import Foundation

enum FileNaming {
    /// Parses `filename*=UTF-8''…` (preferred) or `filename="…"` from a Content-Disposition header.
    static func fileName(fromContentDisposition header: String) -> String? {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts where part.lowercased().hasPrefix("filename*=") {
            let value = String(part.dropFirst("filename*=".count))
            if let quote = value.range(of: "''") {
                let encoded = String(value[quote.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return sanitize(decoded) }
            }
        }
        for part in parts where part.lowercased().hasPrefix("filename=") {
            var value = String(part.dropFirst("filename=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return sanitize(value.removingPercentEncoding ?? value) }
        }
        return nil
    }

    static func fileName(from url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return sanitize(last.removingPercentEncoding ?? last) }
        return url.host() ?? "download"
    }

    /// The display name (`dn`) of a magnet link, with form-encoded `+` turned back into spaces.
    static func magnetName(_ url: URL) -> String? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQueryItems?.first(where: { $0.name == "dn" })?.value else { return nil }
        let name = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        return name.isEmpty ? nil : sanitize(name)
    }

    /// The info hash (`xt=urn:btih:<hash>`) of a magnet link, lowercased.
    static func magnetHash(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "xt" }?.value?.split(separator: ":").last?.lowercased()
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// Returns `name` or `name (2).ext`, `name (3).ext`… so nothing in `directory` is overwritten.
    /// `ignoringPartials` skips the partial-file check, for renaming a finished download over its own partial.
    static func unique(_ name: String, in directory: URL, taken: Set<String> = [], ignoringPartials: Bool = false) -> String {
        let fm = FileManager.default
        func free(_ candidate: String) -> Bool {
            !taken.contains(candidate)
                && !fm.fileExists(atPath: directory.appending(path: candidate).path)
                && (ignoringPartials || !fm.fileExists(atPath: directory.appending(path: candidate + DownloadItem.partialSuffix).path))
        }
        if free(name) { return name }
        let (stem, ext) = splitExtension(name)
        for n in 2...9999 {
            let candidate = "\(stem) (\(n))\(ext)"
            if free(candidate) { return candidate }
        }
        return UUID().uuidString + ext
    }

    /// Splits off the extension, keeping compound ones like `.tar.gz` together. `ext` includes the dot.
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst"] where lower.hasSuffix(compound) && lower.count > compound.count {
            return (String(name.dropLast(compound.count)), String(name.suffix(compound.count)))
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        return ((name as NSString).deletingPathExtension, "." + ext)
    }
}
