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

    /// Dot and progress color (taken from Vitals' module colors).
    var color: Color {
        switch self {
        case .video: .adaptive(light: 0x5951B0, dark: 0x8C85E0)
        case .music: .adaptive(light: 0xE296B2, dark: 0xEFA7C1)
        case .archives: .adaptive(light: 0xE8B248, dark: 0xF0C060)
        case .documents: .adaptive(light: 0x46902E, dark: 0x6FBF55)
        case .apps: .anchorAccent
        case .other: .adaptive(light: 0x8E8E93, dark: 0xA1A1A6)
        }
    }

    /// Text color for file tiles.
    var ink: Color {
        switch self {
        case .video: .adaptive(light: 0x5951B0, dark: 0xA9A3F0)
        case .music: .adaptive(light: 0xB8467A, dark: 0xF2B3CA)
        case .archives: .adaptive(light: 0xA86F0B, dark: 0xF3C76E)
        case .documents: .adaptive(light: 0x3C7F27, dark: 0x8ED17A)
        case .apps: .anchorAccentInk
        case .other: .adaptive(light: 0x5E5E63, dark: 0xB4B4B9)
        }
    }

    /// Tile background.
    var wash: Color {
        switch self {
        case .video: .adaptive(light: 0xEDECF7, dark: 0x2A2840)
        case .music: .adaptive(light: 0xFBEFF4, dark: 0x3A2730)
        case .archives: .adaptive(light: 0xFCF3E1, dark: 0x3A3020)
        case .documents: .adaptive(light: 0xE9F3E5, dark: 0x233322)
        case .apps: .anchorAccentWash
        case .other: .adaptive(light: 0xF2F2F4, dark: 0x2E2E31)
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
}
