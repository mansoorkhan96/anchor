import Foundation

struct TorrentStatus: Sendable {
    var state: String
    var name: String?
    var totalBytes: Int64
    var completedBytes: Int64
    var speed: Double
    var connections: Int
    var seeders: Int
    var errorMessage: String?
    var followedBy: String?
}

/// A torrent added to aria2 in a paused state so its files can be reviewed before downloading.
struct PreparedTorrent: Sendable, Equatable {
    var gid: String
    var name: String
    var files: [TorrentFile]
    var directory: URL
}

enum Aria2Error: LocalizedError {
    case missingBinary
    case notReady
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary: "The torrent engine (aria2c) is missing from the app bundle"
        case .notReady: "The torrent engine did not start"
        case .rpc(let message): message
        }
    }
}

/// Runs a private aria2c sidecar on demand and talks to it over JSON-RPC. Torrents and magnets only.
actor Aria2 {
    static let shared = Aria2()

    private var process: Process?
    private var port = 0
    private let secret = UUID().uuidString
    private var nextID = 0

    private var binary: URL? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/aria2c")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let brew = URL(filePath: "/opt/homebrew/bin/aria2c")
        return FileManager.default.isExecutableFile(atPath: brew.path) ? brew : nil
    }

    var isRunning: Bool { process?.isRunning == true }

    func ensureRunning() async throws {
        if isRunning { return }
        guard let binary else { throw Aria2Error.missingBinary }

        let support = AppPaths.support
        port = Int.random(in: 46_800...46_999)
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(secret)",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--seed-time=0", "--bt-save-metadata=true", "--continue=true", "--follow-torrent=mem",
            "--max-concurrent-downloads=50", "--file-allocation=none", "--auto-file-renaming=false",
            "--dht-file-path=\(support.appending(path: "dht.dat").path)",
            "--quiet=true",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc

        for _ in 0..<40 {
            if (try? await call("aria2.getVersion", [])) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Aria2Error.notReady
    }

    func shutdown() {
        process?.terminate()
        process = nil
    }

    func addMagnet(_ uri: String, directory: URL) async throws -> String {
        try await ensureRunning()
        let result = try await call("aria2.addUri", [[uri], ["dir": directory.path]])
        guard let gid = result as? String else { throw Aria2Error.rpc("No id returned") }
        return gid
    }

    func addTorrent(_ file: URL, directory: URL, select: [Int]? = nil, checkIntegrity: Bool = false) async throws -> String {
        try await ensureRunning()
        let data = try Data(contentsOf: file).base64EncodedString()
        var options = ["dir": directory.path]
        if let select, !select.isEmpty { options["select-file"] = select.map(String.init).joined(separator: ",") }
        if checkIntegrity { options["check-integrity"] = "true" }
        let result = try await call("aria2.addTorrent", [data, [String](), options])
        guard let gid = result as? String else { throw Aria2Error.rpc("No id returned") }
        return gid
    }

    /// Fetches a magnet's metadata and leaves the real download paused, returning its file list.
    func prepareMagnet(_ uri: String, directory: URL) async throws -> PreparedTorrent {
        try await ensureRunning()
        let result = try await call("aria2.addUri", [[uri], ["dir": directory.path, "pause-metadata": "true"]])
        guard let meta = result as? String else { throw Aria2Error.rpc("No id returned") }
        do {
            for _ in 0..<180 {
                try Task.checkCancellation()
                let status = try await call("aria2.tellStatus", [meta, ["status", "followedBy", "errorMessage"]]) as? [String: Any]
                if let next = (status?["followedBy"] as? [String])?.first {
                    return try await prepared(next, directory: directory)
                }
                if status?["status"] as? String == "error" {
                    throw Aria2Error.rpc(status?["errorMessage"] as? String ?? "Couldn't fetch the torrent")
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw Aria2Error.rpc("Couldn't fetch the file list: no peers responded")
        } catch {
            await remove(meta)
            throw error
        }
    }

    /// Adds a .torrent paused and returns its file list.
    func prepareTorrent(_ file: URL, directory: URL) async throws -> PreparedTorrent {
        try await ensureRunning()
        let data = try Data(contentsOf: file).base64EncodedString()
        let result = try await call("aria2.addTorrent", [data, [String](), ["dir": directory.path, "pause": "true"]])
        guard let gid = result as? String else { throw Aria2Error.rpc("No id returned") }
        return try await prepared(gid, directory: directory)
    }

    private func prepared(_ gid: String, directory: URL) async throws -> PreparedTorrent {
        let status = try await call("aria2.tellStatus", [gid, ["bittorrent"]]) as? [String: Any]
        let info = (status?["bittorrent"] as? [String: Any])?["info"] as? [String: Any]
        let files = try await files(gid, directory: directory)
        return PreparedTorrent(gid: gid, name: info?["name"] as? String ?? files.first?.name ?? "Torrent",
                               files: files, directory: directory)
    }

    /// The torrent's files, with paths relative to the download folder.
    func files(_ gid: String, directory: URL) async throws -> [TorrentFile] {
        guard let list = try await call("aria2.getFiles", [gid]) as? [[String: Any]] else { return [] }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return list.compactMap { entry in
            guard let index = Int(entry["index"] as? String ?? "") else { return nil }
            let path = entry["path"] as? String ?? ""
            return TorrentFile(index: index,
                               path: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
                               length: Int64(entry["length"] as? String ?? "") ?? 0,
                               completed: Int64(entry["completedLength"] as? String ?? "") ?? 0,
                               included: (entry["selected"] as? String) != "false")
        }
    }

    /// Moves a paused (prepared) torrent to another folder.
    func setDirectory(_ gid: String, to directory: URL) async {
        _ = try? await call("aria2.changeOption", [gid, ["dir": directory.path]])
    }

    /// Changes which files download. aria2 only applies this to paused downloads, so active ones are paused briefly.
    func select(_ gid: String, files indexes: [Int]) async {
        guard !indexes.isEmpty else { return }
        let csv = indexes.map(String.init).joined(separator: ",")
        let status = (try? await call("aria2.tellStatus", [gid, ["status"]]) as? [String: Any])?["status"] as? String
        guard status == "active" || status == "waiting" else {
            _ = try? await call("aria2.changeOption", [gid, ["select-file": csv]])
            return
        }
        _ = try? await call("aria2.forcePause", [gid])
        for _ in 0..<30 {
            let now = (try? await call("aria2.tellStatus", [gid, ["status"]]) as? [String: Any])?["status"] as? String
            if now == "paused" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = try? await call("aria2.changeOption", [gid, ["select-file": csv]])
        _ = try? await call("aria2.unpause", [gid])
    }

    func status(_ gid: String) async throws -> TorrentStatus {
        let keys = ["status", "totalLength", "completedLength", "downloadSpeed", "connections",
                    "numSeeders", "errorMessage", "followedBy", "bittorrent"]
        guard let json = try await call("aria2.tellStatus", [gid, keys]) as? [String: Any] else {
            throw Aria2Error.rpc("Bad status")
        }
        let info = (json["bittorrent"] as? [String: Any])?["info"] as? [String: Any]
        return TorrentStatus(
            state: json["status"] as? String ?? "error",
            name: info?["name"] as? String,
            totalBytes: Int64(json["totalLength"] as? String ?? "") ?? 0,
            completedBytes: Int64(json["completedLength"] as? String ?? "") ?? 0,
            speed: Double(json["downloadSpeed"] as? String ?? "") ?? 0,
            connections: Int(json["connections"] as? String ?? "") ?? 0,
            seeders: Int(json["numSeeders"] as? String ?? "") ?? 0,
            errorMessage: json["errorMessage"] as? String,
            followedBy: (json["followedBy"] as? [String])?.first
        )
    }

    func pause(_ gid: String) async {
        _ = try? await call("aria2.forcePause", [gid])
    }

    func resume(_ gid: String) async {
        _ = try? await call("aria2.unpause", [gid])
    }

    func remove(_ gid: String) async {
        _ = try? await call("aria2.forceRemove", [gid])
        _ = try? await call("aria2.removeDownloadResult", [gid])
    }

    func setSpeedLimit(_ bytesPerSecond: Int64) async {
        guard isRunning else { return }
        _ = try? await call("aria2.changeGlobalOption", [["max-overall-download-limit": "\(bytesPerSecond)"]])
    }

    private func call(_ method: String, _ params: [Any]) async throws -> Any {
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "\(nextID)", "method": method, "params": ["token:\(secret)"] + params]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Aria2Error.rpc("Bad reply") }
        if let error = json["error"] as? [String: Any] { throw Aria2Error.rpc(error["message"] as? String ?? "RPC error") }
        return json["result"] ?? NSNull()
    }
}
