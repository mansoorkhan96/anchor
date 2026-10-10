import AppKit

/// Chrome native messaging host for the Drift browser extension.
///
/// Chrome starts this tool on request and talks to it over stdin/stdout: each message is a 4-byte native-endian
/// length followed by that many bytes of JSON. `{"type":"ping"}` answers at once, so the extension can tell that
/// the host is installed. `{"type":"launch"}` starts Drift in the background if needed and answers once its
/// browser bridge is up (or after a timeout), with `{"ok":true|false,"enabled":true|false}`.

let bridge = URL(string: "http://127.0.0.1:47821/ping")!

/// Drift.app, three levels up from Drift.app/Contents/MacOS/drift-native-host.
let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func readMessage() -> [String: Any]? {
    let input = FileHandle.standardInput
    guard let head = try? input.read(upToCount: 4), head.count == 4 else { return nil }
    let length = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    guard length > 0, length < 1_000_000, let body = try? input.read(upToCount: Int(length)) else { return nil }
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}

func reply(_ object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(body.count)
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4) + body)
}

/// Whether Drift's bridge answers, and if so whether browser downloads are on.
func ping() async -> Bool? {
    var request = URLRequest(url: bridge)
    request.timeoutInterval = 1
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["enabled"] as? Bool ?? false
}

func launch() async -> [String: Any] {
    if let enabled = await ping() { return ["ok": true, "enabled": enabled] }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    guard (try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil else {
        return ["ok": false, "enabled": false]
    }
    for _ in 0..<60 {
        if let enabled = await ping() { return ["ok": true, "enabled": enabled] }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return ["ok": false, "enabled": false]
}

if let message = readMessage() {
    switch message["type"] as? String {
    case "launch": reply(await launch())
    default: reply(["ok": true])
    }
}
