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

    func addTorrent(_ file: URL, directory: URL) async throws -> String {
        try await ensureRunning()
        let data = try Data(contentsOf: file).base64EncodedString()
        let result = try await call("aria2.addTorrent", [data, [String](), ["dir": directory.path]])
        guard let gid = result as? String else { throw Aria2Error.rpc("No id returned") }
        return gid
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
