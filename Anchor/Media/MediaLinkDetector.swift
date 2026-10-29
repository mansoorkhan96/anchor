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

    /// The site a video link belongs to, for downloading one video at a time per site: "youtube.com" for
    /// youtu.be, m.youtube.com and music.youtube.com alike. nil for links that aren't http(s).
    static func site(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if let alias = siteAliases[host] { return alias }
        if let known = knownHosts.filter({ host == $0 || host.hasSuffix("." + $0) }).max(by: { $0.count < $1.count }) {
            return siteAliases[known] ?? known
        }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    /// Short links and second names that are the same site.
    private static let siteAliases: [String: String] = [
        "youtu.be": "youtube.com", "m.youtube.com": "youtube.com", "music.youtube.com": "youtube.com",
        "vm.tiktok.com": "tiktok.com", "pin.it": "pinterest.com", "twitter.com": "x.com", "fb.watch": "facebook.com",
        "v.redd.it": "reddit.com",
    ]

    /// The link to probe: a YouTube channel's front page lists its Videos, Live and Shorts tabs, which yt-dlp reads in
    /// full (slow); its Videos tab is what people mean.
    static func probeURL(for url: URL) -> URL {
        guard var host = url.host()?.lowercased() else { return url }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "youtube.com" else { return url }
        let parts = url.path().split(separator: "/").map(String.init)
        let channel = (parts.count == 1 && parts[0].hasPrefix("@"))
            || (parts.count == 2 && ["channel", "c", "user"].contains(parts[0]))
        guard channel, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = "/" + parts.joined(separator: "/") + "/videos"
        return components.url ?? url
    }

    /// yt-dlp's catch-all extractor: it found no site-specific support, so the link is treated as an ordinary download.
    static func isGeneric(extractor: String?, key: String?) -> Bool {
        let name = (key ?? extractor ?? "").lowercased()
        return name.isEmpty || name == "generic"
    }
}
