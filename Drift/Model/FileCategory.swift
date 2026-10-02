import SwiftUI

enum FileCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, music, archives, documents, apps, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .music: "Music"
        case .archives: "Archives"
        case .documents: "Documents"
        case .apps: "Apps"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .archives: "archivebox"
        case .documents: "doc.text"
        case .apps: "app.badge"
        case .other: "doc"
        }
    }

    var color: Color {
        switch self {
        case .video: Color(hex: 0x8C9EFF)
        case .music: Color(hex: 0xF28CB1)
        case .archives: Color(hex: 0xF2B35B)
        case .documents: Color(hex: 0x6FD3A0)
        case .apps: Color(hex: 0x5CCDEB)
        case .other: Color(hex: 0xA6AAB3)
        }
    }

    private static let extensions: [FileCategory: Set<String>] = [
        .video: ["mp4", "mkv", "mov", "avi", "webm", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "3gp"],
        .music: ["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "aiff", "wma", "alac"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "lz", "cab"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub", "csv", "rtf", "pages", "numbers", "key", "md"],
        .apps: ["dmg", "pkg", "app", "exe", "msi", "apk", "deb", "rpm", "appimage", "mpkg"],
    ]

    static func detect(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }

    /// Extensions that look like something worth downloading (used by the clipboard watcher).
    static var downloadableExtensions: Set<String> {
        extensions.values.reduce(into: Set(["torrent", "bin", "img", "jar"])) { $0.formUnion($1) }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let driftAccent = Color(hex: 0x5CCDEB)
    static let driftTorrent = Color(hex: 0xC9A4FF)
    static let driftPaused = Color(hex: 0xF2B35B)
    static let driftSuccess = Color(hex: 0x6FD3A0)
}
