import Foundation
import Network
import AppKit

/// Tiny HTTP server on 127.0.0.1 that the browser extension talks to.
///
/// `GET /ping` reports that Anchor is running; `POST /add` with JSON `{url, filename?, referrer?, cookies?, userAgent?}`
/// queues a download. Requests from web pages are refused: only browser-extension origins, or callers that
/// send no Origin at all (e.g. curl), are accepted.
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()
    static let port: NWEndpoint.Port = 47_821

    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.port)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                Self.receive(on: connection, buffer: Data())
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            NSLog("Anchor: browser bridge failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated static func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                respond(to: request, on: connection)
            } else if complete || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private nonisolated static func respond(to request: HTTPRequest, on connection: NWConnection) {
        let origin = request.headers["origin"] ?? ""
        let trusted = origin.isEmpty || ["chrome-extension://", "moz-extension://", "safari-web-extension://"]
            .contains { origin.hasPrefix($0) }

        func send(_ status: String, _ body: String) {
            var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
            if trusted, !origin.isEmpty { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
            let payload = Data((head + "\r\n" + body).utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }

        guard trusted else { return send("403 Forbidden", #"{"error":"forbidden"}"#) }

        switch (request.method, request.path) {
        case ("GET", "/ping"):
            Task { @MainActor in
                let enabled = AppSettings.shared.browserIntegration
                send("200 OK", #"{"app":"Anchor","enabled":\#(enabled)}"#)
            }
        case ("POST", "/add"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let url = json["url"] as? String else {
                return send("400 Bad Request", #"{"error":"missing url"}"#)
            }
            var headers: [String: String] = [:]
            if let cookies = json["cookies"] as? String, !cookies.isEmpty { headers["Cookie"] = cookies }
            if let referrer = json["referrer"] as? String, !referrer.isEmpty { headers["Referer"] = referrer }
            if let agent = json["userAgent"] as? String, !agent.isEmpty { headers["User-Agent"] = agent }
            let name = json["filename"] as? String
            Task { @MainActor in
                // Switched off in Settings: refuse, so the extension lets the browser keep the download.
                guard AppSettings.shared.browserIntegration else {
                    return send("409 Conflict", #"{"error":"disabled"}"#)
                }
                AppRouter.shared.handleBrowserDownload(url: url, fileName: name, headers: headers)
                send("200 OK", #"{"ok":true}"#)
            }
        case ("OPTIONS", _):
            send("204 No Content", "")
        default:
            send("404 Not Found", #"{"error":"not found"}"#)
        }
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Returns nil until the buffer holds a complete request (headers plus Content-Length bytes).
    init?(_ data: Data) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        headers = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}
