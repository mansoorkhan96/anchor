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

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// Returns `name` or `name (2).ext`, `name (3).ext`… so nothing in `directory` is overwritten.
    static func unique(_ name: String, in directory: URL, taken: Set<String> = []) -> String {
        let fm = FileManager.default
        func free(_ candidate: String) -> Bool {
            !taken.contains(candidate)
                && !fm.fileExists(atPath: directory.appending(path: candidate).path)
                && !fm.fileExists(atPath: directory.appending(path: candidate + ".drift-part").path)
        }
        if free(name) { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        for n in 2...9999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if free(candidate) { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    }
}
