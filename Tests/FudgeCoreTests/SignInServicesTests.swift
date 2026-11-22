import Foundation
import Testing

@testable import FudgeCore

// SPEC-149 part B: the line under the sign-in server choice names the services the server on screen offers. Fudge
// reads only ids and writes its own names. The requests here go to `LocalHTTPStub` on 127.0.0.1 or to fakes; no test
// reaches a real sign-in server.

private let plain = "Extensions sign in to services through this server."
private let atlassian = "Atlassian (Jira, Confluence)"

private func answer(_ json: String) -> Data { Data(json.utf8) }

// MARK: - Reading the answer

@Test func theAnswersIdsAreReadInTheServersOrder() {
    #expect(
        SignInServices.ids(
            from: answer(#"{"services":[{"id":"github","title":"GitHub"},{"id":"atlassian","title":"Atlassian"}]}"#))
            == ["github", "atlassian"])
    #expect(SignInServices.ids(from: answer(#"{"services":[]}"#)) == [])
}

@Test func otherFieldsAreIgnored() {
    #expect(
        SignInServices.ids(
            from: answer(
                #"{"version":"0.5.0","services":[{"id":"zoom","title":"Z","callback":"https://x/","n":1}],"extra":[1]}"#
            )) == ["zoom"])
}

@Test func anAnswerOfAnotherShapeIsNoAnswer() {
    for json in [
        "", "not json", "[]", #"[{"id":"github"}]"#, "{}", #"{"services":null}"#, #"{"services":"github"}"#,
        #"{"services":{"id":"github"}}"#, #"{"services":["github"]}"#, #"{"services":[{"id":1}]}"#,
        #"{"services":[{"id":true}]}"#, #"{"services":[{"id":null}]}"#, #"{"services":[{"title":"GitHub"}]}"#,
        #"{"services":[{"id":"github"},{"id":["atlassian"]}]}"#,
    ] {
        #expect(SignInServices.ids(from: answer(json)) == nil, "\(json)")
    }
}

@Test func anAnswerOverTheByteLimitIsNoAnswer() {
    let padding = String(repeating: " ", count: SignInServices.byteLimit)
    #expect(SignInServices.ids(from: answer(#"{"services":[{"id":"github"}]}"# + padding)) == nil)
    let fits = #"{"services":[{"id":"github"}]}"#
    let padded = fits + String(repeating: " ", count: SignInServices.byteLimit - fits.utf8.count)
    #expect(padded.utf8.count == 64 * 1024)
    #expect(SignInServices.ids(from: answer(padded)) == ["github"])
}

// MARK: - Fudge's own names

@Test func onlyIdsFudgeSendsToASignInServerAreNamedByFudgesNamesOnceEachInTheServersOrder() {
    #expect(
        SignInServices.names(ids: ["atlassian", "nope", "github", "atlassian", "github", "GitHub"]) == [
            atlassian, "GitHub",
        ])
    #expect(SignInServices.names(ids: ["linear", "zoom", "notion"]) == ["Linear", "Zoom", "Notion"])
    #expect(SignInServices.names(ids: ["jira", "", "unknown"]) == [])
    // Every relay id in the table has a name, and entries that share an id share it.
    for provider in OAuthProviders.all {
        #expect(SignInServices.names(ids: [provider.id]) == [provider.name], "\(provider.id)")
    }
}

@Test func aServersTitleNeverReachesTheLine() {
    let json = #"{"services":[{"id":"github","title":"Sign in here: evil.example"},{"id":"x","title":"Phish"}]}"#
    let line = SignInServices.line(names: SignInServices.names(ids: SignInServices.ids(from: answer(json)) ?? []))
    #expect(line == "Extensions sign in to GitHub through this server.")
}

// MARK: - The line

@Test func theLineNamesTheServicesOrSaysThePlainLine() {
    #expect(SignInServices.line(names: []) == plain)
    #expect(SignInServer.explanation == plain)
    #expect(SignInServices.line(names: ["GitHub"]) == "Extensions sign in to GitHub through this server.")
    #expect(
        SignInServices.line(names: ["GitHub", atlassian])
            == "Extensions sign in to GitHub and Atlassian (Jira, Confluence) through this server.")
    #expect(
        SignInServices.line(names: ["GitHub", "Linear", "Slack"])
            == "Extensions sign in to GitHub, Linear, and Slack through this server.")
}

@Test func pastFiveNamesTheRestAreAndNMore() {
    let names = ["A", "B", "C", "D", "E", "F", "G", "H"]
    #expect(SignInServices.maxNames == 5)
    #expect(SignInServices.list(Array(names.prefix(5))) == "A, B, C, D, and E")
    #expect(SignInServices.list(Array(names.prefix(6))) == "A, B, C, D, and 2 more")
    #expect(SignInServices.list(names) == "A, B, C, D, and 4 more")
    let all = SignInServices.names(ids: OAuthProviders.all.map(\.id))
    #expect(
        SignInServices.line(names: all)
            == "Extensions sign in to GitHub, Linear, Slack, Asana, and \(all.count - 4) more through this server.")
}

@Test func theListIsJoinedAsListFormatterJoinsEnglish() {
    let formatter = ListFormatter()
    formatter.locale = Locale(identifier: "en_US")
    let names = ["GitHub", atlassian, "Linear", "Slack", "Asana"]
    for count in 1...SignInServices.maxNames {
        let some = Array(names.prefix(count))
        #expect(SignInServices.list(some) == formatter.string(from: some), "\(count)")
    }
}

// MARK: - The address

@Test func theAddressIsUnderTheServerAsAProvidersEndpointIs() {
    #expect(SignInServer.off.servicesURL == nil)
    #expect(
        SignInServer.fudge.servicesURL?.absoluteString == SignInServer.fudgeURL.absoluteString + "/api/services")
    for (server, expected) in [
        ("https://sign-in.example.com", "https://sign-in.example.com/api/services"),
        ("https://sign-in.example.com/", "https://sign-in.example.com/api/services"),
        ("https://host.example/relay/", "https://host.example/relay/api/services"),
        ("https://host.example/relay", "https://host.example/relay/api/services"),
        ("http://localhost:8080", "http://localhost:8080/api/services"),
    ] {
        let custom = SignInServer.custom(URL(string: server)!)
        #expect(custom.servicesURL?.absoluteString == expected, "\(server)")
        // The same base as the provider endpoints.
        let github = OAuthProviders.all[0]
        #expect(
            custom.endpoint(github, "token") == expected.replacingOccurrences(of: "api/services", with: "github/token"))
    }
}

// MARK: - The server on screen

@Test func anAddressOfYourOwnCountsOnlyOnceSavedAndShown() {
    let own = SignInServer.custom(URL(string: "https://sign-in.example.com")!)
    #expect(SignInServices.serverOnScreen(saved: .off, ownChosen: false, typedAddress: "") == nil)
    #expect(SignInServices.serverOnScreen(saved: .fudge, ownChosen: false, typedAddress: "") == .fudge)
    // "Your own server…" picked, and the address is being typed: the saved server is still Fudge's, or off.
    #expect(SignInServices.serverOnScreen(saved: .fudge, ownChosen: true, typedAddress: "https://new.example") == nil)
    #expect(SignInServices.serverOnScreen(saved: .off, ownChosen: true, typedAddress: "") == nil)
    // Saved, and the field shows it.
    #expect(
        SignInServices.serverOnScreen(saved: own, ownChosen: true, typedAddress: "https://sign-in.example.com") == own)
    // Saved, and another address is being typed over it.
    #expect(
        SignInServices.serverOnScreen(saved: own, ownChosen: true, typedAddress: "https://sign-in.example.co") == nil)
}

// MARK: - Only the server on screen now

/// A fetcher whose answers wait until the test gives them, and which records what it's asked.
private actor GatedFetcher: SignInServicesFetching {
    private(set) var asked: [URL] = []
    private var waiting: [URL: CheckedContinuation<Data, Error>] = [:]

    func fetch(_ url: URL) async throws -> Data {
        asked.append(url)
        return try await withCheckedThrowingContinuation { waiting[url] = $0 }
    }

    struct NotAsked: Error {
        let url: URL
    }

    /// Answers the request for `url`; throws when there's none, so a test fails rather than waits for ever.
    func answer(_ url: URL, ids: [String]) throws {
        guard let request = waiting.removeValue(forKey: url) else { throw NotAsked(url: url) }
        request.resume(returning: try FixedSignInServices(ids: ids).fetchNow())
    }

    func waitUntilAsked(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        // A request is waiting as soon as it's recorded: both happen in one turn of this actor.
        while asked.count < count {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension FixedSignInServices {
    fileprivate func fetchNow() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["services": (ids ?? []).map { ["id": $0] }])
    }
}

/// A fetcher that must never be asked.
private struct RecordingFetcher: SignInServicesFetching {
    let asked = Locked<[URL]>([])
    func fetch(_ url: URL) async throws -> Data {
        asked.mutate { $0.append(url) }
        throw FixedSignInServices.NoAnswer()
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value { lock.withLock { value } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

@MainActor @Test func aLateAnswerForTheServerBeforeNeverShows() async throws {
    let line = SignInServicesLine()
    let fetcher = GatedFetcher()
    let first = SignInServer.custom(URL(string: "https://first.example")!)
    let second = SignInServer.custom(URL(string: "https://second.example/")!)
    let loadingFirst = Task { await line.load(first, using: fetcher) }
    try await fetcher.waitUntilAsked(1)
    #expect(line.text == plain)
    // The choice changes while the first server's request is out; its task isn't even cancelled.
    let loadingSecond = Task { await line.load(second, using: fetcher) }
    try await fetcher.waitUntilAsked(2)
    try await fetcher.answer(first.servicesURL!, ids: ["github"])
    await loadingFirst.value
    #expect(line.names == [])
    #expect(line.text == plain)
    try await fetcher.answer(second.servicesURL!, ids: ["atlassian"])
    await loadingSecond.value
    #expect(line.text == "Extensions sign in to Atlassian (Jira, Confluence) through this server.")
    #expect(await fetcher.asked == [first.servicesURL!, second.servicesURL!])
}

@MainActor @Test func anAnswerAfterItsTaskWasCancelledNeverShows() async throws {
    let line = SignInServicesLine()
    let fetcher = GatedFetcher()
    let loading = Task { await line.load(.fudge, using: fetcher) }
    try await fetcher.waitUntilAsked(1)
    loading.cancel()
    try await fetcher.answer(SignInServer.fudge.servicesURL!, ids: ["github"])
    await loading.value
    #expect(line.text == plain)
}

@MainActor @Test func aChangeStartsOverWithThePlainLine() async throws {
    let line = SignInServicesLine()
    await line.load(.fudge, using: FixedSignInServices(ids: ["github"]))
    #expect(line.text == "Extensions sign in to GitHub through this server.")
    let fetcher = GatedFetcher()
    let loading = Task { await line.load(.custom(URL(string: "https://other.example")!), using: fetcher) }
    try await fetcher.waitUntilAsked(1)
    #expect(line.text == plain)
    try await fetcher.answer(URL(string: "https://other.example/api/services")!, ids: [])
    await loading.value
    #expect(line.text == plain)
}

@MainActor @Test func noServerOnScreenShowsThePlainLineAndAsksNothing() async {
    let line = SignInServicesLine()
    let fetcher = RecordingFetcher()
    await line.load(.fudge, using: FixedSignInServices(ids: ["github"]))
    // "Your own server…" with an address being typed.
    let onScreen = SignInServices.serverOnScreen(saved: .fudge, ownChosen: true, typedAddress: "https://typed.example")
    await line.load(onScreen, using: fetcher)
    #expect(line.text == plain)
    await line.load(.off, using: fetcher)
    #expect(line.text == plain)
    #expect(fetcher.asked.current == [])
}

// MARK: - Snapshot runs

@MainActor @Test func aSnapshotRunNeverUsesTheNetworkEvenWithAServerChosen() async {
    let network = RecordingFetcher()
    let made = Locked(false)
    let pick = { (snapshot: Bool, value: String?) in
        SignInServices.fetcher(snapshot: snapshot, snapshotValue: value) {
            made.mutate { $0 = true }
            return network
        }
    }
    let line = SignInServicesLine()
    await line.load(.fudge, using: pick(true, "github|atlassian"))
    #expect(line.text == "Extensions sign in to GitHub and Atlassian (Jira, Confluence) through this server.")
    await line.load(.custom(URL(string: "https://own.example")!), using: pick(true, nil))
    #expect(line.text == plain)
    #expect(!made.current)
    #expect(network.asked.current == [])
    // Outside a snapshot run, the network fetcher is the one.
    _ = pick(false, "github")
    #expect(made.current)
}

@MainActor @Test func theSnapshotFlagsIdsGoThroughTheSameReadingNamesAndLimits() async {
    let line = SignInServicesLine()
    await line.load(.fudge, using: FixedSignInServices(snapshotValue: " atlassian | nope|github|atlassian||"))
    #expect(line.names == [atlassian, "GitHub"])
    await line.load(.fudge, using: FixedSignInServices(snapshotValue: "github|linear|slack|asana|google|zoom"))
    #expect(line.text == "Extensions sign in to GitHub, Linear, Slack, Asana, and 2 more through this server.")
    await line.load(.fudge, using: FixedSignInServices(snapshotValue: ""))
    #expect(line.text == plain)
    await line.load(.fudge, using: FixedSignInServices(snapshotValue: "nope"))
    #expect(line.text == plain)
}

// MARK: - The request, against a local stub server

/// Asks the stub. The first run after a build can keep a machine busy for several seconds, so the tests that expect an
/// answer, or a refusal for a reason other than time, allow 30 s: their result then never stands for a timeout. The
/// 5 s limit itself is tested with its real value.
private func names(from base: URL, path: String = "", timeout: TimeInterval = 30) async -> [String] {
    let server = SignInServer.custom(URL(string: base.absoluteString + path)!)
    let fetcher = URLSessionSignInServices(userAgent: "Fudge/1.2.3", timeout: timeout)
    return await SignInServices.names(offeredBy: server, using: fetcher)
}

@Test func aServerThatListsItsServicesIsAskedWithOneGetUnderItsPath() async throws {
    let (stub, base) = try await LocalHTTPStub.start(
        LocalHTTPStub.answer(
            200, #"{"services":[{"id":"github","title":"GitHub"},{"id":"atlassian","title":"Atlassian"}]}"#,
            headers: ["Content-Type: application/json"]))
    defer { stub.stop() }
    #expect(await names(from: base, path: "/relay/") == ["GitHub", atlassian])
    let requests = stub.requests
    #expect(requests.count == 1)
    let lines = requests.first?.components(separatedBy: "\r\n") ?? []
    #expect(lines.first == "GET /relay/api/services HTTP/1.1")
    let headers = Set(lines.dropFirst().map { $0.lowercased() })
    #expect(headers.contains("user-agent: fudge/1.2.3"))
    #expect(headers.contains("accept: application/json"))
    #expect(headers.contains("accept-language: en"))
    #expect(!headers.contains { $0.hasPrefix("cookie:") || $0.hasPrefix("authorization:") })
}

@Test func anOlderOrSwitchedOffServersNotFoundIsThePlainLine() async throws {
    let (stub, base) = try await LocalHTTPStub.start(LocalHTTPStub.answer(404, "Not found"))
    defer { stub.stop() }
    #expect(await names(from: base) == [])
}

@Test func anyStatusButOKIsThePlainLineEvenWithAList() async throws {
    for status in [201, 204, 500] {
        let (stub, base) = try await LocalHTTPStub.start(
            LocalHTTPStub.answer(status, #"{"services":[{"id":"github"}]}"#))
        defer { stub.stop() }
        #expect(await names(from: base) == [], "\(status)")
    }
}

@Test func aRedirectIsntFollowed() async throws {
    let (stub, base) = try await LocalHTTPStub.start(
        LocalHTTPStub.answer(302, "", headers: ["Location: /api/services-elsewhere"]))
    defer { stub.stop() }
    #expect(await names(from: base) == [])
    #expect(stub.requests.count == 1)
}

@Test func moreThan64KBIsThePlainLine() async throws {
    let list = #"{"services":[{"id":"github"}]}"#
    let body = Data((list + String(repeating: " ", count: 70 * 1024)).utf8)
    // Said up front in Content-Length, and not said, so it's found while reading.
    for headers in [["Content-Length: \(body.count)"], []] {
        let (stub, base) = try await LocalHTTPStub.start(.answer(status: 200, headers: headers, body: body))
        defer { stub.stop() }
        #expect(await names(from: base) == [], "\(headers)")
    }
}

@Test func readingStopsAndTheConnectionClosesPast64KB() async throws {
    // 70 KB at once, then a byte every 5 s; the stub would end the connection itself at 15 s, and the request allows
    // 30 s. Only a client that stops reading past 64 KB hangs up before that.
    let (stub, base) = try await LocalHTTPStub.start(
        .drip(
            headers: [], first: Data(String(repeating: " ", count: 70 * 1024).utf8), chunk: Data(" ".utf8),
            interval: 5, count: 3))
    defer { stub.stop() }
    #expect(await names(from: base) == [])
    let deadline = ContinuousClock.now + .seconds(16)
    while stub.clientCloses.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    let closed = try #require(stub.clientCloses.first)
    #expect(closed < 15)
}

@Test func anAnswerSlowerThanFiveSecondsInAllIsThePlainLine() async throws {
    // The list at once, then a byte every half second for 8 s: each read is well under any per-read timeout, and the
    // whole answer would read as GitHub. Only the whole request's 5 s limit ends it.
    let list = Data(#"{"services":[{"id":"github"}]}"#.utf8)
    let (stub, base) = try await LocalHTTPStub.start(
        .drip(
            headers: ["Content-Length: \(list.count + 16)"], first: list, chunk: Data(" ".utf8), interval: 0.5,
            count: 16))
    defer { stub.stop() }
    let start = ContinuousClock.now
    // Read in full, the answer would name GitHub, at 8 s.
    #expect(await names(from: base, timeout: SignInServices.timeout) == [])
    #expect(ContinuousClock.now - start >= .seconds(4.5))
}

@Test func onlyAnOKAnswerOfAtMost64KBIsRead() throws {
    let url = URL(string: "https://sign-in.example.com/api/services")!
    func response(_ status: Int, length: Int? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: length.map { ["Content-Length": "\($0)"] } ?? [:])!
    }
    var body = SignInServicesBody()
    try body.check(response(200))
    try body.check(response(200, length: 65_536))
    for status in [201, 204, 301, 302, 304, 404, 500] {
        #expect(throws: SignInServicesBody.Refusal.status(status)) { try body.check(response(status)) }
    }
    #expect(throws: SignInServicesBody.Refusal.tooLarge) { try body.check(response(200, length: 65_537)) }
    try body.append(Data(repeating: 32, count: 65_535))
    try body.append(Data([32]))
    #expect(body.data.count == 65_536)
    #expect(throws: SignInServicesBody.Refusal.tooLarge) { try body.append(Data([32])) }
    #expect(body.data.count == 65_536)
    var big = SignInServicesBody()
    #expect(throws: SignInServicesBody.Refusal.tooLarge) { try big.append(Data(repeating: 32, count: 65_537)) }
    #expect(big.data.isEmpty)
}

@Test func theSessionKeepsNothingAndGivesUpAfterFiveSeconds() {
    let configuration = URLSessionSignInServices.configuration()
    #expect(configuration.timeoutIntervalForResource == 5)
    #expect(configuration.timeoutIntervalForRequest == 5)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.waitsForConnectivity == false)
    #expect(SignInServices.byteLimit == 65_536)
}
