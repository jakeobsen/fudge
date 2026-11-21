import Foundation
import FudgeCore
import Network
import Security

// The app's side of OAuth sign-in through a fudge-oauth relay (SPEC-056): the Keychain, and the loopback listener the
// browser returns to. The rules (which providers, the callback's checks, what's stored) are in core's SignIn.swift.

/// Sign-ins in the login Keychain: generic passwords under `OAuthTokenStore.service`, one per account
/// (`<extension>/<providerId>`), readable only on this Mac. Clipboard history keeps its key the same way, under its own
/// service (`ClipboardHistoryStore.keychainService`).
struct KeychainSecretStore: SecretStore {
    var service = OAuthTokenStore.service
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused: \(reason)"
        }
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func read(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Fudge sign-in (\(account))"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func accounts() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// The loopback listener a sign-in's browser returns to: `127.0.0.1` on a free port, path
/// `/oauth/callback/<random>`. It answers only while a sign-in waits, takes one `GET` on that exact path, and closes
/// after it, or when the sign-in ends.
final class OAuthLoopback: @unchecked Sendable {
    enum Outcome: Equatable {
        case callback(OAuthCallback)
        case timedOut
        case cancelled

        /// The browser came back with a code.
        var isCode: Bool { if case .callback(.code) = self { true } else { false } }
    }

    let path = "/oauth/callback/\(OAuthCallback.randomToken())"
    private(set) var port: UInt16 = 0
    var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fudge.oauth.loopback")
    // Guarded by `queue`.
    private var state: String?
    private var waiting: CheckedContinuation<Outcome, Never>?
    private var closed = false
    private var starting: CheckedContinuation<Void, Error>?

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts listening on a free port of `127.0.0.1`.
    static func start() async throws -> OAuthLoopback {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let loopback = OAuthLoopback(listener: try NWListener(using: parameters))
        try await loopback.begin()
        return loopback
    }

    private func begin() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // Called on `queue`, once `start` has run there.
        listener.stateUpdateHandler = { [weak self] state in self?.started(state) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.starting = continuation
                self.listener.start(queue: self.queue)
            }
        }
    }

    // Called on `queue`.
    private func started(_ state: NWListener.State) {
        guard let starting else { return }
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            self.starting = nil
            starting.resume()
        case .failed(let error):
            self.starting = nil
            starting.resume(throwing: error)
        case .cancelled:
            self.starting = nil
            starting.resume(throwing: CancellationError())
        default:
            break
        }
    }

    /// Waits for the callback carrying `state`, for up to `timeout`.
    func wait(state: String, timeout: TimeInterval) async -> Outcome {
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            queue.async {
                guard !self.closed else { return continuation.resume(returning: .cancelled) }
                self.state = state
                self.waiting = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.timedOut) }
            }
        }
        close()
        return outcome
    }

    /// Ends a wait as cancelled (Esc, the command going away) and closes the listener.
    func cancel() {
        queue.async { self.finish(.cancelled) }
        close()
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.listener.cancel()
            self.finish(.cancelled)
        }
    }

    // Called on `queue`.
    private func finish(_ outcome: Outcome) {
        guard let waiting else { return }
        self.waiting = nil
        state = nil
        waiting.resume(returning: outcome)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n".utf8)) {
                self.answer(connection, requestLine: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if buffer.count >= 8192 || complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    // Called on `queue`.
    private func answer(_ connection: NWConnection, requestLine: String) {
        guard let state, waiting != nil else { return respond(connection, status: "404 Not Found", body: nil) }
        let callback = OAuthCallback.read(requestLine: requestLine, path: path, state: state)
        // A wrong path or state is answered and ignored: only this sign-in's own callback ends the wait.
        guard callback.endsWait else {
            let status = callback == .notFound ? "404 Not Found" : "400 Bad Request"
            return respond(connection, status: status, body: nil)
        }
        let signedIn = if case .code = callback { true } else { false }
        respond(
            connection, status: signedIn ? "200 OK" : "400 Bad Request", body: OAuthCallback.page(signedIn: signedIn))
        finish(.callback(callback))
        closed = true
        listener.cancel()
    }

    private func respond(_ connection: NWConnection, status: String, body: String?) {
        let content = Data((body ?? "Not found.").utf8)
        let type = body == nil ? "text/plain" : "text/html"
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(content.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + content,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// "Sign in to <provider>" in the launcher, while an extension signs in.
struct SignInPrompt: Equatable {
    var session: String
    var providerName: String
    var description: String?
    var icon: JSONValue?
    /// After ↵: the browser is open, and the callback is awaited.
    var waiting = false
}
