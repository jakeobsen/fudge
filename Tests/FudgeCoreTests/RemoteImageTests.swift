import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import FudgeCore

// MARK: - Which URLs are fetched

@Test(arguments: [
    ("http://example.com/a.png", RemoteImageURL.Refusal.notHTTPS),
    ("ftp://example.com/a.png", .notHTTPS),
    ("https://user:secret@example.com/a.png", .userInfo),
    ("https://localhost/a.png", .localNetwork),
    ("https://LOCALHOST./a.png", .localNetwork),
    ("https://api.localhost/a.png", .localNetwork),
    ("https://printer.local/a.png", .localNetwork),
    ("https://router.home.arpa/a.png", .localNetwork),
    ("https://nas/a.png", .localNetwork),
    ("https://127.0.0.1/a.png", .localNetwork),
    ("https://10.1.2.3/a.png", .localNetwork),
    ("https://172.16.5.4/a.png", .localNetwork),
    ("https://172.31.255.255/a.png", .localNetwork),
    ("https://192.168.1.1/a.png", .localNetwork),
    ("https://169.254.169.254/latest", .localNetwork),
    ("https://100.64.0.1/a.png", .localNetwork),
    ("https://224.0.0.1/a.png", .localNetwork),
    ("https://0.0.0.0/a.png", .localNetwork),
    // The other ways getaddrinfo reads an IPv4 address.
    ("https://127.1/a.png", .localNetwork),
    ("https://2130706433/a.png", .localNetwork),
    ("https://0x7f000001/a.png", .localNetwork),
    ("https://0177.0.0.1/a.png", .localNetwork),
    ("https://[::1]/a.png", .localNetwork),
    ("https://[::]/a.png", .localNetwork),
    ("https://[fc00::1]/a.png", .localNetwork),
    ("https://[fd12:3456::1]/a.png", .localNetwork),
    ("https://[fe80::1]/a.png", .localNetwork),
    ("https://[::ffff:192.168.1.1]/a.png", .localNetwork),
    ("https://[::ffff:7f00:1]/a.png", .localNetwork),
    ("https://[64:ff9b::a00:1]/a.png", .localNetwork),
    ("https://[2002:c0a8:101::1]/a.png", .localNetwork),
    ("https://[ff02::1]/a.png", .localNetwork),
])
func refusesURLsThatArentPublicHTTPS(text: String, refusal: RemoteImageURL.Refusal) throws {
    let url = try #require(URL(string: text))
    #expect(RemoteImageURL.check(url) == refusal)
}

@Test(arguments: [
    "https://github.com/github.png",
    "https://example.com./a.png?raycast-width=20",
    "https://8.8.8.8/a.png",
    "https://172.32.0.1/a.png",
    "https://[2606:4700:4700::1111]/a.png",
    "https://[::ffff:8.8.8.8]/a.png",
])
func allowsPublicHTTPSURLs(text: String) throws {
    #expect(RemoteImageURL.check(try #require(URL(string: text))) == nil)
}

@Test func tellsURLsFromOtherImageSources() {
    for url in ["https://a.com/x.png", "HTTP://a.com/x.png", "ftp://a.com/x", "data+x://y"] {
        #expect(RemoteImageURL.isURL(url), "\(url)")
    }
    for other in ["file:///tmp/x.png", "icon.png", "/tmp/x.png", "~/x.png", "🙂", "list-16", "1x://y"] {
        #expect(!RemoteImageURL.isURL(other), "\(other)")
    }
}

// MARK: - Raycast's size hints

@Test func readsRaycastsMarkdownImageHints() {
    #expect(
        MarkdownImageHints(source: "https://a.com/x.png?raycast-width=100&raycast-height=50")
            == MarkdownImageHints(width: 100, height: 50))
    #expect(
        MarkdownImageHints(source: "x.png?raycast-tint-color=%23ff0000&size=2")
            == MarkdownImageHints(tintColor: "#ff0000"))
    #expect(MarkdownImageHints(source: "x.png?raycast-width=abc&raycast-height=-5") == MarkdownImageHints())
    #expect(MarkdownImageHints(source: "https://a.com/x.png") == MarkdownImageHints())

    let natural = CGSize(width: 200, height: 100)
    #expect(MarkdownImageHints(width: 100).displaySize(natural: natural) == CGSize(width: 100, height: 50))
    #expect(MarkdownImageHints(height: 25).displaySize(natural: natural) == CGSize(width: 50, height: 25))
    #expect(MarkdownImageHints(width: 30, height: 40).displaySize(natural: natural) == CGSize(width: 30, height: 40))
    #expect(MarkdownImageHints().displaySize(natural: natural) == nil)
}

// MARK: - Decoding

@Test func decodesImagesAsThumbnailsAndRefusesHugeOrNonImageBodies() throws {
    #expect(try RemoteImageDecoder.inspect(png(width: 40, height: 20)) == .raster(width: 40, height: 20))
    let wide = try #require(RemoteImageDecoder.thumbnail(png(width: 4000, height: 10)))
    #expect(max(wide.width, wide.height) <= RemoteImageDecoder.maxPixelSize)

    #expect(throws: RemoteImageDecoder.Problem.tooLarge) {
        try RemoteImageDecoder.inspect(png(width: 16_385, height: 1))
    }
    #expect(throws: RemoteImageDecoder.Problem.notAnImage) {
        try RemoteImageDecoder.inspect(Data("<html><body>Not found</body></html>".utf8))
    }

    let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.utf8)
    #expect(try RemoteImageDecoder.inspect(svg) == .svg)
    let bigSVG = svg + Data(repeating: 0x20, count: RemoteImageDecoder.maxSVGBytes)
    #expect(throws: RemoteImageDecoder.Problem.tooLarge) { try RemoteImageDecoder.inspect(bigSVG) }
}

@Test func linksInAnSVGAreUnwrappedForDrawing() {
    let svg = #"<svg><a xlink:href="https://x" target="_parent"><rect/><animate/></a><A href='y'><circle/></A ></svg>"#
    let drawn = String(decoding: RemoteImageDecoder.svgForDrawing(Data(svg.utf8)), as: UTF8.self)
    #expect(drawn == "<svg><rect/><animate/><circle/></svg>")
}

// MARK: - The loader

@Test func aFirstLoadFetchesWithFudgesHeadersAndIsCached() async throws {
    let image = png(width: 8, height: 8)
    let fetcher = FakeImageFetcher { request in
        .ok(request.url!, image, headers: ["etag": "\"v1\"", "last-modified": "Tue, 17 Nov 2026 10:00:00 GMT"])
    }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!

    #expect(await loader.load(url) == image)
    let request = try #require(fetcher.requests.first)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "fudge/\(FudgeVersion.current)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
    #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(request.timeoutInterval == 15)
    #expect(
        cache.read(url)?.entry == .init(fetchedAt: start, etag: "\"v1\"", lastModified: "Tue, 17 Nov 2026 10:00:00 GMT")
    )

    // Fresh: no second request.
    #expect(await loader.load(url) == image)
    #expect(fetcher.requests.count == 1)
}

@Test func aStaleEntryShowsAtOnceAndA304KeepsIt() async throws {
    let old = png(width: 8, height: 8)
    let fetcher = FakeImageFetcher { request in .status(304, request.url!) }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!
    try cache.store(url, body: old, entry: .init(fetchedAt: start - 25 * 3600, etag: "\"v1\"", lastModified: "then"))

    #expect(await loader.load(url) == old)
    await loader.finishRequests()
    let request = try #require(fetcher.requests.first)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "then")
    #expect(cache.read(url)?.body == old)
    #expect(cache.read(url)?.entry == .init(fetchedAt: start, etag: "\"v1\"", lastModified: "then"))

    // Revalidated once: loading again doesn't ask again.
    #expect(await loader.load(url) == old)
    #expect(fetcher.requests.count == 1)
}

@Test func aStaleEntryIsReplacedWhenTheServerSendsANewBody() async throws {
    let old = png(width: 8, height: 8)
    let new = png(width: 16, height: 16)
    let fetcher = FakeImageFetcher { request in .ok(request.url!, new, headers: ["etag": "\"v2\""]) }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!
    try cache.store(url, body: old, entry: .init(fetchedAt: start - 25 * 3600, etag: "\"v1\""))

    #expect(await loader.load(url) == old, "the old image shows at once")
    await loader.finishRequests()
    #expect(cache.read(url)?.body == new)
    #expect(cache.read(url)?.entry == .init(fetchedAt: start, etag: "\"v2\""))
}

@Test func requestsForOneURLAreCoalesced() async throws {
    let image = png(width: 8, height: 8)
    let fetcher = FakeImageFetcher { request in
        try await Task.sleep(for: .milliseconds(100))
        return .ok(request.url!, image)
    }
    let (loader, _) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!
    async let first = loader.load(url)
    async let second = loader.load(url)
    #expect(await [first, second] == [image, image])
    #expect(fetcher.requests.count == 1)
}

@Test func atMostSixRequestsRunAtOnce() async throws {
    let image = png(width: 8, height: 8)
    let fetcher = FakeImageFetcher { request in
        try await Task.sleep(for: .milliseconds(50))
        return .ok(request.url!, image)
    }
    let (loader, _) = try makeLoader(fetcher)
    await withTaskGroup(of: Data?.self) { group in
        for index in 0..<10 {
            group.addTask { await loader.load(URL(string: "https://example.com/\(index).png")!) }
        }
        for await body in group { #expect(body == image) }
    }
    #expect(fetcher.requests.count == 10)
    #expect(fetcher.mostAtOnce == 6)
}

@Test(arguments: [nil, "100"])
func aBodyOverTheLimitIsDroppedWhateverContentLengthSays(contentLength: String?) async throws {
    let chunk = Data(repeating: 0, count: 1_000_000)
    let fetcher = FakeImageFetcher { request in
        RemoteImageResponse(
            status: 200, url: request.url!, headers: contentLength.map { ["content-length": $0] } ?? [:],
            body: .chunks(Array(repeating: chunk, count: 10) + [Data([0])]))
    }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/big.png")!
    #expect(await loader.load(url) == nil)
    #expect(cache.read(url) == nil)
}

@Test func aContentLengthOverTheLimitIsRefusedBeforeReading() async throws {
    let fetcher = FakeImageFetcher { request in
        RemoteImageResponse(
            status: 200, url: request.url!, headers: ["content-length": "10000001"],
            body: AsyncThrowingStream(unfolding: {
                Issue.record("the body was read")
                return nil
            }))
    }
    let (loader, _) = try makeLoader(fetcher)
    #expect(await loader.load(URL(string: "https://example.com/big.png")!) == nil)
}

@Test func aBodyThatIsntAnImageIsntCached() async throws {
    let fetcher = FakeImageFetcher { request in .ok(request.url!, Data("<html>Sign in</html>".utf8)) }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!
    #expect(await loader.load(url) == nil)
    #expect(cache.read(url) == nil)
}

@Test func anOversizedImageIsRefusedFromItsHeader() async throws {
    let huge = png(width: 16_385, height: 1)
    let fetcher = FakeImageFetcher { request in .ok(request.url!, huge) }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/wide.png")!
    #expect(await loader.load(url) == nil)
    #expect(cache.read(url) == nil)
}

@Test func refusedURLsAreNeverFetchedAndLoggedOnce() async throws {
    let fetcher = FakeImageFetcher { request in .ok(request.url!, png(width: 1, height: 1)) }
    let log = LogLines()
    let (loader, _) = try makeLoader(fetcher, log: log)
    let url = URL(string: "http://example.com/a.png?token=secret")!
    #expect(await loader.load(url) == nil)
    #expect(await loader.load(url) == nil)
    #expect(fetcher.requests.isEmpty)
    #expect(log.lines.count == 1)
    #expect(log.lines.first?.contains("secret") == false, "the query isn't logged")
}

@Test func aRedirectToARefusedURLFails() async throws {
    let fetcher = FakeImageFetcher { _ in .ok(URL(string: "https://192.168.1.1/a.png")!, png(width: 1, height: 1)) }
    let (loader, cache) = try makeLoader(fetcher)
    let url = URL(string: "https://example.com/a.png")!
    #expect(await loader.load(url) == nil)
    #expect(cache.read(url) == nil)
}

@Test func theSessionFollowsOnlyRedirectsToAllowedURLs() async throws {
    let fetcher = URLSessionImageFetcher()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://example.com/a.png")!)  // never resumed
    let response = HTTPURLResponse(
        url: URL(string: "https://example.com/a.png")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    for (target, allowed) in [
        ("https://cdn.example.com/a.png", true), ("http://example.com/a.png", false),
        ("https://192.168.1.1/a.png", false), ("https://localhost/a.png", false),
    ] {
        let request = URLRequest(url: URL(string: target)!)
        let followed = await fetcher.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request)
        #expect((followed != nil) == allowed, "\(target)")
    }
}

@Test func theSessionHasNoCookiesCredentialsOrCache() {
    let configuration = URLSessionImageFetcher.configuration()
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.timeoutIntervalForRequest == 15)
}

// MARK: - The cache

@Test func theLeastRecentlyUsedEntriesGoPastTheCap() throws {
    let cache = RemoteImageCache(directory: try Fixtures.temporaryDirectory(), capacity: 3500)
    let urls = (0..<4).map { URL(string: "https://example.com/\($0).png")! }
    let body = Data(repeating: 1, count: 1000)
    for index in 0..<3 {
        try cache.store(
            urls[index], body: body, entry: .init(fetchedAt: start), now: Date(timeIntervalSince1970: Double(index)))
    }
    _ = cache.read(urls[0], now: Date(timeIntervalSince1970: 10))  // used again: now the newest
    try cache.store(urls[3], body: body, entry: .init(fetchedAt: start), now: Date(timeIntervalSince1970: 11))
    #expect(cache.read(urls[1]) == nil, "the least recently used goes")
    for kept in [0, 2, 3] { #expect(cache.read(urls[kept]) != nil, "\(kept)") }
}

// MARK: - Helpers

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func makeLoader(
    _ fetcher: FakeImageFetcher, log: LogLines = LogLines()
) throws -> (RemoteImageLoader, RemoteImageCache) {
    let cache = RemoteImageCache(directory: try Fixtures.temporaryDirectory().appendingPathComponent("image-cache"))
    return (RemoteImageLoader(cache: cache, fetcher: fetcher, now: { start }, log: { log.append($0) }), cache)
}

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private final class FakeImageFetcher: RemoteImageFetching, @unchecked Sendable {
    // @unchecked: every mutable field is behind `lock`.
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var running = 0
    private var most = 0
    private let respond: @Sendable (URLRequest) async throws -> RemoteImageResponse

    init(_ respond: @escaping @Sendable (URLRequest) async throws -> RemoteImageResponse) {
        self.respond = respond
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var mostAtOnce: Int { lock.withLock { most } }

    func fetch(_ request: URLRequest) async throws -> RemoteImageResponse {
        lock.withLock {
            recorded.append(request)
            running += 1
            most = max(most, running)
        }
        defer { lock.withLock { running -= 1 } }
        return try await respond(request)
    }
}

private final class LogLines: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

extension RemoteImageResponse {
    fileprivate static func ok(_ url: URL, _ body: Data, headers: [String: String] = [:]) -> RemoteImageResponse {
        RemoteImageResponse(status: 200, url: url, headers: headers, body: .chunks([body]))
    }

    fileprivate static func status(_ status: Int, _ url: URL) -> RemoteImageResponse {
        RemoteImageResponse(status: status, url: url, body: .chunks([]))
    }
}

extension AsyncThrowingStream where Element == Data, Failure == Error {
    fileprivate static func chunks(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

@Test func hintedSizesFitThePaneKeepingTheirProportions() {
    let bounds = CGSize(width: 560, height: 320)
    let natural = CGSize(width: 1000, height: 500)
    let wide = CGSize(width: 560, height: 280)
    #expect(MarkdownImageHints(width: 600).displaySize(natural: natural, fitting: bounds) == wide)
    #expect(
        MarkdownImageHints(width: 5000).displaySize(natural: natural, fitting: bounds) == wide,
        "no wider than the pane")
    #expect(
        MarkdownImageHints(width: 100, height: 400).displaySize(natural: natural, fitting: bounds)
            == CGSize(width: 80, height: 320), "height bounds it too")
    #expect(
        MarkdownImageHints(width: 64).displaySize(natural: natural, fitting: bounds) == CGSize(width: 64, height: 32),
        "never scaled up")
    #expect(MarkdownImageHints().displaySize(natural: natural, fitting: bounds) == nil, "no hint")
}

/// Counts how many hold a slot at once.
private actor SlotCounter {
    var now = 0
    var most = 0
    func enter() {
        now += 1
        most = max(most, now)
    }
    func leave() { now -= 1 }
}

@Test func theLimiterLetsOnlyItsLimitRunAtOnce() async {
    let limiter = AsyncLimiter(limit: 2)
    let counter = SlotCounter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                await limiter.acquire()
                await counter.enter()
                try? await Task.sleep(for: .milliseconds(20))
                await counter.leave()
                await limiter.release()
            }
        }
    }
    #expect(await counter.most == 2)
    #expect(await counter.now == 0)
}
