import CryptoKit
import Foundation

enum ToolInstallError: LocalizedError, Equatable {
    case badRelease
    case download(String)
    case missingChecksum(String)
    case checksumMismatch(String)
    case unsafeArchive(String)
    case extraction
    case signature(String)
    case wontRun(String)
    case disk(String)

    var errorDescription: String? {
        switch self {
        case .badRelease: "Couldn't find the latest release"
        case .download(let message): "Download failed: \(message)"
        case .missingChecksum(let name): "No published checksum for \(name), so it wasn't installed"
        case .checksumMismatch(let name): "\(name) didn't match its published checksum, so it wasn't installed"
        case .unsafeArchive(let reason): "The archive looks unsafe (\(reason)), so it wasn't installed"
        case .extraction: "Couldn't unpack the download"
        case .signature(let name): "\(name) isn't signed by its publisher, so it wasn't installed"
        case .wontRun(let name): "\(name) didn't start on this Mac"
        case .disk(let message): message
        }
    }
}

/// What the installer reports while it works, for the Video Tools rows.
enum ToolInstallPhase: Equatable, Sendable {
    case downloading(received: Int64, total: Int64?)
    case verifying
    case installing
}

enum FileHash {
    /// SHA-256 of a file, read in 1 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Lists a zip's entries from its central directory, without extracting anything.
enum ZipInspector {
    struct Entry: Equatable {
        var name: String
        var externalAttributes: UInt32

        var unixMode: UInt32 { externalAttributes >> 16 }
        var isSymlink: Bool { unixMode & 0o170000 == 0o120000 }
    }

    static func entries(of url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + at + $1]) << (8 * UInt32($1)) }
        }
        guard data.count >= 22 else { throw ToolInstallError.unsafeArchive("not a zip file") }
        // The end of central directory record sits in the last 22 bytes plus an optional comment of up to 64 KB.
        var end: Int?
        var offset = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while offset >= lowest {
            if u32(offset) == 0x06054b50 { end = offset; break }
            offset -= 1
        }
        guard let end else { throw ToolInstallError.unsafeArchive("not a zip file") }
        let count = u16(end + 10)
        let size = Int(u32(end + 12))
        let start = Int(u32(end + 16))
        // Zip64 archives are not expected from these vendors; refuse rather than guess.
        guard count != 0xFFFF, u32(end + 12) != 0xFFFF_FFFF, u32(end + 16) != 0xFFFF_FFFF,
              start + size <= end else { throw ToolInstallError.unsafeArchive("unsupported zip layout") }
        var entries: [Entry] = []
        var cursor = start
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw ToolInstallError.unsafeArchive("damaged zip") }
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let attributes = u32(cursor + 38)
            guard cursor + 46 + nameLength <= end else { throw ToolInstallError.unsafeArchive("damaged zip") }
            let nameData = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else { throw ToolInstallError.unsafeArchive("unreadable name") }
            entries.append(Entry(name: name, externalAttributes: attributes))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Rejects anything that could write outside the extraction folder: absolute paths, `..`, backslashes, links.
    static func validate(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { throw ToolInstallError.unsafeArchive("empty archive") }
        for entry in entries {
            let name = entry.name
            guard !name.isEmpty else { throw ToolInstallError.unsafeArchive("empty name") }
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
                throw ToolInstallError.unsafeArchive("bad path \(name)")
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."), !components.dropLast().contains("") else {
                throw ToolInstallError.unsafeArchive("bad path \(name)")
            }
            guard !entry.isSymlink else { throw ToolInstallError.unsafeArchive("link \(name)") }
        }
    }
}

/// Code signature checks with the vendor's Team ID pinned.
enum CodeSignature {
    static func requirement(teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// `codesign --verify --strict` against a Developer ID requirement for `teamID`. Any failure is false.
    static func verify(_ url: URL, teamID: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let output = await ProcessRunner.run("/usr/bin/codesign",
                                             ["--verify", "--strict", "-R=\(requirement(teamID: teamID))", url.path], timeout: 60)
        return output.status == 0 && !output.timedOut
    }
}

/// Downloads, verifies and installs one tool release. Nothing is extracted or run before its checksum matches,
/// and a failure at any step leaves the previous version untouched.
enum ToolInstaller {
    static func verifyChecksum(of file: URL, expected: String?) throws {
        let name = file.lastPathComponent
        guard let expected, Checksums.isSHA256(expected.lowercased()) else { throw ToolInstallError.missingChecksum(name) }
        guard try FileHash.sha256(of: file) == expected.lowercased() else { throw ToolInstallError.checksumMismatch(name) }
    }

    /// Checks every entry, unpacks with ditto, then makes sure nothing unpacked is a link.
    static func extract(_ zip: URL, to folder: URL) async throws {
        try ZipInspector.validate(ZipInspector.entries(of: zip))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], timeout: 300)
        guard output.status == 0 else { throw ToolInstallError.extraction }
        if let link = firstLink(in: folder) { throw ToolInstallError.unsafeArchive("link \(link.lastPathComponent)") }
    }

    private static func firstLink(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return nil }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true {
            return url
        }
        return nil
    }

    /// Installs `release` into `toolsFolder` and returns the record for tools.json.
    static func install(_ release: ToolRelease, into toolsFolder: URL,
                        progress: @escaping @Sendable (ToolInstallPhase) -> Void) async throws -> ToolRecord {
        let fm = FileManager.default
        let staging = toolsFolder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Checksums first (small), then the archives, each verified as soon as it lands.
        var hashes: [String] = []
        var archives: [URL] = []
        var finishedBytes: Int64 = 0
        for asset in release.assets {
            let sums = try await fetchText(asset.checksumURL)
            guard let expected = Checksums.entry(named: asset.checksumName, in: sums) else {
                throw ToolInstallError.missingChecksum(asset.checksumName)
            }
            let archive = staging.appending(path: asset.checksumName)
            let base = finishedBytes
            let bytes = try await FileDownloader.download(asset.url, to: archive) { received, total in
                progress(.downloading(received: base + received, total: total.map { base + $0 }))
            }
            finishedBytes += bytes
            progress(.verifying)
            try verifyChecksum(of: archive, expected: expected)
            hashes.append(expected)
            archives.append(archive)
        }

        // 2. Unpack and check signatures and that each tool runs.
        progress(.installing)
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        for archive in archives { try await extract(archive, to: unpacked) }
        for asset in release.assets {
            let executable = unpacked.appending(path: asset.executable)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ToolInstallError.extraction
            }
            if let team = asset.teamID {
                guard await CodeSignature.verify(executable, teamID: team) else { throw ToolInstallError.signature(asset.executable) }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let main = unpacked.appending(path: release.assets[0].executable)
        // The first run is slow for yt-dlp (macOS checks its libraries once), so this also warms it up.
        let versionArgument = release.tool == .ffmpeg ? "-version" : "--version"
        guard let version = await ToolDiscovery.version(of: main, argument: versionArgument, timeout: 180) else {
            throw ToolInstallError.wontRun(release.tool.title)
        }
        if release.tool == .ffmpeg {
            guard await ToolDiscovery.version(of: unpacked.appending(path: "ffprobe"), argument: "-version", timeout: 60) != nil else {
                throw ToolInstallError.wontRun("ffprobe")
            }
        }

        // 3. Swap into place, one item at a time, each atomically.
        let installedPath: URL
        switch release.tool {
        case .ytdlp:
            let folder = toolsFolder.appending(path: ToolSources.ytdlpFolder, directoryHint: .isDirectory)
            try replace(folder, with: unpacked)
            installedPath = folder.appending(path: ToolSources.ytdlpExecutable)
        case .ffmpeg:
            try replace(toolsFolder.appending(path: "ffprobe"), with: unpacked.appending(path: "ffprobe"))
            try replace(toolsFolder.appending(path: "ffmpeg"), with: unpacked.appending(path: "ffmpeg"))
            installedPath = toolsFolder.appending(path: "ffmpeg")
        case .deno:
            try replace(toolsFolder.appending(path: "deno"), with: unpacked.appending(path: "deno"))
            installedPath = toolsFolder.appending(path: "deno")
        }
        return ToolRecord(version: version, source: .managed, path: installedPath.path, installedAt: Date(),
                          sha256: hashes.joined(separator: ","), runtime: release.tool == .deno ? "deno" : nil)
    }

    /// Moves `new` to `target`, atomically swapping when something is already there.
    private static func replace(_ target: URL, with new: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: new, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: new, to: target)
            }
        } catch {
            throw ToolInstallError.disk("Couldn't install into the Tools folder: \(error.localizedDescription)")
        }
    }

    private static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Anchor", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ToolInstallError.download("no response") }
            if http.statusCode == 404 { throw ToolInstallError.missingChecksum(url.lastPathComponent) }
            guard http.statusCode == 200, data.count < 1_000_000 else { throw ToolInstallError.download("server responded \(http.statusCode)") }
            return String(decoding: data, as: UTF8.self)
        } catch let error as ToolInstallError {
            throw error
        } catch {
            throw ToolInstallError.download(error.localizedDescription)
        }
    }
}

/// A URLSession download with byte progress, written straight to `destination`.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<Int64, Error>?
    private let lock = NSLock()
    private var moveError: Error?
    private var bytes: Int64 = 0

    private init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Returns the number of bytes written.
    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int64 {
        let downloader = FileDownloader(destination: destination, onProgress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Anchor", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.lock.withLock { downloader.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock {
            guard status == 200 else {
                moveError = ToolInstallError.download("server responded \(status)")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                moveError = ToolInstallError.disk(error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, moveError, bytes) = lock.withLock { () -> (CheckedContinuation<Int64, Error>?, Error?, Int64) in
            defer { self.continuation = nil }
            return (self.continuation, self.moveError, self.bytes)
        }
        if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError()
                                 : ToolInstallError.download(error.localizedDescription))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume(returning: bytes)
        }
    }
}
