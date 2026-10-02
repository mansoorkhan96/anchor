import Foundation

/// What a server tells us about a URL before downloading it.
struct ProbeResult: Sendable, Equatable {
    var finalURL: URL
    var fileName: String
    var totalBytes: Int64?
    var supportsRanges: Bool
    var validator: String?
    var mimeType: String?
}

enum Probe {
    /// Requests `bytes=0-` and inspects only the response headers, cancelling before the body.
    static func run(_ url: URL, headers: [String: String] = [:]) async throws -> ProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        bytes.task.cancel()

        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.badResponse(http.statusCode) }
        return parse(http, requested: url)
    }

    static func parse(_ http: HTTPURLResponse, requested: URL) -> ProbeResult {
        let finalURL = http.url ?? requested
        var total: Int64?
        var ranges = false

        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"), let size = Int64(range[range.index(after: slash)...]) {
            total = size
            ranges = true
        } else if http.expectedContentLength > 0 {
            total = http.expectedContentLength
            ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }

        let name = http.value(forHTTPHeaderField: "Content-Disposition").flatMap(FileNaming.fileName(fromContentDisposition:))
            ?? FileNaming.fileName(from: finalURL)

        let validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
        return ProbeResult(finalURL: finalURL, fileName: name, totalBytes: total, supportsRanges: ranges,
                           validator: validator, mimeType: http.mimeType)
    }
}

enum DownloadError: LocalizedError, Equatable {
    case badResponse(Int)
    case fileChanged
    case disk(String)
    case tooManyRetries(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): code == 0 ? "Invalid server response" : "Server responded \(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)"
        case .fileChanged: "The file changed on the server"
        case .disk(let message): message
        case .tooManyRetries(let message): message
        }
    }
}
