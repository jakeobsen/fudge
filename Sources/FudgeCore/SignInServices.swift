import Foundation
import Observation

/// The services a sign-in server offers (SPEC-149 part B): the line under the sign-in server choice names them when the
/// server answers `GET <server>/api/services` with `{"services":[{"id":"github",…},…]}`.
///
/// Only each entry's `id` is read. Fudge keeps the ids `OAuthProviders` has, in the server's order and once each, and
/// writes its own names for them, so no text from the server reaches the page. Anything else gives
/// `SignInServer.explanation`, with no error.
public enum SignInServices {
    /// The address under the server, as `SignInServer.servicesURL` builds it.
    public static let path = "api/services"
    /// The whole request, connecting and reading included, gives up after this many seconds.
    public static let timeout: TimeInterval = 5
    /// At most this many bytes of the answer are read; more is no answer.
    public static let byteLimit = 64 * 1024
    /// At most this many names are written; with more, the first `maxNames - 1` and "and N more".
    public static let maxNames = 5

    /// The ids in a server's answer, in its order: a JSON object whose `services` is an array of objects, each with a
    /// string `id`. Other fields are ignored. Nil for anything else, or over `byteLimit` bytes.
    public static func ids(from data: Data) -> [String]? {
        guard data.count <= byteLimit,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let services = object["services"] as? [Any]
        else { return nil }
        var ids: [String] = []
        for service in services {
            guard let entry = service as? [String: Any], let id = entry["id"] as? String else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// Fudge's own names for the ids it sends to a sign-in server (`OAuthProvider.id`), in the given order, each id
    /// once. An id with several table entries takes the first entry's name; unknown ids are left out.
    public static func names(ids: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for id in ids where !seen.contains(id) {
            guard let provider = OAuthProviders.all.first(where: { $0.id == id }) else { continue }
            seen.insert(id)
            names.append(provider.name)
        }
        return names
    }

    /// The line under the choice: the names, or `SignInServer.explanation` with none.
    public static func line(names: [String]) -> String {
        guard !names.isEmpty else { return SignInServer.explanation }
        return "Extensions sign in to \(list(names)) through this server."
    }

    /// The names as an English list, as `ListFormatter` writes one in English ("A", "A and B", "A, B, and C"). Past
    /// `maxNames`, the first `maxNames - 1` and "N more", so there are never more than `maxNames` items.
    public static func list(_ names: [String]) -> String {
        var items = names
        if names.count > maxNames {
            items = Array(names.prefix(maxNames - 1)) + ["\(names.count - (maxNames - 1)) more"]
        }
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    /// Asks the server what it offers, and gives Fudge's names for it: none when the server is off, can't say, or
    /// offers nothing Fudge knows.
    public static func names(
        offeredBy server: SignInServer, using fetcher: any SignInServicesFetching
    ) async -> [String] {
        guard let url = server.servicesURL, let data = try? await fetcher.fetch(url), let ids = ids(from: data) else {
            return []
        }
        return names(ids: ids)
    }

    /// The server the line is for. "Your own server…" counts only once its address is saved and the field shows
    /// that address; while one is typed, nil, so the line is the plain one and nothing is asked.
    public static func serverOnScreen(saved: SignInServer, ownChosen: Bool, typedAddress: String) -> SignInServer? {
        if ownChosen {
            guard case .custom(let url) = saved, url.absoluteString == typedAddress else { return nil }
            return saved
        }
        return saved == .off ? nil : saved
    }

    /// The fetcher, picked once at launch: a snapshot run always gets `FixedSignInServices` with `--sign-in-services`'
    /// value, and `network` is called only when it isn't one.
    public static func fetcher(
        snapshot: Bool, snapshotValue: String?, network: () -> any SignInServicesFetching
    ) -> any SignInServicesFetching {
        snapshot ? FixedSignInServices(snapshotValue: snapshotValue) : network()
    }
}

extension SignInServer {
    /// `<server>/api/services`, built as `endpoint` builds a provider's, so a server under a path works; nil when off.
    public var servicesURL: URL? {
        guard let base = trimmedBase else { return nil }
        return URL(string: "\(base)/\(SignInServices.path)")
    }
}

/// Where the line's answer comes from: the server (`URLSessionSignInServices`), or a snapshot run's fixed answer.
public protocol SignInServicesFetching: Sendable {
    /// The body of a 200 answer to a GET of `url`, at most `SignInServices.byteLimit` bytes. Throws for anything else.
    func fetch(_ url: URL) async throws -> Data
}

/// A snapshot run's answer, never the network: `--sign-in-services "github|atlassian"`'s ids, sent as a server's
/// answer, so they go through the same reading, names, limits and joining. Without the flag there's no answer.
public struct FixedSignInServices: SignInServicesFetching {
    public struct NoAnswer: Error {}

    /// The ids it answers with; nil answers nothing.
    public let ids: [String]?

    public init(ids: [String]?) {
        self.ids = ids
    }

    /// From `--sign-in-services`' value: ids separated by `|`, spaces around them trimmed.
    public init(snapshotValue: String?) {
        ids = snapshotValue.map { value in
            value.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    public func fetch(_ url: URL) async throws -> Data {
        guard let ids else { throw NoAnswer() }
        return try JSONSerialization.data(withJSONObject: ["services": ids.map { ["id": $0] }])
    }
}

/// What a sign-in server's answer may be: a 200, and at most `SignInServices.byteLimit` bytes in all.
/// `URLSessionSignInServices` hands it the response and each piece of the body as they arrive, and stops reading at
/// the first refusal.
public struct SignInServicesBody: Sendable {
    public enum Refusal: Error, Equatable {
        case status(Int)
        case tooLarge
    }

    /// The body so far.
    public private(set) var data = Data()

    public init() {}

    /// Refuses any status but 200, and a `Content-Length` over the limit.
    public func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Refusal.status(status) }
        guard response.expectedContentLength <= Int64(SignInServices.byteLimit) else { throw Refusal.tooLarge }
    }

    /// Adds a piece of the body; refuses one that would take it over the limit.
    public mutating func append(_ piece: Data) throws {
        guard data.count + piece.count <= SignInServices.byteLimit else { throw Refusal.tooLarge }
        data.append(piece)
    }
}

/// Asks a sign-in server for its services: one GET with `User-Agent`, `Accept: application/json` and
/// `Accept-Language: en`, on an ephemeral session with no cookies, credentials or cache. The whole request gets
/// `SignInServices.timeout` seconds, and a redirect isn't followed, so it's no answer. Only a 200 is an answer.
///
/// The body is read in the session's delegate callbacks, on a queue of their own, through `SignInServicesBody`: past
/// `byteLimit` the request is cancelled at once. So the answer is decided there, whatever else keeps Swift's threads
/// busy, and the caller only hears it.
public final class URLSessionSignInServices: NSObject, SignInServicesFetching, URLSessionDataDelegate,
    @unchecked Sendable
{
    // @unchecked: the session is created once, URLSession is thread-safe, and `requests` is behind `lock`.
    private struct Request {
        var body = SignInServicesBody()
        let continuation: CheckedContinuation<Data, Error>
    }

    private let userAgent: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    /// `timeout` is `SignInServices.timeout` but in tests that mustn't depend on how busy the machine is.
    public init(userAgent: String, timeout: TimeInterval = SignInServices.timeout) {
        self.userAgent = userAgent
        self.timeout = timeout
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "URLSessionSignInServices"
        session = URLSession(configuration: Self.configuration(timeout: timeout), delegate: self, delegateQueue: queue)
    }

    public static func configuration(timeout: TimeInterval = SignInServices.timeout) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { requests[task.taskIdentifier] = Request(continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Answers the caller once; later callbacks for the task find nothing.
    private func finish(_ task: URLSessionTask, _ result: Result<Data, Error>) {
        let request = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
        request?.continuation.resume(with: result)
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try lock.withLock { try requests[dataTask.taskIdentifier]?.body.check(response) }
            completionHandler(.allow)
        } catch {
            finish(dataTask, .failure(error))
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try lock.withLock { try requests[dataTask.taskIdentifier]?.body.append(data) }
        } catch {
            finish(dataTask, .failure(error))
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { requests[task.taskIdentifier]?.body.data } ?? Data()
        finish(task, error.map { .failure($0) } ?? .success(body))
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Nil ends the request with the redirect itself, whose status isn't 200.
        completionHandler(nil)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// The line under one sign-in server choice, for the server on screen now only. A view runs `load` from
/// `.task(id:)` with `SignInServices.serverOnScreen`: each change starts over with the plain line, and an answer that
/// comes after the server changed, or after its task was cancelled, is dropped.
@MainActor
@Observable
public final class SignInServicesLine {
    /// Fudge's names for what the server on screen offers; empty until it answers.
    public private(set) var names: [String] = []
    @ObservationIgnored private var wanted: SignInServer?

    public init() {}

    /// What the line says.
    public var text: String { SignInServices.line(names: names) }

    /// Shows `server`'s services once it answers, the plain line meanwhile; nil asks nothing.
    public func load(_ server: SignInServer?, using fetcher: any SignInServicesFetching) async {
        wanted = server
        names = []
        guard let server, server.url != nil else { return }
        let found = await SignInServices.names(offeredBy: server, using: fetcher)
        guard !Task.isCancelled, wanted == server else { return }
        names = found
    }
}
