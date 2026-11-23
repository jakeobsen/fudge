import Foundation
import Network

/// An HTTP server on 127.0.0.1 for tests, so no test reaches a real server: every connection reads one request head,
/// keeps it, and gets `reply`. Stop it with `stop()`.
final class LocalHTTPStub: @unchecked Sendable {
    // @unchecked: its state is behind `lock`, and the listener and connections run on `queue`.
    enum Reply: Sendable {
        /// The status, header lines ("Name: value") and body, then the connection closes.
        case answer(status: Int, headers: [String], body: Data)
        /// A 200 with the header lines and `first`, then `chunk` every `interval` seconds, `count` times, then the
        /// close. With `count: 0` nothing follows `first`, and the connection stays open until the client closes it or
        /// `stop()`.
        case drip(headers: [String], first: Data, chunk: Data, interval: TimeInterval, count: Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPStub")
    private let lock = NSLock()
    private let reply: Reply
    private var heads: [String] = []
    private var closes: [TimeInterval] = []
    private var closedByStub = Set<ObjectIdentifier>()
    private var connections: [NWConnection] = []

    /// A 200, 404 or any status with a body and its `Content-Length`.
    static func answer(_ status: Int, _ body: String, headers: [String] = []) -> Reply {
        let data = Data(body.utf8)
        return .answer(status: status, headers: headers + ["Content-Length: \(data.count)"], body: data)
    }

    /// Starts listening, and gives the server's base URL, `http://127.0.0.1:<port>`.
    static func start(_ reply: Reply) async throws -> (LocalHTTPStub, URL) {
        let stub = try LocalHTTPStub(reply)
        let port = try await stub.listen()
        return (stub, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private init(_ reply: Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.reply = reply
    }

    /// The request heads received so far, each from its request line to the blank line.
    var requests: [String] { lock.withLock { heads } }

    /// For a `.drip` reply: how long after its connection opened the client closed each one, so far. A connection the
    /// stub ends itself, after its last chunk, isn't counted. `stop()` isn't the stub ending one, so its closes count:
    /// read this before `stop()`.
    var clientCloses: [TimeInterval] { lock.withLock { closes } }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    private func listen() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, Data(), opened: Date())
    }

    private func read(_ connection: NWConnection, _ received: Data, opened: Date) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                self.lock.withLock { self.heads.append(head) }
                self.respond(connection, opened: opened)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, received, opened: opened)
            }
        }
    }

    /// Notes when the client closes the connection (or the stub ends it, after its last chunk).
    private func watchClose(_ connection: NWConnection, opened: Date) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, done, error in
            guard let self else { return }
            if done || error != nil {
                self.lock.withLock {
                    if !self.closedByStub.contains(ObjectIdentifier(connection)) {
                        self.closes.append(Date().timeIntervalSince(opened))
                    }
                }
            } else {
                self.watchClose(connection, opened: opened)
            }
        }
    }

    private func respond(_ connection: NWConnection, opened: Date) {
        switch reply {
        case .answer(let status, let headers, let body):
            send(connection, head(status: status, headers: headers) + body) { connection.cancel() }
        case .drip(let headers, let first, let chunk, let interval, let count):
            send(connection, head(status: 200, headers: headers) + first) {}
            watchClose(connection, opened: opened)
            for index in 0..<count {
                queue.asyncAfter(deadline: .now() + interval * Double(index + 1)) { [weak self] in
                    guard let self else { return }
                    let last = index == count - 1
                    if last { lock.withLock { _ = closedByStub.insert(ObjectIdentifier(connection)) } }
                    send(connection, chunk) { if last { connection.cancel() } }
                }
            }
        }
    }

    private func head(status: Int, headers: [String]) -> Data {
        let lines = ["HTTP/1.1 \(status) Stub"] + headers + ["Connection: close", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func send(_ connection: NWConnection, _ data: Data, then: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in then() })
    }
}

/// True the first time `set()` is called, false after.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}
