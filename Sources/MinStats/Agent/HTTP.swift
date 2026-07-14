import Foundation

/// The subset of HTTP/1.1 this agent needs. Deliberately tiny: it serves a
/// handful of JSON endpoints to a known client on a private network, so a
/// full server (and a dependency) would be far more than the job requires.
enum HTTP {
    struct Request {
        let method: String
        let path: String
        /// Lowercased keys — header names are case-insensitive.
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        let status: Int
        let body: Data

        static func json(_ value: some Encodable, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            let body = (try? encoder.encode(value)) ?? Data()
            return Response(status: status, body: body)
        }

        static func error(_ message: String, status: Int) -> Response {
            json(ErrorBody(error: message), status: status)
        }

        private struct ErrorBody: Encodable { let error: String }

        var wireData: Data {
            var head = "HTTP/1.1 \(status) \(HTTP.reason(status))\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            // The agent is single-request-per-connection: simpler, and the
            // client polls on its own cadence anyway.
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    /// Parses a request if `buffer` holds a complete one (headers + the full
    /// body per Content-Length). Returns nil while more bytes are needed, so
    /// the caller can keep receiving.
    static func parse(_ buffer: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator),
              let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        let available = buffer.count - bodyStart
        guard available >= expected else { return nil }  // keep reading

        return Request(
            method: String(requestLine[0]).uppercased(),
            // Strip any query string — this agent routes on path only.
            path: String(String(requestLine[1]).split(separator: "?").first ?? ""),
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + expected))
        )
    }
}
