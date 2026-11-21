import Foundation
import Testing

@testable import FudgeCore

// SPEC-056: sign-in through a fudge-oauth relay. The provider table, the settings rules, the callback parser and the
// token store, with a fake Keychain.

// MARK: - The provider table

@Test func everyBuiltInProvidersDefaultURLsMapAndNothingElseDoes() {
    #expect(OAuthProviders.all.map(\.id) == ["github", "linear", "slack", "asana", "google", "jira", "zoom"])
    for provider in OAuthProviders.all {
        #expect(OAuthProviders.provider(authorizing: provider.authorizeURL) == provider, "\(provider.id)")
    }
    // @raycast/utils 2.3.3's defaults.
    #expect(OAuthProviders.provider(authorizing: "https://github.oauth.raycast.com/authorize")?.id == "github")
    #expect(OAuthProviders.provider(authorizing: "https://accounts.google.com/o/oauth2/v2/auth")?.id == "google")
    #expect(OAuthProviders.provider(authorizing: "https://auth.atlassian.com/authorize")?.id == "jira")
    #expect(OAuthProviders.provider(authorizing: "https://zoom.us/oauth/authorize")?.id == "zoom")
    for other in [
        "https://github.com/login/oauth/authorize", "https://github.oauth.raycast.com/authorize/",
        "https://github.oauth.raycast.com/token", "http://github.oauth.raycast.com/authorize",
        "https://GITHUB.oauth.raycast.com/authorize?x=1", "https://example.com/authorize", "",
    ] {
        #expect(OAuthProviders.provider(authorizing: other) == nil, "\(other)")
    }
    #expect(
        OAuthProviders.raycastHosts.sorted() == [
            "asana.oauth.raycast.com", "github.oauth.raycast.com", "linear.oauth.raycast.com",
            "slack.oauth.raycast.com",
        ])
    let google = OAuthProviders.all.first { $0.id == "google" }!
    #expect(google.refreshURL == google.tokenURL, "Google refreshes at its token URL")
    let github = OAuthProviders.all.first { $0.id == "github" }!
    #expect(github.refreshURL == "https://github.oauth.raycast.com/refresh-token")
}

/// The runtime's tests load the same table from this file, so the two can't drift apart.
@Test func theTableTheHostGetsMatchesTheRuntimesFixture() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/oauth-providers.json")
    let pinned = try JSONDecoder().decode([OAuthProvider].self, from: Data(contentsOf: fixture))
    #expect(pinned == OAuthProviders.all)
    let sent = try JSONDecoder().decode([OAuthProvider].self, from: Data(OAuthProviders.environmentValue.utf8))
    #expect(sent == OAuthProviders.all)
    #expect(OAuthProviders.environmentKey == "FUDGE_OAUTH_PROVIDERS")
}

// MARK: - The setting

@Test func aServerCountsOnlyWithItsConsent() throws {
    var settings = FudgeSettings()
    #expect(settings.signIn == .off)
    settings.signInServer = "fudge"
    #expect(settings.signIn == .off, "a hand-set value without the consent time counts as off")
    settings.signInServerConsentAt = "not a date"
    #expect(settings.signIn == .off)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    settings.setSignIn(.fudge, now: now)
    #expect(settings.signIn == .fudge)
    #expect(settings.signInServer == "fudge")
    #expect(settings.signInServerConsentAt == ISO8601DateFormatter().string(from: now))
    #expect(settings.signIn.url == SignInServer.fudgeURL)
    #expect(SignInServer.fudgeURL.absoluteString == "https://fudge-oauth.rackofpain.net")

    let own = URL(string: "https://sign-in.example.com")!
    settings.setSignIn(.custom(own), now: now)
    #expect(settings.signIn == .custom(own))
    #expect(settings.signInServer == "https://sign-in.example.com")

    settings.setSignIn(.off, now: now)
    #expect(settings.signInServer == nil && settings.signInServerConsentAt == nil, "off removes both")

    // A saved value that isn't a valid server is off, consent or not.
    settings.signInServer = "http://example.com"
    settings.signInServerConsentAt = ISO8601DateFormatter().string(from: now)
    #expect(settings.signIn == .off)
}

@Test func theSignInKeysRoundTripThroughSettingsJSON() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.setSignIn(.custom(URL(string: "http://localhost:8080")!), now: Date())
    try settings.save(to: file)
    let loaded = FudgeSettings.load(from: file)
    #expect(loaded.signIn == .custom(URL(string: "http://localhost:8080")!))
    var off = loaded
    off.setSignIn(.off, now: Date())
    try off.save(to: file)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    #expect(object["signInServer"] == nil && object["signInServerConsentAt"] == nil)
}

@Test func ownServerAddressesAreCheckedBeforeTheyreSaved() {
    func problem(_ text: String) -> SignInServer.Problem? {
        if case .failure(let problem) = SignInServer.validate(text) { problem } else { nil }
    }
    #expect(
        SignInServer.validate("https://sign-in.example.com") == .success(URL(string: "https://sign-in.example.com")!))
    #expect(
        SignInServer.validate("  https://corp.example/oauth/ ") == .success(URL(string: "https://corp.example/oauth/")!)
    )
    #expect(SignInServer.validate("http://localhost:8080") == .success(URL(string: "http://localhost:8080")!))
    #expect(SignInServer.validate("http://127.0.0.1:9000") == .success(URL(string: "http://127.0.0.1:9000")!))
    #expect(problem("") == .empty)
    #expect(problem("   ") == .empty)
    #expect(problem("sign-in.example.com") == .notAURL)
    #expect(problem("ftp://example.com") == .notAURL)
    #expect(problem("https://") == .notAURL)
    #expect(problem("http://example.com") == .insecure)
    #expect(problem("http://localhost.example.com") == .insecure)
    #expect(problem("http://192.168.1.2") == .insecure)
    #expect(problem("https://user:pass@example.com") == .extraParts)
    #expect(problem("https://example.com/?a=1") == .extraParts)
    #expect(problem("https://example.com/#x") == .extraParts)
    #expect(SignInServer.Problem.insecure.message == "Use https://, or http:// on localhost or 127.0.0.1.")

    // Saved as the worker's `new URL()` writes it (each expected value is Node's `href`, without the "/" it adds to
    // an empty path), so a sign-in's authorize URL comes back unchanged.
    let normalised = [
        ("https://Relay.Example", "https://relay.example"),
        ("HTTPS://relay.example", "https://relay.example"),
        ("https://relay.example:443", "https://relay.example"),
        ("https://relay.example:0443/x", "https://relay.example/x"),
        ("http://LOCALHOST:8080", "http://localhost:8080"),
        ("http://localhost:80", "http://localhost"),
        ("https://relay.example:8443", "https://relay.example:8443"),
        ("https://relay.example/a/../b", "https://relay.example/b"),
        ("https://relay.example/a/./b/%2e%2E/c", "https://relay.example/a/c"),
        ("https://relay.example/a/..", "https://relay.example/"),
        ("https://relay.example/.", "https://relay.example/"),
        ("https://Relay.Example/Base/", "https://relay.example/Base/"),
        ("https://10.0.0.1", "https://10.0.0.1"),
        ("https://relay.example./x", "https://relay.example./x"),
    ]
    for (typed, saved) in normalised {
        #expect(SignInServer.validate(typed) == .success(URL(string: saved)!), "\(typed)")
    }
    // Hosts that parser rewrites in other ways aren't accepted: IPv4 in other notations, percent-encoded or
    // non-ASCII names, IPv6. A port past 65535 isn't a URL there.
    for typed in [
        "https://0x7f.0.0.1", "https://127.1", "https://010.0.0.1", "https://10.0.0.1.", "https://re%6Cay.example",
        "https://relä.example", "https://[::1]", "https://relay.example:99999",
    ] {
        #expect(problem(typed) == .notAURL, "\(typed)")
    }

    // End to end: the authorize URL the worker sends back, as Node writes it, is the prepared request's.
    let redirect = "http://127.0.0.1:5000/oauth/callback/abc"
    let query = "?redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Foauth%2Fcallback%2Fabc&state=s1"
    for (typed, fromNode) in [
        ("https://Relay.Example", "https://relay.example/github/authorize"),
        ("https://relay.example:443/a/../b/", "https://relay.example/b/github/authorize"),
        ("http://LOCALHOST:80", "http://localhost/github/authorize"),
    ] {
        guard case .success(let url) = SignInServer.validate(typed),
            case .success(let (provider, authorize)) = PreparedSignIn.provider(
                for: "https://github.oauth.raycast.com/authorize", providerName: "GitHub", server: .custom(url))
        else {
            Issue.record("\(typed) wasn't accepted")
            continue
        }
        let request = PreparedSignIn(provider: provider, authorizeURL: authorize, redirectURI: redirect)
        #expect(request.state(ofAuthorizeURL: fromNode + query) == "s1", "\(typed)")
    }
}

@Test func theRelaysEndpointsAreUnderTheServersAddress() {
    let github = OAuthProviders.all[0]
    #expect(SignInServer.fudge.endpoint(github, "authorize") == "https://fudge-oauth.rackofpain.net/github/authorize")
    let own = SignInServer.custom(URL(string: "https://corp.example/oauth/")!)
    #expect(own.endpoint(github, "token") == "https://corp.example/oauth/github/token")
    #expect(SignInServer.off.endpoint(github, "token") == nil)
    #expect(own.host == "corp.example")
    #expect(SignInServer.Consent.title(host: "corp.example") == "Extensions will sign in through corp.example.")
}

// MARK: - Preparing a sign-in

@Test func preparingRefusesWhileOffAndForProvidersFudgeDoesntKnow() {
    let github = "https://github.oauth.raycast.com/authorize"
    #expect(PreparedSignIn.provider(for: github, providerName: "GitHub", server: .off).failure == .off)
    #expect(
        SignInRefusal.off.message
            == "Sign-in is off. Turn it on in Fudge's Settings → Sign-in, or use a token in this extension's settings (⌘⇧,)."
    )
    let unknown = PreparedSignIn.provider(for: "https://example.com/oauth", providerName: "Example", server: .fudge)
    #expect(unknown.failure == .unknownProvider("Example"))
    #expect(SignInRefusal.unknownProvider("Example").message == "Fudge can't sign in to Example yet.")
    let prepared = PreparedSignIn.provider(for: github, providerName: "GitHub", server: .fudge)
    #expect(prepared.value?.0.id == "github")
    #expect(prepared.value?.1 == "https://fudge-oauth.rackofpain.net/github/authorize")
}

@Test func onlyTheRequestsOwnAuthorizeURLMayBeOpened() {
    let request = PreparedSignIn(
        provider: OAuthProviders.all[0], authorizeURL: "https://relay.example/github/authorize",
        redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
    let redirect = "redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Foauth%2Fcallback%2Fabc"
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(redirect)&state=s1") == "s1")
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(redirect)") == nil, "no state")
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?state=s1") == nil, "no redirect")
    #expect(request.state(ofAuthorizeURL: "https://evil.example/github/authorize?\(redirect)&state=s1") == nil)
    #expect(request.state(ofAuthorizeURL: "https://relay.example/slack/authorize?\(redirect)&state=s1") == nil)
    #expect(request.state(ofAuthorizeURL: "http://relay.example/github/authorize?\(redirect)&state=s1") == nil)
    let other = "redirect_uri=http%3A%2F%2F127.0.0.1%3A5001%2Foauth%2Fcallback%2Fabc"
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(other)&state=s1") == nil)
}

// MARK: - Which listener a sign-in uses

private final class Listener {}

@Test func thePromptKeepsTheListenerItWaitsOnWhateverTheSessionPreparesMeanwhile() {
    func request(_ listener: Listener) -> SignInRequests<Listener>.Request {
        let prepared = PreparedSignIn(
            provider: OAuthProviders.all[0], authorizeURL: "https://relay.example/github/authorize",
            redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
        return (prepared, listener)
    }
    var requests = SignInRequests<Listener>()
    let first = Listener()
    let second = Listener()
    let third = Listener()

    // An unused request is replaced, and its listener closed.
    let none = requests.prepare(request(first), for: "s1")
    let replaced = requests.prepare(request(second), for: "s1")
    #expect(none == nil && replaced === first)
    #expect(requests.preparedRequest(of: "s1")?.listener === second)

    // The prompt takes the request. Preparing again meanwhile closes nothing, and Esc still reaches the prompt's.
    let shown = requests.show("s1")
    let again = requests.show("s1")
    #expect(shown?.listener === second)
    #expect(again == nil, "one prompt at a time")
    #expect(requests.preparedRequest(of: "s1") == nil)
    let closed = requests.prepare(request(third), for: "s1")
    #expect(closed == nil, "the prompt's listener isn't closed")
    #expect(requests.waitedOn === second)
    let expired = requests.expire(second, of: "s1")
    #expect(!expired, "a shown request never expires")

    // Another session going away leaves the prompt alone; its own going away cancels the prompt's listener and
    // closes the unused one, and the prompt goes when its sign-in finishes.
    let other = requests.end("s2")
    #expect(other.unused == nil && other.waitedOn == nil)
    let ended = requests.end("s1")
    #expect(ended.unused === third && ended.waitedOn === second)
    #expect(requests.waitedOn === second, "the prompt stays until its sign-in finishes")
    let finishedOther = requests.finish(third, signedIn: false)
    let finished = requests.finish(second, signedIn: false)
    #expect(!finishedOther && finished)
    #expect(requests.shown == nil && requests.waitedOn == nil)

    // An unused request expires only while it's still the session's latest.
    _ = requests.prepare(request(first), for: "s1")
    _ = requests.prepare(request(second), for: "s1")
    let stale = requests.expire(first, of: "s1")
    let latest = requests.expire(second, of: "s1")
    let left = requests.show("s1")
    #expect(!stale && latest)
    #expect(left == nil, "nothing left to show")
}

@Test func aRelaySignInIsPendingOnlyUntilItEndsWithoutACode() {
    func request(_ provider: Int, _ listener: Listener) -> SignInRequests<Listener>.Request {
        let prepared = PreparedSignIn(
            provider: OAuthProviders.all[provider], authorizeURL: "https://relay.example/x/authorize",
            redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
        return (prepared, listener)
    }
    let github = OAuthProviders.all[0].id
    let linear = OAuthProviders.all[1].id
    var requests = SignInRequests<Listener>()
    let first = Listener()
    let second = Listener()
    let third = Listener()

    // Prepared, then shown: pending, for this session only.
    _ = requests.prepare(request(0, first), for: "s1")
    #expect(requests.pending(of: "s1") == [github])
    #expect(requests.pending(of: "s2").isEmpty)
    _ = requests.show("s1")
    #expect(requests.pending(of: "s1") == [github])

    // Esc, an error or the timeout: no code, so no longer pending.
    let cancelled = requests.finish(first, signedIn: false)
    #expect(cancelled)
    #expect(requests.pending(of: "s1").isEmpty)

    // A request replaced by another provider's, or one that expires, is pending no more either.
    _ = requests.prepare(request(0, first), for: "s1")
    _ = requests.prepare(request(1, second), for: "s1")
    #expect(requests.pending(of: "s1") == [linear])
    let expired = requests.expire(second, of: "s1")
    #expect(expired)
    #expect(requests.pending(of: "s1").isEmpty)

    // A code keeps it pending for the token exchange that follows, until the session ends.
    _ = requests.prepare(request(0, third), for: "s1")
    _ = requests.show("s1")
    let signedIn = requests.finish(third, signedIn: true)
    #expect(signedIn)
    #expect(requests.pending(of: "s1") == [github])
    _ = requests.prepare(request(1, first), for: "s1")
    #expect(requests.pending(of: "s1") == [github, linear])
    _ = requests.end("s1")
    #expect(requests.pending(of: "s1").isEmpty)

    // Only the prompt's own listener finishes it.
    _ = requests.prepare(request(1, second), for: "s2")
    _ = requests.show("s2")
    let other = requests.finish(first, signedIn: true)
    #expect(!other)
    #expect(requests.pending(of: "s2") == [linear])
}

// MARK: - The callback

@Test func theCallbackIsOneGETOnTheExactPathWithTheSignInsState() {
    let path = "/oauth/callback/r4nd0m"
    func read(_ line: String) -> OAuthCallback { OAuthCallback.read(requestLine: line, path: path, state: "st") }
    #expect(read("GET /oauth/callback/r4nd0m?code=c0de&state=st HTTP/1.1") == .code("c0de"))
    #expect(read("GET /oauth/callback/r4nd0m?state=st&code=a%2Bb HTTP/1.1") == .code("a+b"))
    #expect(
        read("GET /oauth/callback/r4nd0m?error=access_denied&error_description=No%20thanks&state=st HTTP/1.1")
            == .error("access_denied", description: "No thanks"))
    #expect(
        read("GET /oauth/callback/r4nd0m?error=access_denied&state=st HTTP/1.1")
            == .error("access_denied", description: nil))
    // Not the callback: answered with a 404, and the sign-in keeps waiting.
    #expect(read("POST /oauth/callback/r4nd0m?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /oauth/callback/other?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /oauth/callback/r4nd0m/x?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /favicon.ico HTTP/1.1") == .notFound)
    #expect(read("GET http://127.0.0.1/oauth/callback/r4nd0m?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("garbage") == .notFound)
    #expect(read("") == .notFound)
    // The callback, but not this sign-in's.
    #expect(read("GET /oauth/callback/r4nd0m?code=c&state=other HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?code=c HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?state=st HTTP/1.1") == .invalid, "neither a code nor an error")
    #expect(read("GET /oauth/callback/r4nd0m?code=&state=st HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?state=st&state=other&code=c HTTP/1.1") == .code("c"), "the first state")
}

@Test func callbackPathsAreRandomAndURLSafe() {
    let tokens = (0..<20).map { _ in OAuthCallback.randomToken() }
    #expect(Set(tokens).count == 20)
    for token in tokens {
        #expect(token.count == 22)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
    #expect(OAuthCallback.page(signedIn: true).contains("Signed in. You can close this tab."))
}

// MARK: - The token store

@Test func tokensAreKeptPerExtensionAndProvider() throws {
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    #expect(OAuthTokenStore.service == "io.github.jakeobsen.fudge.oauth")
    #expect(try store.tokens(extension: "github", provider: "github") == nil)
    let tokens = StoredTokenSet(
        accessToken: "a", refreshToken: "r", expiresIn: 3600, scope: "repo", updatedAt: "2026-11-21T02:00:00Z",
        providerName: "GitHub")
    try store.save(tokens, extension: "github", provider: "github")
    try store.save(
        StoredTokenSet(accessToken: "b", updatedAt: "2026-11-21T03:00:00Z"), extension: "linear", provider: "linear")
    #expect(try secrets.accounts() == ["github/github", "linear/linear"])
    #expect(try store.tokens(extension: "github", provider: "github") == tokens)
    #expect(try store.tokens(extension: "linear", provider: "github") == nil, "another extension's are its own")

    let entries = try store.entries()
    #expect(entries.map(\.id) == ["github/github", "linear/linear"])
    #expect(entries[0].providerName == "GitHub")
    #expect(entries[1].providerName == "linear", "without a name, the provider id")
    #expect(entries[0].updatedAt == ISO8601DateFormatter().date(from: "2026-11-21T02:00:00Z"))

    try store.remove(extension: "github", provider: "github")
    #expect(try store.tokens(extension: "github", provider: "github") == nil)
    try store.removeAll()
    #expect(try store.entries().isEmpty)

    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a/b", provider: "x") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a", provider: "x/y") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a", provider: "") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "", provider: "x") }
}

@Test func tokensTravelToAndFromTheWorkerAsJSON() {
    let tokens = StoredTokenSet(accessToken: "a", refreshToken: "r", expiresIn: 60, updatedAt: "2026-11-21T02:00:00Z")
    let json = OAuthTokenStore.json(tokens)
    guard case .object(let object) = json else { return #expect(Bool(false), "an object") }
    #expect(object["accessToken"] == .string("a"))
    #expect(object["expiresIn"] == .number(60))
    #expect(OAuthTokenStore.tokenSet(json) == tokens)
    #expect(OAuthTokenStore.tokenSet(.object(["refreshToken": .string("r")])) == nil, "no access token")
}

@Test func anImportKeepsThisMacsSignInServer() {
    #expect(Backup.consentKeys.contains("signInServer") && Backup.consentKeys.contains("signInServerConsentAt"))
    #expect(Backup.exportStrippedKeys.contains("signInServerConsentAt"))
}

// MARK: - The worker's calls

@Test func anExtensionReadsSetsAndRemovesOnlyItsOwnTokens() throws {
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    let theirs = StoredTokenSet(accessToken: "theirs", updatedAt: "2026-11-21T02:00:00Z")
    try store.save(theirs, extension: "other", provider: "github")
    let calls = SignInCalls(store: store, extensionName: "mine", pending: [])
    func call(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
        try calls.answer(method, .object(params))
    }
    // Naming another extension in the parameters changes nothing: the session's extension is used.
    #expect(try call("oauth.tokens.get", ["providerId": .string("github"), "extension": .string("other")]) == .null)
    #expect(throws: OAuthTokenStore.Failure.invalidName) {
        try call("oauth.tokens.get", ["providerId": .string("../other/github")])
    }
    let mine: JSONValue = .object(["accessToken": .string("mine"), "updatedAt": .string("2026-11-21T03:00:00Z")])
    _ = try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": mine, "extension": .string("other")])
    _ = try call("oauth.tokens.remove", ["providerId": .string("github"), "extension": .string("other")])
    #expect(try store.tokens(extension: "other", provider: "github") == theirs, "theirs untouched")
    #expect(try store.tokens(extension: "mine", provider: "github") == nil, "set, then removed: its own")
    _ = try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": mine])
    #expect(try store.tokens(extension: "mine", provider: "github")?.accessToken == "mine")
    #expect(throws: OAuthTokenStore.Failure.invalidTokens) {
        try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": .object([:])])
    }
}

@Test func onlyARelaySignInThisSessionPreparedMarksTokensAndARefreshKeepsTheMark() throws {
    let store = OAuthTokenStore(secrets: MemorySecretStore())
    func tokens(_ relay: String?) -> JSONValue {
        var object: [String: JSONValue] = ["accessToken": .string("a"), "updatedAt": .string("2026-11-21T03:00:00Z")]
        if let relay { object["relayProvider"] = .string(relay) }
        return .object(object)
    }
    let prepared = SignInCalls(store: store, extensionName: "google-ext", pending: ["google"])
    #expect(try prepared.hasRelaySignIn(provider: "google"), "pending")
    _ = try prepared.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens("google")]))
    #expect(try store.tokens(extension: "google-ext", provider: "google")?.relayProvider == "google")

    // A later worker refreshes without a sign-in: the stored mark stays, and it still counts.
    let later = SignInCalls(store: store, extensionName: "google-ext", pending: [])
    #expect(try later.hasRelaySignIn(provider: "google"), "stored")
    _ = try later.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens(nil)]))
    #expect(try store.tokens(extension: "google-ext", provider: "google")?.relayProvider == "google")
    #expect(try !later.hasRelaySignIn(provider: "zoom"))

    // An extension can't claim a relay sign-in it didn't prepare.
    let claims = SignInCalls(store: store, extensionName: "own-flow", pending: [])
    _ = try claims.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens("google")]))
    #expect(try store.tokens(extension: "own-flow", provider: "google")?.relayProvider == nil)
    #expect(try !claims.hasRelaySignIn(provider: "google"))
    // Nor see another extension's.
    #expect(try !SignInCalls(store: store, extensionName: "google", pending: []).hasRelaySignIn(provider: "google"))
}

@Test func onlyThisSignInsCallbackEndsTheWait() {
    #expect(OAuthCallback.code("c").endsWait)
    #expect(OAuthCallback.error("access_denied", description: nil).endsWait)
    #expect(!OAuthCallback.notFound.endsWait, "a wrong path: 404, keep waiting")
    #expect(!OAuthCallback.invalid.endsWait, "a wrong state: 400, keep waiting")
}

// MARK: - Data URLs

@Test func dataURLImagesDecode() {
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"
    let encoded = "data:image/svg+xml,\(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
    #expect(DataURL.image(encoded)?.type == "image/svg+xml")
    #expect(DataURL.image(encoded)?.data == Data(svg.utf8))
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    #expect(DataURL.image("data:image/png;base64,\(png.base64EncodedString())")?.data == png)
    #expect(DataURL.image("data:text/html,<b>x</b>") == nil, "only images")
    #expect(DataURL.image("https://example.com/a.png") == nil)
    #expect(DataURL.image("data:image/png;base64,AAAA", limit: 2) == nil, "past the limit")
}

extension Result {
    fileprivate var failure: Failure? { if case .failure(let failure) = self { failure } else { nil } }
    fileprivate var value: Success? { if case .success(let value) = self { value } else { nil } }
}
