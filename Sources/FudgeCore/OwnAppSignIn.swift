import Foundation

// Sign-in for extensions with their own OAuth app (SPEC-132, FUD-165). Such an extension signs in straight to its
// service, which sends the browser back to Raycast's return address for its `OAuth.RedirectMethod`, the same for every
// extension. Fudge answers that address: a `raycast://oauth` or `com.raycast:/oauth` link, or, for Web, the address
// the user pastes. Nothing here depends on a particular extension (D-83).

/// An extension's `OAuth.RedirectMethod`, for the direct path. `ClientIdMetadataDocument`, Raycast's own client
/// document, isn't one: it's refused.
public enum OAuthRedirectMethod: String, Sendable, CaseIterable {
    case web
    case app
    case appURI

    /// Raycast's return address for the method, the same for every extension (`Extension` is a literal).
    public var raycastRedirectURI: String {
        switch self {
        case .web: "https://raycast.com/redirect?packageName=Extension"
        case .app: "raycast://oauth?package_name=Extension"
        case .appURI: "com.raycast:/oauth?package_name=Extension"
        }
    }

    /// Whether the address the browser comes back to shows in its address bar, so the user can paste it: only Web's
    /// raycast.com page. App and AppURI hand their link to macOS, and the code never shows.
    public var canPaste: Bool { self == .web }
}

/// Raycast's return address coming back to Fudge (SPEC-132 §3.2, §4).
public enum RaycastReturn {
    /// The schemes Fudge registers for it (`CFBundleURLTypes`), which are Raycast's own.
    public static let schemes = ["raycast", "com.raycast"]

    /// One link of each shape, for asking which app opens them.
    public static let links = [URL(string: "raycast://oauth")!, URL(string: "com.raycast:/oauth")!]

    /// Whether a link is one of the two shapes Fudge answers: `raycast://oauth?…` (scheme `raycast`, host `oauth`,
    /// empty path) or `com.raycast:/oauth?…` (scheme `com.raycast`, no host, path `/oauth`), ignoring case in the
    /// scheme and host.
    static func isReturnLink(_ components: URLComponents) -> Bool {
        switch components.scheme?.lowercased() {
        case "raycast": components.host?.lowercased() == "oauth" && components.percentEncodedPath.isEmpty
        case "com.raycast": components.host == nil && components.percentEncodedPath == "/oauth"
        default: false
        }
    }

    /// What a link that opened Fudge says to the direct sign-in waiting with `state`: a code or an error ends the
    /// wait, as the loopback's callback does. Any other link (`raycast://extensions/…` included) is `notFound`; a
    /// return link with another state, or with neither a code nor an error, is `invalid`. Either way it's ignored.
    public static func read(link: String, state: String) -> OAuthCallback {
        guard let components = URLComponents(string: link), isReturnLink(components) else { return .notFound }
        return OAuthCallback.read(query: components.queryItems ?? [], state: state)
    }

    /// The most text a paste is read from: an address with a code is far shorter.
    public static let pasteLimit = 16 * 1024

    /// What a pasted address says to the Web sign-in waiting with `state` (§4): the text, trimmed, as an `https` URL
    /// with any host or a `raycast://oauth` link, its query read as a link's. Anything else is `notFound`.
    public static func read(pasted text: String, state: String) -> OAuthCallback {
        guard text.utf8.count <= pasteLimit else { return .notFound }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return .notFound }
        let isWeb = components.scheme?.lowercased() == "https" && !(components.host ?? "").isEmpty
        let isLink = components.scheme?.lowercased() == "raycast" && isReturnLink(components)
        guard isWeb || isLink else { return .notFound }
        return OAuthCallback.read(query: components.queryItems ?? [], state: state)
    }

    /// The prompt's line under a Web sign-in.
    public static let pasteHint = "If your browser doesn't come back to Fudge, copy the address from it and press ⌘V."
    /// Under the prompt, after a paste that doesn't end the sign-in.
    public static let pasteProblem = "That address isn't from this sign-in."

    /// The prompt's one line when Fudge doesn't open Raycast's links, so the sign-in can't come back by itself.
    public static func elsewhereHint(_ status: RaycastLinksStatus) -> String? {
        guard case .elsewhere(let app) = status else { return nil }
        let opener = app.map { "open \($0)" } ?? "don't open Fudge"
        return "Raycast links \(opener), so this sign-in can't come back by itself; Settings → Sign-in can change that."
    }
}

/// Who opens Raycast's links now (SPEC-132 §3.3).
public enum RaycastLinksStatus: Equatable, Sendable {
    /// How another copy of Fudge is named.
    public static let anotherFudge = "another copy of Fudge"

    /// Fudge opens both `raycast://oauth` and `com.raycast:/oauth`.
    case fudge
    /// Another app opens at least one of them, by its name; nil when no app does.
    case elsewhere(String?)

    public var isFudge: Bool { self == .fudge }

    /// Onboarding's line.
    public var line: String {
        switch self {
        case .fudge: "Raycast links open Fudge."
        case .elsewhere(let app?): "Raycast links open \(app)."
        case .elsewhere(nil): "No app opens Raycast links."
        }
    }

    /// The Sign-in page's row, after "Raycast links".
    public var row: String {
        switch self {
        case .fudge: "open with Fudge"
        case .elsewhere(let app?): "open with \(app)"
        case .elsewhere(nil): "no app opens them"
        }
    }
}

/// Which app opens a link, and making Fudge the one: LaunchServices in the app, a fake in tests and snapshot runs, so
/// neither ever changes the Mac's handlers.
public protocol RaycastLinks: Sendable {
    /// The app that opens `url` now, nil when none does.
    func opener(of url: URL) -> URL?
    /// The bundle identifier of the app at `app`, nil when it has none.
    func bundleIdentifier(of app: URL) -> String?
    /// Makes the app at `app` open links with `scheme`, throwing the system's error.
    func open(scheme: String, with app: URL) async throws
}

extension RaycastLinks {
    /// Who opens Raycast's links: Fudge (at `fudge`) only when it opens both shapes. Another app is named as the
    /// Finder names it; a copy of Fudge somewhere else on the Mac (another build claims the schemes too) is "another
    /// copy of Fudge".
    public func status(fudge: URL) -> RaycastLinksStatus {
        let others = RaycastReturn.links.map { opener(of: $0) }.filter { !Self.same($0, fudge) }
        guard let other = others.first else { return .fudge }
        return .elsewhere(
            other.map { app in
                let id = bundleIdentifier(of: app)
                return id != nil && id == bundleIdentifier(of: fudge)
                    ? RaycastLinksStatus.anotherFudge : Self.appName(app)
            })
    }

    /// **Open Raycast Links with Fudge**: makes Fudge open both schemes, then reads the status again. The system's
    /// message comes back when it refused.
    public func openWithFudge(_ fudge: URL) async -> (status: RaycastLinksStatus, problem: String?) {
        var problem: String?
        for scheme in RaycastReturn.schemes {
            do {
                try await open(scheme: scheme, with: fudge)
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        let status = status(fudge: fudge)
        if problem == nil, !status.isFudge { problem = "macOS didn't make Fudge open Raycast links." }
        return (status, problem)
    }

    static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// An app's name as the Finder shows it, without `.app`.
    static func appName(_ app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }
}

/// A `RaycastLinks` that never touches LaunchServices: tests and snapshot runs (`--raycast-links fudge|<app name>`).
public final class FixedRaycastLinks: RaycastLinks, @unchecked Sendable {
    private let lock = NSLock()
    private var openers: [String: URL]
    /// What `open` throws, if anything.
    public var refusal: (any Error)?
    /// Bundle identifiers by app path; none otherwise.
    public var identifiers: [String: String] = [:]
    /// The schemes `open` was asked to change, in order.
    public private(set) var opened: [String] = []

    /// Both schemes open `app` (nil: no app opens them).
    public init(app: URL?) {
        openers = Dictionary(
            uniqueKeysWithValues: RaycastReturn.schemes.compactMap { scheme in app.map { (scheme, $0) } })
    }

    /// For a snapshot run: `fudge` opens them, or an app of that name in `/Applications`.
    public convenience init(snapshotValue: String, fudge: URL) {
        self.init(
            app: snapshotValue == "fudge"
                ? fudge : URL(fileURLWithPath: "/Applications/\(snapshotValue).app", isDirectory: true))
    }

    public func opener(of url: URL) -> URL? {
        lock.withLock { url.scheme.flatMap { openers[$0.lowercased()] } }
    }

    public func bundleIdentifier(of app: URL) -> String? {
        lock.withLock { identifiers[app.path] }
    }

    public func open(scheme: String, with app: URL) async throws {
        try lock.withLock {
            opened.append(scheme)
            if let refusal { throw refusal }
            openers[scheme] = app
        }
    }
}

/// **Extensions with their own sign-in** (SPEC-132 §5, D-89): their own switch, off by default.
public enum OwnAppSignIn {
    public static let title = "Extensions with their own sign-in"
    /// The one line the Sign-in page, its consent sheet and onboarding all show: the architect's words (D-89).
    public static let explanation =
        "Let extensions sign in with their own apps. Most of them come back through raycast.com."

    /// The sheet before it's turned on.
    public enum Consent {
        public static let title = "Turn on extensions with their own sign-in?"
        public static let confirm = "Continue"
        public static let cancel = "Cancel"
    }
}

extension FudgeSettings {
    /// Whether extensions with their own sign-in may use it: switched on through the consent sheet, which records the
    /// date, so a hand-set `true` counts as off.
    public var isOwnAppSignInOn: Bool {
        ownAppSignIn && ownAppSignInConsentAt.flatMap(ISO8601DateFormatter().date(from:)) != nil
    }

    /// The switch: on records the consent date, off removes both keys.
    public mutating func setOwnAppSignIn(_ on: Bool, now: Date) {
        ownAppSignIn = on
        ownAppSignInConsentAt = on ? ISO8601DateFormatter().string(from: now) : nil
    }
}

/// Onboarding's Raycast step (SPEC-132 §3.3, D-88): why Fudge and Raycast can get in each other's way, the offer to
/// open Raycast's links with Fudge, and §5's switch.
public enum RaycastStep {
    public static let title = "Raycast"
    public static let explanation =
        "Fudge runs extensions made for Raycast. With Raycast on the same Mac, the two can get in each other's way. "
        + "Signing in to some extensions ends with a Raycast link, which has to open Fudge."
    /// Under the links button: what it changes besides sign-in.
    public static let linksNote = "Raycast's own links then open Fudge too."

    /// One of the step's buttons.
    public enum Button: Equatable, Sendable {
        /// **Open Raycast Links with Fudge**: changes the Mac's handler for `raycast` and `com.raycast`.
        case openLinks
        /// **Turn On**: what §5's switch and its sheet do.
        case turnOnOwnAppSignIn
        /// Continue, or Not Now while something is offered: changes nothing.
        case next

        public var title: String {
            switch self {
            case .openLinks: "Open Raycast Links with Fudge"
            case .turnOnOwnAppSignIn: "Turn On"
            case .next: "Continue"
            }
        }
    }

    /// The step's buttons, in order, and the one ↵ presses, which is always `next`: no step changes the Mac or turns
    /// something on by ↵ alone.
    public static func buttons(links: RaycastLinksStatus, ownAppSignInOn: Bool) -> (
        all: [Button], defaultButton: Button
    ) {
        var all: [Button] = []
        if !links.isFudge { all.append(.openLinks) }
        if !ownAppSignInOn { all.append(.turnOnOwnAppSignIn) }
        return (all + [.next], .next)
    }

    /// The title of `next`: Not Now while the step offers something, else Continue.
    public static func nextTitle(links: RaycastLinksStatus, ownAppSignInOn: Bool) -> String {
        links.isFudge && ownAppSignInOn ? "Continue" : "Not Now"
    }
}
