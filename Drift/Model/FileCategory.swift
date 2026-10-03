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
        case .video: .adaptive(light: 0x9333EA, dark: 0xC084FC)
        case .music: .adaptive(light: 0xDB2777, dark: 0xF472B6)
        case .archives: .adaptive(light: 0xC2410C, dark: 0xFB923C)
        case .documents: .adaptive(light: 0x15803D, dark: 0x4ADE80)
        case .apps: .adaptive(light: 0x2563EB, dark: 0x60A5FA)
        case .other: .adaptive(light: 0x5B6170, dark: 0xA1A6B3)
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
