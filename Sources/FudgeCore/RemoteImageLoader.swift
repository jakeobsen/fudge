import Foundation

/// A response to an image request: the status, the URL it ended at after redirects, its headers (names lowercased)
/// and the body as it streams in.
public struct RemoteImageResponse: Sendable {
    public var status: Int
    public var url: URL
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, url: URL, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Sends an image request. The app's is `URLSessionImageFetcher`; tests use a fake and never touch the network.
public protocol RemoteImageFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> RemoteImageResponse
}

/// Collects a body, failing as soon as it passes `limit`, whatever `Content-Length` said.
public struct BodyLimit: Sendable {
    public struct TooLarge: Error, Equatable {}

    public let limit: Int
    public private(set) var data = Data()

    public init(limit: Int) {
        self.limit = limit
    }

    public mutating func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= limit else { throw TooLarge() }
        data.append(chunk)
    }
}

/// Why an image couldn't be loaded (SPEC-059). `RemoteImageRetry` loads a retryable failure again later; the others
/// are final for the run.
public enum RemoteImageFailure: Error, Equatable, Sendable {
    /// `RemoteImageURL` refused the URL, or the redirect it ended at.
    case refused
    /// An HTTP status other than 2xx (or a 304 to a conditional request), with a 429's or 503's `Retry-After` in
    /// seconds.
    case http(Int, retryAfter: TimeInterval?)
    /// The body isn't an image.
    case notAnImage
    /// Over `RemoteImageLoader.maxBytes`, or too large to decode.
    case tooBig
    /// No complete response: no connection, a timeout, the connection lost while reading.
    case network

    /// A network error, HTTP 408, 429 or 5xx.
    public var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let status, _): status == 408 || status == 429 || (500..<600).contains(status)
        case .refused, .notAnImage, .tooBig: false
        }
    }

    /// A `Retry-After` header's wait from `now`: whole seconds, or an HTTP date. Nil when it's neither.
    public static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// What loading an image gave.
public enum RemoteImageLoad: Equatable, Sendable {
    /// The body, and when it was fetched: just now from the network, or earlier when it came from the cache.
    case loaded(Data, fetchedAt: Date)
    /// A refresh the server answered 304: the image already shown stays, and the cache's entry is fresh again.
    case unchanged(fetchedAt: Date)
    case failed(RemoteImageFailure)
}

/// Loads the https images extensions ask for, through `RemoteImageCache`: a cached body as it is, fresh or stale,
/// unless the caller is refreshing a stale one, which is revalidated; anything else from the network. Requests for
/// one URL are coalesced, and at most `maxConcurrent` run at once. When to load again is `RemoteImageRetry`'s call.
public actor RemoteImageLoader {
    public static let maxBytes = 10_000_000
    public static let timeout: TimeInterval = 15
    public static let maxConcurrent = 6

    /// The headers every request carries. `Accept-Language` replaces the user's languages.
    public static var headers: [String: String] {
        ["User-Agent": "fudge/\(FudgeVersion.current)", "Accept": "image/*", "Accept-Language": "en"]
    }

    private let cache: RemoteImageCache
    private let fetcher: any RemoteImageFetching
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var inFlight: [String: Task<RemoteImageLoad, Never>] = [:]
    private var logged: Set<String> = []
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(
        cache: RemoteImageCache, fetcher: any RemoteImageFetching, now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { message in FudgeLog.error(message) }
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.now = now
        self.log = log
    }

    /// The image body for `url`, or why there's none. A cached body comes as it is, fresh or stale. With
    /// `refreshing` (the caller shows this image already), a stale one is revalidated instead, and a 304 says
    /// `.unchanged`.
    public func load(_ url: URL, refreshing: Bool = false) async -> RemoteImageLoad {
        if let refusal = RemoteImageURL.check(url) {
            note(url, "isn't loaded (\(refusal))")
            return .failed(.refused)
        }
        let key = RemoteImageCache.key(for: url)
        let cached = cache.read(url, now: now())
        if let cached, !refreshing || RemoteImageCache.isFresh(cached.entry, now: now()) {
            return .loaded(cached.body, fetchedAt: cached.entry.fetchedAt)
        }
        let result = await (inFlight[key] ?? start(url, key: key, revalidating: cached?.entry)).value
        // A first load that joined a revalidation wants the body, which the 304 kept in the cache.
        if case .unchanged = result, !refreshing {
            guard let kept = cache.read(url, now: now()) else { return .failed(.network) }
            return .loaded(kept.body, fetchedAt: kept.entry.fetchedAt)
        }
        return result
    }

    /// Waits for every request in flight, background revalidations included.
    public func finishRequests() async {
        while let task = inFlight.values.first {
            _ = await task.value
        }
    }

    private func start(_ url: URL, key: String, revalidating entry: RemoteImageCache.Entry?) -> Task<
        RemoteImageLoad, Never
    > {
        if let task = inFlight[key] { return task }
        // The task can't start before this returns (it needs the actor), so it's in `inFlight` before it ends.
        let task = Task {
            let result = await self.fetch(url, revalidating: entry)
            self.finished(key)
            return result
        }
        inFlight[key] = task
        return task
    }

    private func finished(_ key: String) {
        inFlight[key] = nil
    }

    /// The request for `url`, conditional when there's a cached entry to revalidate.
    public static func request(for url: URL, revalidating entry: RemoteImageCache.Entry?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let etag = entry?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = entry?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    private func fetch(_ url: URL, revalidating entry: RemoteImageCache.Entry?) async -> RemoteImageLoad {
        await acquire()
        defer { release() }
        do {
            let response = try await fetcher.fetch(Self.request(for: url, revalidating: entry))
            if let refusal = RemoteImageURL.check(response.url) {
                note(url, "was redirected somewhere it isn't loaded from (\(refusal))")
                return .failed(.refused)
            }
            if response.status == 304, var entry {
                entry.fetchedAt = now()
                try? cache.update(url, entry: entry)
                return .unchanged(fetchedAt: entry.fetchedAt)
            }
            guard (200..<300).contains(response.status) else {
                note(url, "failed with HTTP \(response.status)")
                let retryAfter =
                    response.status == 429 || response.status == 503
                    ? RemoteImageFailure.retryAfter(response.headers["retry-after"], now: now()) : nil
                return .failed(.http(response.status, retryAfter: retryAfter))
            }
            if let length = response.headers["content-length"].flatMap(Int.init), length > Self.maxBytes {
                note(url, "is over \(Self.maxBytes / 1_000_000) MB")
                return .failed(.tooBig)
            }
            var body = BodyLimit(limit: Self.maxBytes)
            for try await chunk in response.body { try body.append(chunk) }
            _ = try RemoteImageDecoder.inspect(body.data)
            let fresh = RemoteImageCache.Entry(
                fetchedAt: now(), etag: response.headers["etag"], lastModified: response.headers["last-modified"])
            try? cache.store(url, body: body.data, entry: fresh, now: now())
            return .loaded(body.data, fetchedAt: fresh.fetchedAt)
        } catch is BodyLimit.TooLarge {
            note(url, "is over \(Self.maxBytes / 1_000_000) MB")
            return .failed(.tooBig)
        } catch RemoteImageDecoder.Problem.tooLarge {
            note(url, "is too large to decode")
            return .failed(.tooBig)
        } catch RemoteImageDecoder.Problem.notAnImage {
            note(url, "isn't an image")
            return .failed(.notAnImage)
        } catch {
            note(url, "failed: \(error.localizedDescription)")
            return .failed(.network)
        }
    }

    /// Logs a problem once per URL, without its query, which can carry tokens.
    private func note(_ url: URL, _ problem: String) {
        let key = url.absoluteString
        guard !logged.contains(key) else { return }
        logged.insert(key)
        var shown = URLComponents(url: url, resolvingAgainstBaseURL: false)
        shown?.query = nil
        shown?.fragment = nil
        shown?.user = nil
        shown?.password = nil
        log("image \(shown?.string ?? "?") \(problem)")
    }

    private func acquire() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        // A finishing request hands its slot straight to the first one waiting.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The one `URLSession` fudge fetches images with: no cookies, no credentials, no URL cache, 15 s, and redirects
/// only to URLs `RemoteImageURL` allows. Authentication challenges are cancelled, except server trust.
public final class URLSessionImageFetcher: NSObject, RemoteImageFetching, URLSessionTaskDelegate, @unchecked Sendable {
    // @unchecked: the session is created once and URLSession is thread-safe.
    private var session: URLSession!

    public override init() {
        super.init()
        session = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: nil)
    }

    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = RemoteImageLoader.timeout
        configuration.timeoutIntervalForResource = RemoteImageLoader.timeout
        configuration.httpMaximumConnectionsPerHost = RemoteImageLoader.maxConcurrent
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = RemoteImageLoader.headers
        return configuration
    }

    public func fetch(_ request: URLRequest) async throws -> RemoteImageResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url ?? request.url else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for case (let name as String, let value as String) in http.allHeaderFields {
            headers[name.lowercased()] = value
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var chunk = Data()
                chunk.reserveCapacity(64 * 1024)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == 64 * 1024 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RemoteImageResponse(status: http.statusCode, url: url, headers: headers, body: body)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // Returning nil ends the request with the redirect itself, which the loader treats as a failure.
        guard let url = request.url, RemoteImageURL.check(url) == nil else { return nil }
        return request
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
