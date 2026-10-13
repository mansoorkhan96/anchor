import Foundation

/// The external tools video downloads need. `ffmpeg` covers ffmpeg and ffprobe; `deno` covers the JavaScript runtime
/// (Anchor's own Deno, or a Deno, Node or Bun already on the Mac).
enum ToolID: String, Codable, CaseIterable, Identifiable, Sendable {
    case ytdlp = "yt-dlp", ffmpeg, deno

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "FFmpeg"
        case .deno: "Deno"
        }
    }

    var purpose: String {
        switch self {
        case .ytdlp: "Finds and downloads the video"
        case .ffmpeg: "Joins video and audio, converts to MP4 or M4A"
        case .deno: "Runs the scripts some sites need to play a video"
        }
    }

    var symbol: String {
        switch self {
        case .ytdlp: "arrow.down.to.line"
        case .ffmpeg: "film"
        case .deno: "curlybraces"
        }
    }

    /// Download size of the current releases, shown before installing.
    var approximateBytes: Int64 {
        switch self {
        case .ytdlp: 54_000_000
        case .ffmpeg: 57_000_000
        case .deno: 38_000_000
        }
    }
}

enum ToolSource: String, Codable, Sendable {
    /// Downloaded and kept up to date by Anchor.
    case managed
    /// Found on the Mac (Homebrew, MacPorts, PATH); Anchor never updates it.
    case system
}

/// One entry of tools.json.
struct ToolRecord: Codable, Equatable, Sendable {
    var version: String
    var source: ToolSource
    /// The executable: yt-dlp, ffmpeg (ffprobe sits next to it) or the JavaScript runtime.
    var path: String
    var installedAt: Date
    /// SHA-256 of the verified download, for managed tools.
    var sha256: String?
    /// The JavaScript runtime's name (deno, node or bun); nil for the other tools.
    var runtime: String?

    var url: URL { URL(filePath: path) }
}

/// tools.json in the Tools folder.
struct ToolManifest: Codable, Equatable, Sendable {
    var tools: [String: ToolRecord] = [:]

    subscript(tool: ToolID) -> ToolRecord? {
        get { tools[tool.rawValue] }
        set { tools[tool.rawValue] = newValue }
    }

    /// An unreadable or missing file is an empty manifest: the tools are then looked for again.
    static func load(from url: URL) -> ToolManifest {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(ToolManifest.self, from: data) else { return ToolManifest() }
        return manifest
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Reading and comparing the version strings the tools print.
enum ToolVersion {
    /// `deno 2.9.7 (stable, ...)` is 2.9.7, `v22.1.0` is 22.1.0, `ffmpeg version 9.0.2-https://...` is 9.0.2,
    /// `2026.08.19` stays as is. Snapshot builds (`N-127260-g7bc3576910-...`) keep their build name.
    static func parse(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        let words = line.split(separator: " ").map(String.init)
        var token: String
        if let index = words.firstIndex(of: "version"), index + 1 < words.count {
            token = words[index + 1]
        } else if words.count > 1, words[0].first?.isLetter == true {
            token = words[1]
        } else {
            token = words[0]
        }
        if token.hasPrefix("v"), token.dropFirst().first?.isNumber == true { token.removeFirst() }
        if token.first?.isNumber == true {
            // Drop build suffixes like "-https://www.martin-riedl.de" or "-tessus".
            token = String(token.prefix { $0.isNumber || $0 == "." })
        } else if token.hasPrefix("N-") {
            let parts = token.split(separator: "-")
            token = parts.prefix(3).joined(separator: "-")
        }
        return token.isEmpty ? nil : token
    }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Numeric comparison, missing parts count as 0 ("22" == "22.0.0"). Unparseable versions never qualify.
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        guard let have = components(version), let need = components(minimum) else { return false }
        for i in 0..<max(have.count, need.count) {
            let (a, b) = (i < have.count ? have[i] : 0, i < need.count ? need[i] : 0)
            if a != b { return a > b }
        }
        return true
    }
}

/// JavaScript runtimes yt-dlp can use, in order of preference, with the oldest version that works.
enum JSRuntime {
    static let order = ["deno", "node", "bun"]

    static func minimum(_ name: String) -> String? {
        switch name {
        case "deno": "2.3"
        case "node": "22"
        case "bun": "1.2.11"
        default: nil
        }
    }

    static func title(_ name: String) -> String {
        switch name {
        case "node": "Node.js"
        case "bun": "Bun"
        default: "Deno"
        }
    }
}
