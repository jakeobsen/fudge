import Foundation

// OAuth sign-in through a fudge-oauth relay (SPEC-056, decision D-63). The relay holds the OAuth apps' secrets and
// lives in its own repository, jakeobsen/fudge-oauth. Fudge holds none: it sends `@raycast/utils`' built-in providers
// to the relay instead of Raycast's servers, and keeps the tokens in the Keychain.

/// One of the providers `@raycast/utils`' `OAuthService` has built in, with its default URLs (2.3.3).
public struct OAuthProvider: Sendable, Equatable, Codable {
    /// The relay's path segment: `<server>/<id>/authorize`.
    public let id: String
    public let name: String
    public let authorizeURL: String
    public let tokenURL: String
    /// Where `OAuthService` sends a refresh. For Google, Jira and Zoom that's the token URL, so a request there is a
    /// refresh when its `grant_type` is `refresh_token`.
    public let refreshURL: String

    public init(id: String, name: String, authorizeURL: String, tokenURL: String, refreshURL: String) {
        self.id = id
        self.name = name
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.refreshURL = refreshURL
    }
}

/// The one table of providers Fudge signs in to. Only these exact URLs are ever sent to the relay.
public enum OAuthProviders {
    public static let all: [OAuthProvider] = [
        raycastProxy("github", "GitHub"),
        raycastProxy("linear", "Linear"),
        raycastProxy("slack", "Slack"),
        raycastProxy("asana", "Asana"),
        OAuthProvider(
            id: "google", name: "Google", authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token", refreshURL: "https://oauth2.googleapis.com/token"),
        OAuthProvider(
            id: "jira", name: "Jira", authorizeURL: "https://auth.atlassian.com/authorize",
            tokenURL: "https://auth.atlassian.com/oauth/token", refreshURL: "https://auth.atlassian.com/oauth/token"),
        OAuthProvider(
            id: "zoom", name: "Zoom", authorizeURL: "https://zoom.us/oauth/authorize",
            tokenURL: "https://zoom.us/oauth/token", refreshURL: "https://zoom.us/oauth/token"),
    ]

    /// Raycast's proxy for a provider, as `OAuthService` uses it by default.
    private static func raycastProxy(_ id: String, _ name: String) -> OAuthProvider {
        let base = "https://\(id).oauth.raycast.com"
        return OAuthProvider(
            id: id, name: name, authorizeURL: "\(base)/authorize", tokenURL: "\(base)/token",
            refreshURL: "\(base)/refresh-token")
    }

    /// The provider whose default authorize URL this is, exactly; nil for anything else.
    public static func provider(authorizing endpoint: String) -> OAuthProvider? {
        all.first { $0.authorizeURL == endpoint }
    }

    /// Raycast's proxy hosts. With sign-in off, the worker refuses requests to them rather than send one.
    public static var raycastHosts: [String] {
        all.compactMap { URL(string: $0.tokenURL)?.host }.filter { $0.hasSuffix(".oauth.raycast.com") }
    }

    /// The environment variable that hands this table to the extension host, whose workers rewrite `fetch` with it.
    public static let environmentKey = "FUDGE_OAUTH_PROVIDERS"

    /// The table as JSON, for `environmentKey`.
    public static var environmentValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(all)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The relay extensions sign in through (`signInServer` in `settings.json`): off, Fudge's own, or the user's.
public enum SignInServer: Sendable, Equatable {
    case off
    case fudge
    case custom(URL)

    /// Fudge's sign-in server.
    public static let fudgeURL = URL(string: "https://fudge-oauth.rackofpain.net")!

    /// The relay's address; nil when off.
    public var url: URL? {
        switch self {
        case .off: nil
        case .fudge: Self.fudgeURL
        case .custom(let url): url
        }
    }

    /// The relay's host, as the consent sheet names it.
    public var host: String? { url?.host }

    /// `<server>/<provider>/<endpoint>`, for `authorize`, `token` or `refresh-token`.
    public func endpoint(_ provider: OAuthProvider, _ name: String) -> String? {
        guard let url else { return nil }
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(provider.id)/\(name)"
    }

    /// The value saved in `settings.json`: `"fudge"` or the URL.
    public var settingsValue: String? {
        switch self {
        case .off: nil
        case .fudge: "fudge"
        case .custom(let url): url.absoluteString
        }
    }

    /// Reads a saved value. Anything that isn't `"fudge"` or a valid server URL is off.
    public init(settingsValue: String?) {
        guard let value = settingsValue else {
            self = .off
            return
        }
        if value == "fudge" {
            self = .fudge
        } else if case .success(let url) = Self.validate(value) {
            self = .custom(url)
        } else {
            self = .off
        }
    }

    /// Why a typed server address can't be used.
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case notAURL
        /// Only `https://`, or `http://` on `localhost` or `127.0.0.1`.
        case insecure
        /// User info, a query or a fragment.
        case extraParts

        public var message: String {
            switch self {
            case .empty: "Enter the server's address."
            case .notAURL: "Enter a URL, like https://sign-in.example.com."
            case .insecure: "Use https://, or http:// on localhost or 127.0.0.1."
            case .extraParts: "Leave out the user name, password, query and fragment."
            }
        }
    }

    /// Checks a typed address for "Your own server…": an `https://` URL with a host, or `http://` on `localhost` or
    /// `127.0.0.1` for testing, with no user info, query or fragment. Surrounding whitespace is ignored.
    ///
    /// The address is returned as the worker's `new URL()` writes it, since a sign-in's authorize URL is compared with
    /// what the worker sends back (`PreparedSignIn.state(ofAuthorizeURL:)`): the scheme and host in lowercase, no
    /// default port, and the path's dot segments resolved. A host that parser would rewrite in other ways (non-ASCII,
    /// percent-encoded, IPv6, or an IPv4 address written other than as four decimal numbers) isn't accepted.
    public static func validate(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            let host = components.percentEncodedHost.flatMap(canonicalHost)
        else { return .failure(.notAURL) }
        switch scheme {
        case "https": break
        case "http" where ["localhost", "127.0.0.1"].contains(host): break
        case "http": return .failure(.insecure)
        default: return .failure(.notAURL)
        }
        if components.user != nil || components.password != nil || components.query != nil
            || components.fragment != nil
        {
            return .failure(.extraParts)
        }
        var authority = host
        if let port = components.port {
            guard (0...65535).contains(port) else { return .failure(.notAURL) }
            if port != (scheme == "https" ? 443 : 80) { authority += ":\(port)" }
        }
        let path = resolvingDotSegments(components.percentEncodedPath)
        guard let url = URL(string: "\(scheme)://\(authority)\(path)") else { return .failure(.notAURL) }
        return .success(url)
    }

    private static let hostScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")

    /// A host in lowercase, when the URL parser would only change its letter case: an ASCII name, or an IPv4 address
    /// as four decimal numbers. Nil for anything else.
    static func canonicalHost(_ host: String) -> String? {
        let lowered = host.lowercased()
        guard !lowered.isEmpty, lowered.unicodeScalars.allSatisfy(hostScalars.contains) else { return nil }
        // A name whose last label is a number (decimal, or hex after "0x") is read as an IPv4 address, in any of
        // several notations, so only the one it's written back in is kept.
        var labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        guard let last = labels.last else { return nil }
        let isNumber =
            (!last.isEmpty && last.allSatisfy { $0.isASCII && $0.isNumber })
            || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        guard isNumber else { return lowered }
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        let canonical =
            octets.count == 4
            && octets.allSatisfy { octet in
                guard let value = Int(octet), (0...255).contains(value) else { return false }
                return String(value) == octet
            }
        return canonical ? lowered : nil
    }

    /// A path with its `.` and `..` segments resolved as the URL parser does, `%2e` counting as a dot.
    static func resolvingDotSegments(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var resolved: [Substring] = []
        for (index, segment) in zip(segments.indices, segments) {
            let isLast = index == segments.indices.last
            switch segment.lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !resolved.isEmpty { resolved.removeLast() }
                if isLast { resolved.append("") }
            case ".", "%2e":
                if isLast { resolved.append("") }
            default:
                resolved.append(segment)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// The sheet before a server is saved.
    public enum Consent {
        public static func title(host: String) -> String { "Extensions will sign in through \(host)." }
        public static let confirm = "Continue"
        public static let cancel = "Cancel"
    }

    /// The sheet before a change that signs out of everything.
    public enum Change {
        public static let title = "Sign out of everything?"
        public static let message = "Changing the sign-in server signs every extension out."
        public static let confirm = "Change Server"
        public static let cancel = "Cancel"
    }
}

extension FudgeSettings {
    /// The sign-in server in use: off unless it was chosen through the consent sheet, which records the date, so a
    /// hand-set value counts as off.
    public var signIn: SignInServer {
        guard signInServerConsentAt.flatMap(ISO8601DateFormatter().date(from:)) != nil else { return .off }
        return SignInServer(settingsValue: signInServer)
    }

    /// Chooses a server, as the consent sheet's Continue does; off removes both keys.
    public mutating func setSignIn(_ server: SignInServer, now: Date) {
        signInServer = server.settingsValue
        signInServerConsentAt = server == .off ? nil : ISO8601DateFormatter().string(from: now)
    }
}

/// What the loopback listener makes of one request (SPEC-056 §2).
public enum OAuthCallback: Equatable, Sendable {
    /// Not the callback: another path or method. Answered with a 404, and the sign-in keeps waiting.
    case notFound
    /// The provider's code, with the sign-in's own `state`.
    case code(String)
    /// The provider (or the relay) refused, with its `error` and `error_description`.
    case error(String, description: String?)
    /// The callback's `state` isn't this sign-in's, or it has neither a code nor an error. Answered with a 400, and
    /// the sign-in keeps waiting: a stray request mustn't cancel it.
    case invalid

    /// Whether the callback ends the sign-in's wait: only a code or an error with this sign-in's `state`.
    public var endsWait: Bool {
        switch self {
        case .code, .error: true
        case .notFound, .invalid: false
        }
    }

    /// Reads an HTTP request's first line (`GET /oauth/callback/<random>?code=…&state=… HTTP/1.1`). Only a `GET` on
    /// exactly `path` is the callback; its `state` must equal `state`.
    public static func read(requestLine: String, path: String, state: String) -> OAuthCallback {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
            let components = URLComponents(string: String(parts[1])), components.scheme == nil,
            components.host == nil, components.percentEncodedPath == path
        else { return .notFound }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard let given = values["state"], constantTimeEqual(given, state) else { return .invalid }
        if let error = values["error"], !error.isEmpty {
            return .error(error, description: values["error_description"].flatMap { $0.isEmpty ? nil : $0 })
        }
        if let code = values["code"], !code.isEmpty { return .code(code) }
        return .invalid
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A random URL-safe string with `bytes` of randomness, for the callback's path.
    public static func randomToken(bytes: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The page the browser shows once the callback is read.
    public static func page(signedIn: Bool) -> String {
        let text = signedIn ? "Signed in. You can close this tab." : "Sign-in didn't finish. You can close this tab."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Fudge</title>\
            <style>body{font:16px -apple-system,sans-serif;margin:4em;text-align:center}</style></head>\
            <body><p>\(text)</p></body></html>
            """
    }
}

/// A stored sign-in: Raycast's `TokenSet`, plus the provider's name for the Settings page.
public struct StoredTokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresIn: Double?
    public var scope: String?
    /// ISO 8601.
    public var updatedAt: String
    public var providerName: String?
    /// The `OAuthProviders` id this sign-in went through the relay for. The worker sends a provider's own token URL
    /// (Google's, Jira's, Zoom's) to the relay only for an extension with such a sign-in.
    public var relayProvider: String?

    public init(
        accessToken: String, refreshToken: String? = nil, idToken: String? = nil, expiresIn: Double? = nil,
        scope: String? = nil, updatedAt: String, providerName: String? = nil, relayProvider: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.updatedAt = updatedAt
        self.providerName = providerName
        self.relayProvider = relayProvider
    }
}

/// Where tokens are kept: the Keychain in the app, a dictionary in tests and snapshot runs. Each item is one
/// account's data under Fudge's sign-in service.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}

/// One row of Settings → Sign-in.
public struct SignInEntry: Equatable, Sendable, Identifiable {
    public var extensionName: String
    public var providerID: String
    public var providerName: String
    public var updatedAt: Date?
    public var id: String { OAuthTokenStore.account(extension: extensionName, provider: providerID) }
}

/// The sign-ins Fudge keeps: one item per extension and `providerId`, account `<extension>/<providerId>`, holding a
/// JSON `StoredTokenSet`.
public struct OAuthTokenStore: Sendable {
    /// The Keychain service of every item.
    public static let service = "io.github.jakeobsen.fudge.oauth"

    public let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The extension or provider id can't name an item.
        case invalidName
        /// `setTokens` without an access token.
        case invalidTokens
        case unknownCall

        public var description: String {
            switch self {
            case .invalidName: "A sign-in's provider id needs 1 to 64 characters, without a slash."
            case .invalidTokens: "setTokens needs an access token."
            case .unknownCall: "Fudge doesn't know this sign-in call."
            }
        }
    }

    public static func account(extension extensionName: String, provider: String) -> String {
        "\(extensionName)/\(provider)"
    }

    /// A provider id from an extension: 1–64 characters, none of them `/` or a control character.
    static func isValid(provider: String) -> Bool {
        (1...64).contains(provider.count) && !provider.contains("/")
            && !provider.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func checkedAccount(_ extensionName: String, _ provider: String) throws -> String {
        guard !extensionName.isEmpty, !extensionName.contains("/"), Self.isValid(provider: provider) else {
            throw Failure.invalidName
        }
        return Self.account(extension: extensionName, provider: provider)
    }

    public func tokens(extension extensionName: String, provider: String) throws -> StoredTokenSet? {
        guard let data = try secrets.read(account: checkedAccount(extensionName, provider)) else { return nil }
        return try? JSONDecoder().decode(StoredTokenSet.self, from: data)
    }

    public func save(_ tokens: StoredTokenSet, extension extensionName: String, provider: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try secrets.write(encoder.encode(tokens), account: checkedAccount(extensionName, provider))
    }

    public func remove(extension extensionName: String, provider: String) throws {
        try secrets.delete(account: checkedAccount(extensionName, provider))
    }

    /// Every stored sign-in, by extension then provider. An item that doesn't read is listed by its account, so it
    /// can still be signed out of.
    public func entries() throws -> [SignInEntry] {
        try secrets.accounts().compactMap { account -> SignInEntry? in
            guard let slash = account.firstIndex(of: "/") else { return nil }
            let extensionName = String(account[..<slash])
            let provider = String(account[account.index(after: slash)...])
            let stored = (try? secrets.read(account: account)).flatMap {
                try? JSONDecoder().decode(StoredTokenSet.self, from: $0)
            }
            return SignInEntry(
                extensionName: extensionName, providerID: provider,
                providerName: stored?.providerName ?? provider,
                updatedAt: stored.flatMap { ISO8601DateFormatter().date(from: $0.updatedAt) })
        }
        .sorted { ($0.extensionName, $0.providerID) < ($1.extensionName, $1.providerID) }
    }

    /// Signs out of everything, as changing the server does.
    public func removeAll() throws {
        for account in try secrets.accounts() { try secrets.delete(account: account) }
    }
}

/// A `SecretStore` in memory, for tests and snapshot runs.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    public init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    public func read(account: String) throws -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { items[account] = nil } }
    public func accounts() throws -> [String] { lock.withLock { items.keys.sorted() } }
}

/// Why a sign-in didn't happen, as the extension's call is rejected.
public enum SignInRefusal: Error, Equatable, Sendable {
    case off
    case unknownProvider(String)
    /// The call came from a command the user isn't using (SPEC-045).
    case background
    /// Another sign-in is on screen.
    case busy
    /// `authorize` without `authorizationRequest` first, or with a URL that isn't the request's.
    case notPrepared
    case cancelled
    case timedOut
    /// The provider or the relay refused: `error`, `error_description`.
    case refused(provider: String, error: String, description: String?)
    /// The callback's state didn't match, or it had no code.
    case browser

    public var message: String {
        switch self {
        case .off:
            "Sign-in is off. Turn it on in Fudge's Settings → Sign-in, or use a token in this extension's settings (⌘⇧,)."
        case .unknownProvider(let name): "Fudge can't sign in to \(name.isEmpty ? "this service" : name) yet."
        case .background: "Sign in from Fudge to continue."
        case .busy: "Another sign-in is in progress. Finish or cancel it first."
        case .notPrepared: "This sign-in request didn't come from Fudge. Try again."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out after 5 minutes. Try again."
        case .refused(let provider, let error, let description):
            "\(provider) didn't sign you in: \(description ?? error)"
        case .browser: "Fudge couldn't open the browser."
        }
    }
}

/// A sign-in request the app has made ready (`oauth.prepare`): the provider, the relay's authorize URL and the
/// loopback redirect.
public struct PreparedSignIn: Equatable, Sendable {
    public var provider: OAuthProvider
    public var authorizeURL: String
    public var redirectURI: String

    public init(provider: OAuthProvider, authorizeURL: String, redirectURI: String) {
        self.provider = provider
        self.authorizeURL = authorizeURL
        self.redirectURI = redirectURI
    }

    /// Maps `endpoint` (the extension's authorize URL) to a provider and the relay's authorize URL; refuses while
    /// sign-in is off and for any endpoint not in `OAuthProviders`. The redirect is filled in once the listener is up.
    public static func provider(
        for endpoint: String, providerName: String, server: SignInServer
    ) -> Result<(OAuthProvider, String), SignInRefusal> {
        guard server != .off else { return .failure(.off) }
        guard let provider = OAuthProviders.provider(authorizing: endpoint),
            let authorize = server.endpoint(provider, "authorize")
        else { return .failure(.unknownProvider(providerName)) }
        return .success((provider, authorize))
    }

    /// The `state` of a URL the extension asks to open: it must be the relay's authorize URL this request names,
    /// with this request's redirect and a `state`.
    public func state(ofAuthorizeURL url: String) -> String? {
        guard let components = URLComponents(string: url), let expected = URLComponents(string: authorizeURL),
            components.scheme == expected.scheme, components.host == expected.host,
            components.port == expected.port, components.path == expected.path
        else { return nil }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "redirect_uri" })?.value == redirectURI,
            let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty
        else { return nil }
        return state
    }
}

/// Which loopback listener each sign-in uses: every session's latest prepared request, and the one the "Sign in to …"
/// prompt shows. The prompt takes its request when it's shown, so a request the session prepares meanwhile never
/// takes its place: Esc, the command going away and the end of the sign-in all reach the listener being waited on.
///
/// It also says which relay sign-ins are pending (`pending(of:)`, for `SignInCalls`): prepared, shown, or signed in
/// with the token exchange still to come. One that ends without a code (Esc, an error, the timeout, a request that's
/// replaced or expires) is pending no more.
public struct SignInRequests<Listener: AnyObject> {
    public typealias Request = (request: PreparedSignIn, listener: Listener)

    private var prepared: [String: Request] = [:]
    /// The request the prompt shows, with its session.
    public private(set) var shown: (session: String, request: Request)?
    /// The providers each session signed in to, whose tokens the extension exchanges and stores next.
    private var signedIn: [String: Set<String>] = [:]

    public init() {}

    /// Keeps `request` as `session`'s latest. Returns the listener of an earlier one nothing used, to close.
    public mutating func prepare(_ request: Request, for session: String) -> Listener? {
        defer { prepared[session] = request }
        return prepared[session]?.listener
    }

    /// `session`'s latest prepared request, not yet shown.
    public func preparedRequest(of session: String) -> Request? { prepared[session] }

    /// The prompt takes `session`'s prepared request; nil when there's none, or a prompt is already up.
    public mutating func show(_ session: String) -> Request? {
        guard shown == nil, let request = prepared.removeValue(forKey: session) else { return nil }
        shown = (session, request)
        return request
    }

    /// The listener the prompt waits on, which Esc cancels.
    public var waitedOn: Listener? { shown?.request.listener }

    /// The sign-in using `listener` is over, with a code (`signedIn`) or without one. True when it was the prompt's,
    /// which is then gone.
    public mutating func finish(_ listener: Listener, signedIn code: Bool) -> Bool {
        guard let shown, shown.request.listener === listener else { return false }
        if code { signedIn[shown.session, default: []].insert(shown.request.request.provider.id) }
        self.shown = nil
        return true
    }

    /// The providers `session` has a relay sign-in pending for: its prepared request's, the prompt's when it's
    /// `session`'s, and those it signed in to.
    public func pending(of session: String) -> Set<String> {
        var providers = signedIn[session] ?? []
        if let request = prepared[session] { providers.insert(request.request.provider.id) }
        if let shown, shown.session == session { providers.insert(shown.request.request.provider.id) }
        return providers
    }

    /// A request unused after its time: true, and dropped, when `listener` is still `session`'s prepared one.
    public mutating func expire(_ listener: Listener, of session: String) -> Bool {
        guard prepared[session]?.listener === listener else { return false }
        prepared[session] = nil
        return true
    }

    /// `session` is going away: its unused request is dropped, to close, and the prompt's listener, when the prompt
    /// is its, is returned to cancel. The prompt stays until its sign-in finishes.
    public mutating func end(_ session: String) -> (unused: Listener?, waitedOn: Listener?) {
        signedIn[session] = nil
        let unused = prepared.removeValue(forKey: session)?.listener
        return (unused, shown?.session == session ? shown?.request.listener : nil)
    }
}

/// A `data:` URL's bytes, for images such as `@raycast/utils`' provider icons (`data:image/svg+xml,…`).
public enum DataURL {
    /// The media type and the bytes; nil for anything but a `data:` URL whose media type is an image, or bytes past
    /// `limit`.
    public static func image(_ text: String, limit: Int = 1024 * 1024) -> (type: String, data: Data)? {
        guard text.lowercased().hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        var parameters = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let type = parameters.isEmpty ? "" : parameters.removeFirst()
        guard type.hasPrefix("image/") else { return nil }
        let payload = String(text[text.index(after: comma)...])
        let data: Data?
        if parameters.contains("base64") {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, data.count <= limit else { return nil }
        return (type, data)
    }
}

extension OAuthTokenStore {
    /// A stored sign-in as the worker gets it.
    public static func json(_ tokens: StoredTokenSet) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tokens))) ?? .null
    }

    /// The tokens a worker sends to `setTokens`; nil without an access token or an `updatedAt`.
    public static func tokenSet(_ json: JSONValue) -> StoredTokenSet? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(StoredTokenSet.self, from: data)
    }
}

/// The worker's `oauth.tokens.*` and `oauth.server` calls, for one extension: the calling session's, never one named in
/// the parameters. `pending` holds the providers this session has prepared a relay sign-in for.
public struct SignInCalls: Sendable {
    public let store: OAuthTokenStore
    public let extensionName: String
    public let pending: Set<String>

    public init(store: OAuthTokenStore, extensionName: String, pending: Set<String>) {
        self.store = store
        self.extensionName = extensionName
        self.pending = pending
    }

    public func answer(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let values: [String: JSONValue] = if case .object(let object) = params { object } else { [:] }
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        let provider = string("providerId") ?? ""
        switch method {
        case "oauth.tokens.get":
            return try store.tokens(extension: extensionName, provider: provider).map(OAuthTokenStore.json) ?? .null
        case "oauth.tokens.set":
            guard var tokens = values["tokens"].flatMap(OAuthTokenStore.tokenSet) else {
                throw OAuthTokenStore.Failure.invalidTokens
            }
            // Only a relay sign-in this session prepared marks the tokens; a refresh keeps the mark they had.
            let existing = try store.tokens(extension: extensionName, provider: provider)
            tokens.relayProvider =
                tokens.relayProvider.flatMap { pending.contains($0) ? $0 : nil }
                ?? existing?.relayProvider
            try store.save(tokens, extension: extensionName, provider: provider)
            return .null
        case "oauth.tokens.remove":
            try store.remove(extension: extensionName, provider: provider)
            return .null
        default:
            throw OAuthTokenStore.Failure.unknownCall
        }
    }

    /// Whether this extension has a relay sign-in for `provider` (an `OAuthProviders` id): one this session prepared,
    /// or one it stored.
    public func hasRelaySignIn(provider: String) throws -> Bool {
        if pending.contains(provider) { return true }
        let prefix = OAuthTokenStore.account(extension: extensionName, provider: "")
        return try store.secrets.accounts().contains { account in
            guard account.hasPrefix(prefix), let data = try? store.secrets.read(account: account),
                let tokens = try? JSONDecoder().decode(StoredTokenSet.self, from: data)
            else { return false }
            return tokens.relayProvider == provider
        }
    }
}
