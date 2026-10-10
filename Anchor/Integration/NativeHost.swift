import Foundation

/// Registers Anchor's native messaging host with the Chromium browsers on this Mac, so the browser extension
/// can launch Anchor when it isn't running. Rewritten at every launch, since the host's path moves with the app.
enum NativeHost {
    static let name = "dev.mansoor.anchor"
    /// The host's name before the app was renamed from Drift; its manifests are removed at launch.
    static let legacyName = "dev.mansoor.drift"
    /// Fixed by the `key` in the extension's manifest.json.
    static let extensionID = "alcbklgeokffgjieplnglbmhadebnncm"

    /// Each browser's profile folder under Application Support.
    private static let browsers = [
        "Google/Chrome",
        "Chromium",
        "Arc/User Data",
        "BraveSoftware/Brave-Browser",
        "Microsoft Edge",
    ]

    static func register() {
        let host = Bundle.main.bundleURL.appending(path: "Contents/MacOS/anchor-native-host")
        guard FileManager.default.isExecutableFile(atPath: host.path) else { return }
        let manifest: [String: Any] = [
            "name": name,
            "description": "Anchor Download Manager",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return }
        for browser in browsers {
            let profile = URL.applicationSupportDirectory.appending(path: browser, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: profile.path) else { continue }
            let folder = profile.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appending(path: "\(name).json"), options: .atomic)
            try? FileManager.default.removeItem(at: folder.appending(path: "\(legacyName).json"))
        }
    }
}
