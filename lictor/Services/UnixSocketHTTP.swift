//
//  UnixSocketHTTP.swift
//  lictor
//
//  A minimal client that performs exactly one HTTP/1.1 round trip over a
//  unix domain socket. URLSession cannot speak to unix sockets, hence this.
//
//  `Connection: close` does NOT mean the response is unframed. Go's net/http,
//  which tailscaled is built on, switches to chunked transfer encoding for any
//  handler that writes more than a couple of kilobytes without setting
//  Content-Length, and it sends both headers together. Treating everything after
//  the blank line as the body therefore yields chunk-size lines mixed into the
//  JSON, which fails to parse and silently blanks out whatever it was carrying.
//  All three framings are handled here.
//
//  **This client blocks.** Always call it off the main thread.
//

import Foundation

nonisolated struct HTTPResponse: Sendable {
    let status: Int
    let body: Data
}

nonisolated enum UnixSocketHTTPError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case socketCreationFailed(Int32)
    case connectionFailed(path: String, errno: Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case malformedResponse
    case malformedBody(String)

    var description: String {
        switch self {
        case .pathTooLong(let path):
            return "socket path is too long: \(path)"
        case .socketCreationFailed(let e):
            return "could not create socket (errno=\(e))"
        case .connectionFailed(let path, let e):
            return "could not connect to \(path) (errno=\(e))"
        case .writeFailed(let e):
            return "write failed (errno=\(e))"
        case .readFailed(let e):
            return "read failed (errno=\(e))"
        case .malformedResponse:
            return "malformed HTTP response"
        case .malformedBody(let detail):
            return "malformed HTTP body: \(detail)"
        }
    }
}

nonisolated enum UnixSocketHTTP {

    /// - Parameter timeout: send and receive timeout in seconds. Always set, so the app cannot hang
    static func request(
        socketPath: String,
        method: String = "GET",
        path: String,
        host: String = "local-tailscaled.sock",
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 5
    ) throws -> HTTPResponse {

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketHTTPError.socketCreationFailed(errno) }
        defer { close(fd) }

        // Without this, a peer that closes between connect() and write() raises
        // SIGPIPE, whose default disposition is still SIG_DFL here and kills the
        // whole app. The app is allowed to die, but not silently and not for this.
        var suppressSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                   &suppressSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

        try connect(fd: fd, to: socketPath)
        setTimeouts(fd: fd, seconds: timeout)

        try send(fd: fd, request: buildRequest(
            method: method, path: path, host: host, body: body, contentType: contentType))

        let raw = try receiveUntilEOF(fd: fd)
        return try parse(raw)
    }

    // MARK: - Connect

    private static func connect(fd: Int32, to socketPath: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw UnixSocketHTTPError.pathTooLong(socketPath)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = CChar(bitPattern: byte)
                }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, size)
            }
        }
        guard result == 0 else {
            throw UnixSocketHTTPError.connectionFailed(path: socketPath, errno: errno)
        }
    }

    private static func setTimeouts(fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds),
                         tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    // MARK: - Send

    private static func buildRequest(
        method: String, path: String, host: String, body: Data?, contentType: String?
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        // The LocalAPI validates Host; anything but local-tailscaled.sock gets 403 (docs/localapi.md §2)
        head += "Host: \(host)\r\n"
        head += "Connection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "\r\n"

        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    private static func send(fd: Int32, request: Data) throws {
        try request.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw UnixSocketHTTPError.writeFailed(errno)
                }
            }
        }
    }

    // MARK: - Receive

    private static func receiveUntilEOF(fd: Int32) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                return out
            } else if errno == EINTR {
                continue
            } else {
                throw UnixSocketHTTPError.readFailed(errno)
            }
        }
    }

    // MARK: - Parse

    private static func parse(_ raw: Data) throws -> HTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw UnixSocketHTTPError.malformedResponse
        }

        let remainder = Data(raw[range.upperBound...])

        guard let header = String(data: raw[raw.startIndex..<range.lowerBound], encoding: .utf8)
        else {
            throw UnixSocketHTTPError.malformedResponse
        }
        let lines = header.components(separatedBy: "\r\n")

        // "HTTP/1.1 200 OK"
        guard let statusLine = lines.first else {
            throw UnixSocketHTTPError.malformedResponse
        }
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else {
            throw UnixSocketHTTPError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return HTTPResponse(status: status, body: try dechunk(remainder))
        }

        if let text = headers["content-length"], let length = Int(text) {
            guard remainder.count >= length else {
                throw UnixSocketHTTPError.malformedBody(
                    "Content-Length said \(length), got \(remainder.count)")
            }
            return HTTPResponse(status: status, body: remainder.prefix(length))
        }

        // No framing headers: the body runs to EOF, which is what Connection:
        // close buys us.
        return HTTPResponse(status: status, body: remainder)
    }

    /// Reassembles a chunked body.
    ///
    /// Each chunk is a hex length, optional `;extension`, CRLF, that many bytes,
    /// CRLF. A zero length ends it; any trailer after that is ignored, because
    /// nothing the LocalAPI sends puts anything there.
    private static func dechunk(_ raw: Data) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var out = Data()
        var cursor = raw.startIndex

        while true {
            guard let lineEnd = raw[cursor...].range(of: crlf) else {
                throw UnixSocketHTTPError.malformedBody("chunk size line is unterminated")
            }
            guard let line = String(data: Data(raw[cursor..<lineEnd.lowerBound]), encoding: .utf8)
            else {
                throw UnixSocketHTTPError.malformedBody("chunk size line is not text")
            }

            let sizeText = (line.split(separator: ";").first.map(String.init) ?? line)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw UnixSocketHTTPError.malformedBody("bad chunk size \"\(sizeText)\"")
            }

            cursor = lineEnd.upperBound
            if size == 0 { return out }

            guard raw.distance(from: cursor, to: raw.endIndex) >= size + crlf.count else {
                throw UnixSocketHTTPError.malformedBody("chunk of \(size) bytes is truncated")
            }
            let chunkEnd = raw.index(cursor, offsetBy: size)
            out.append(raw[cursor..<chunkEnd])
            cursor = raw.index(chunkEnd, offsetBy: crlf.count)
        }
    }
}
