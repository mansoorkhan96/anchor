import Foundation

/// Looks for copies of ffmpeg and a JavaScript runtime that are already on the Mac.
enum ToolDiscovery {
    static let preferredDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// Homebrew (Apple silicon, then Intel), MacPorts, then each PATH entry; duplicates removed.
    static func searchDirectories(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for dir in preferredDirectories + (path ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
            let normalized = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            if seen.insert(normalized).inserted { result.append(URL(filePath: normalized, directoryHint: .isDirectory)) }
        }
        return result
    }

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// The first folder with both ffmpeg and ffprobe where `ffmpeg -version` runs.
    static func findFFmpeg(in directories: [URL]) async -> (path: URL, version: String)? {
        for dir in directories {
            let ffmpeg = dir.appending(path: "ffmpeg"), ffprobe = dir.appending(path: "ffprobe")
            guard isExecutable(ffmpeg), isExecutable(ffprobe),
                  let version = await version(of: ffmpeg, argument: "-version") else { continue }
            return (ffmpeg, version)
        }
        return nil
    }

    /// Deno, else Node, else Bun, each at or above its minimum version; older copies are ignored.
    static func findJSRuntime(in directories: [URL]) async -> (name: String, path: URL, version: String)? {
        for name in JSRuntime.order {
            guard let minimum = JSRuntime.minimum(name) else { continue }
            for dir in directories {
                let candidate = dir.appending(path: name)
                guard isExecutable(candidate), let version = await version(of: candidate, argument: "--version"),
                      ToolVersion.isAtLeast(version, minimum) else { continue }
                return (name, candidate, version)
            }
        }
        return nil
    }

    /// Runs `tool <argument>` and reads the version from its first line; nil if it fails or prints nothing usable.
    static func version(of tool: URL, argument: String, timeout: TimeInterval = 10) async -> String? {
        let output = await ProcessRunner.run(tool.path, [argument], timeout: timeout)
        guard output.status == 0, !output.timedOut else { return nil }
        return ToolVersion.parse(String(decoding: output.data, as: UTF8.self))
    }
}
