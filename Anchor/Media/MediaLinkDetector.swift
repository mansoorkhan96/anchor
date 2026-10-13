import Foundation

/// Decides which links might be videos. A known host only marks a link as *possibly* media: the yt-dlp probe decides.
enum MediaLinkDetector {
    static let knownHosts: [String] = [
        "youtube.com", "youtu.be", "m.youtube.com", "music.youtube.com", "instagram.com", "tiktok.com", "vm.tiktok.com",
        "pinterest.com", "pin.it", "x.com", "twitter.com", "vimeo.com", "facebook.com", "fb.watch", "reddit.com",
        "v.redd.it", "twitch.tv", "dailymotion.com", "soundcloud.com", "bilibili.com",
    ]

    /// True for http(s) links on a known media host or one of its subdomains.
    static func isLikelyMedia(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// yt-dlp's catch-all extractor: it found no site-specific support, so the link is treated as an ordinary download.
    static func isGeneric(extractor: String?, key: String?) -> Bool {
        let name = (key ?? extractor ?? "").lowercased()
        return name.isEmpty || name == "generic"
    }
}
