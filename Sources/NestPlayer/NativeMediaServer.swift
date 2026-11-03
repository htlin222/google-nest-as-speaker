import Foundation
import Network

private func traceNativeHTTP(_ message: String) {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--cast-silence-smoke") {
        try? FileHandle.standardError.write(contentsOf: Data(("NativeHTTP " + message + "\n").utf8))
    }
    #endif
}

struct MediaByteRange: Equatable, Sendable {
    let start: UInt64
    let length: UInt64

    /// A single HTTP byte range. Reject malformed/multipart input rather than
    /// silently returning a different portion of the file.
    static func parse(_ value: String, size: UInt64) -> Self? {
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let halves = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        func number(_ text: Substring) -> UInt64? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt64(text)
        }
        if halves[0].isEmpty {
            guard let suffix = number(halves[1]), suffix > 0 else { return nil }
            let length = min(size, suffix)
            return Self(start: size - length, length: length)
        }
        guard let start = number(halves[0]), start < size else { return nil }
        let end: UInt64
        if halves[1].isEmpty { end = size - 1 }
        else {
            guard let requested = number(halves[1]), requested >= start else { return nil }
            end = min(requested, size - 1)
        }
        return Self(start: start, length: end - start + 1)
    }
}

enum NativeMediaServerError: LocalizedError {
    case startFailed
    var errorDescription: String? { "Could not start the local media server. Allow local network access and try again." }
}

/// The native process retains the security-scoped grant and reads the file.
/// The Cast service receives only an opaque HTTP capability, never a file path.
/// All mutable state is confined to `queue`; each client sends at most one
/// 64 KiB chunk at a time, with eight concurrent clients and bounded headers.
final class NativeMediaServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.htlin.nest-player.media", qos: .userInitiated)
    private let listener: NWListener
    private let file: URL
    private let contentType: String
    private let path = "/" + UUID().uuidString + "/audio"
    private var clients: [UUID: MediaHTTPClient] = [:]
    private var startup: CheckedContinuation<URL, any Error>?
    private var closed = false

    private init(file: URL, contentType: String) throws {
        self.file = file
        self.contentType = contentType
        listener = try NWListener(using: .tcp, on: .any)
    }

    // https://developer.apple.com/documentation/network/nwlistener
    static func serve(file: URL, contentType: String) async throws -> (server: NativeMediaServer, url: URL) {
        let server = try NativeMediaServer(file: file, contentType: contentType)
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                server.queue.async { server.start(continuation) }
            }
        } onCancel: { server.close() }
        try Task.checkCancellation()
        return (server, url)
    }

    func close() {
        queue.async { self.finish() }
    }

    private func start(_ continuation: CheckedContinuation<URL, any Error>) {
        guard !closed else { continuation.resume(throwing: CancellationError()); return }
        startup = continuation
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else { self.finish(); return }
                self.startup?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)")!)
                self.startup = nil
            case .failed: self.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            traceNativeHTTP("accepted connection")
            guard let self, !self.closed, self.clients.count < 8 else { connection.cancel(); return }
            let id = UUID()
            let client = MediaHTTPClient(connection: connection, queue: self.queue, file: self.file,
                                         contentType: self.contentType, path: self.path) { [weak self] in
                self?.clients.removeValue(forKey: id)
            }
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.startup != nil { self?.finish() }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        startup?.resume(throwing: NativeMediaServerError.startFailed)
        startup = nil
        listener.cancel()
        let active = Array(clients.values)
        clients.removeAll()
        for client in active { client.close() }
    }
}

/// Owned by NativeMediaServer's serial queue, including every Network callback.
private final class MediaHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let file: URL
    private let contentType: String
    private let path: String
    private let onClose: @Sendable () -> Void
    private var headers = Data()
    private var handle: FileHandle?
    private var remaining: UInt64 = 0
    private var closed = false
    private var lastActivity = Date()

    init(connection: NWConnection, queue: DispatchQueue, file: URL, contentType: String,
         path: String, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.file = file
        self.contentType = contentType
        self.path = path
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receive()
        checkIdle()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle?.close()
        handle = nil
        connection.cancel()
        onClose()
    }

    private func checkIdle() {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastActivity) >= 10 { self.close() }
            else { self.checkIdle() }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.headers.append(data) }
            guard self.headers.count <= 8192 else { self.reply("431 Request Header Fields Too Large"); return }
            if self.headers.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond()
            } else if complete || error != nil { self.close() }
            else { self.receive() }
        }
    }

    private func respond() {
        guard let text = String(data: headers, encoding: .utf8) else { reply("400 Bad Request"); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(request[2]) else { reply("400 Bad Request"); return }
        guard request[0] == "GET" || request[0] == "HEAD" else { reply("405 Method Not Allowed"); return }
        guard request[1] == path else { reply("404 Not Found"); return }
        traceNativeHTTP("method=\(request[0]) authorized=true")
        let ranges = lines.dropFirst().filter { $0.lowercased().hasPrefix("range:") }
        guard ranges.count <= 1 else { reply("400 Bad Request"); return }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            self.handle = handle
            let size = try handle.seekToEnd()
            var range = MediaByteRange(start: 0, length: size)
            if let header = ranges.first {
                let value = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard let parsed = MediaByteRange.parse(value, size: size) else {
                    reply("416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n"); return
                }
                range = parsed
            }
            try handle.seek(toOffset: range.start)
            remaining = request[0] == "HEAD" ? 0 : range.length
            var extra = "Accept-Ranges: bytes\r\nContent-Type: \(contentType)\r\n"
            if !ranges.isEmpty {
                extra += "Content-Range: bytes \(range.start)-\(range.start + range.length - 1)/\(size)\r\n"
            }
            let status = ranges.isEmpty ? "200 OK" : "206 Partial Content"
            traceNativeHTTP("status=\(status) start=\(range.start) length=\(range.length) size=\(size)")
            send(Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: \(range.length)\r\nConnection: close\r\n\r\n".utf8))
        } catch { reply("404 Not Found") }
    }

    private func reply(_ status: String, extra: String = "") {
        traceNativeHTTP("status=\(status)")
        remaining = 0
        send(Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    private func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error { traceNativeHTTP("send failed: \(error)"); self.close(); return }
            traceNativeHTTP("send processed bytes=\(data.count) remaining=\(self.remaining)")
            self.lastActivity = Date()
            guard self.remaining > 0, let handle = self.handle else { self.close(); return }
            do {
                let chunk = try handle.read(upToCount: Int(min(self.remaining, 64 * 1024))) ?? Data()
                guard !chunk.isEmpty else { self.close(); return }
                self.remaining -= UInt64(chunk.count)
                self.send(chunk)
            } catch { self.close() }
        })
    }

}
