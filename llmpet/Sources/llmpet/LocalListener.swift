import Foundation
import Network

/// Chrome extensions can't touch the filesystem, so the extension POSTs here and
/// we drop the same JSON files any other source would write.
/// ponytail: bare-minimum HTTP on loopback — no routing, no keep-alive, no TLS.
/// If this ever needs to serve anything but one endpoint, use a real server.
final class LocalListener {
    static let port: UInt16 = 7717
    private var listener: NWListener?

    func start() {
        guard let listener = try? NWListener(
            using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!
        ) else { return }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.receive(conn, buffer: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil || (done && buffer.isEmpty) {
                conn.cancel()
                return
            }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receive(conn, buffer: buffer)
                return
            }
            let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
            let body = buffer[separator.upperBound...]
            if body.count < contentLength(of: head) {
                self.receive(conn, buffer: buffer)
                return
            }

            self.handle(body: Data(body))
            // Chrome preflights the POST because of the JSON content-type, and a
            // preflight without Allow-Methods fails — which silently killed every
            // report the extension tried to send.
            let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: content-type\r\n"
                + "Access-Control-Max-Age: 86400\r\nContent-Length: 0\r\n\r\n"
            conn.send(content: Data(response.utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func handle(body: Data) {
        NSLog("llmpet: recibí %d bytes: %@", body.count,
              String(decoding: body.prefix(200), as: UTF8.self))
        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let key = raw["key"] as? String,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return }

        let file = FileSource.dir.appendingPathComponent("\(key).json")
        if raw["state"] as? String == "gone" {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? body.write(to: file)
        }
    }
}

private func contentLength(of head: String) -> Int {
    for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
        return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
    }
    return 0
}
