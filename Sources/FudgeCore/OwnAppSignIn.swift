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
    /// The schemes Fudge Links declares for it (`CFBundleURLTypes` in `App/Links/Info.plist`), which are Raycast's
    /// own. Fudge.app itself declares none (SPEC-140, D-107).
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

/// Who opens Raycast's links now (SPEC-132 §3.3, SPEC-140 §3.1).
public enum RaycastLinksStatus: Equatable, Sendable {
    /// How another copy of Fudge is named.
    public static let anotherFudge = "another copy of Fudge"

    /// Fudge opens both `raycast://oauth` and `com.raycast:/oauth`, through its Fudge Links.
    case fudge
    /// Another app opens at least one of them, by its name; nil when no app does.
    case elsewhere(String?)

    public var isFudge: Bool { self == .fudge }

    /// Onboarding's line, and the Sign-in page's switch's while it's off.
    public var line: String {
        switch self {
        case .fudge: "Raycast links open Fudge."
        case .elsewhere(let app?): "Raycast links open \(app)."
        case .elsewhere(nil): "No app opens Raycast links."
        }
    }
}

/// The Sign-in page's switch, **Fudge opens Raycast links** (D-114). It shows who opens them, read from
/// LaunchServices whenever the page appears or its window becomes key, never a stored value. On does what Open Raycast
/// Links with Fudge does; off gives both schemes back to the other app that claims them.
public struct RaycastLinksToggle: Equatable, Sendable {
    public static let title = "Fudge opens Raycast links"
    public static let explanation = "Signing in to some extensions ends with one, which has to open Fudge."
    /// Under the switch while it's on and no other app claims both schemes, so there's nothing to give them back to.
    public static let nothingToGiveBack = "No other app can open them, so Fudge keeps them."

    public var isOn: Bool
    /// Off can always be switched on (from the disk image, the refusal shows then); on only with an app to give the
    /// links back to.
    public var canChange: Bool
    /// The line under it: who opens them, or who gets them back when it's turned off.
    public var note: String

    /// `giveBackTo` is the name of the app turning it off gives them back to (`RaycastLinks.handBackTarget`).
    public init(status: RaycastLinksStatus, giveBackTo: String?) {
        isOn = status.isFudge
        guard isOn else {
            canChange = true
            note = status.line
            return
        }
        canChange = giveBackTo != nil
        note = giveBackTo.map { "Turn it off to give them back to \($0)." } ?? Self.nothingToGiveBack
    }
}

/// **Fudge Links** (SPEC-140, D-107): the small app inside Fudge.app, the only part of Fudge that declares Raycast's
/// schemes. Only the user's Open with Fudge registers it with LaunchServices, so no build, launch, snapshot run, copy or
/// Spotlight makes Fudge open Raycast's links. macOS opens it with a link; it hands the link to Fudge as a get-URL Apple
/// Event and quits. Its decisions are here, so they're tested.
public enum RaycastLinksHelper {
    /// Its own bundle identifier, under Fudge's: macOS saves the user's choice by bundle identifier, not path.
    public static let bundleIdentifier = FudgeVersion.bundleIdentifier + ".links"
    /// Its name, the file's and the bundle's, so whatever macOS shows names it the same way.
    public static let name = "Fudge Links"
    /// How long it waits for a link when it's launched without one, before quitting.
    public static let idleQuitSeconds = 10.0

    /// Where it is inside the app at `app`: `<app>/Contents/Helpers/Fudge Links.app`, a place no launch, copy or
    /// Spotlight registers.
    public static func url(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/\(name).app", isDirectory: true)
    }

    /// The app that holds the helper at `helper`: three folders up.
    public static func holder(of helper: URL) -> URL {
        helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Whether it hands `link` on: only `raycast:` and `com.raycast:` links, the scheme ignoring case. Anything else is
    /// dropped. The link's shape is Fudge's to check (`RaycastReturn.read(link:state:)`).
    public static func handsOn(_ link: String) -> Bool {
        guard let scheme = URLComponents(string: link)?.scheme?.lowercased() else { return false }
        return RaycastReturn.schemes.contains(scheme)
    }

    /// Which Fudges get a link: every running one, each app once, the one holding the helper first, since each takes
    /// only its own sign-in's return. With none running, the holder, launched in the background, when it's Fudge;
    /// else none, and the link is dropped.
    public static func targets(running: [URL], holder: URL, holderIsFudge: Bool) -> [URL] {
        var seen = Set<String>()
        let distinct = running.filter { seen.insert(path(of: $0)).inserted }
        guard !distinct.isEmpty else { return holderIsFudge ? [holder] : [] }
        let holderPath = path(of: holder)
        return distinct.filter { path(of: $0) == holderPath } + distinct.filter { path(of: $0) != holderPath }
    }

    static func path(of app: URL) -> String {
        app.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Which app opens a link, and making Fudge the one: LaunchServices in the app, a fake in tests and snapshot runs, so
/// neither ever changes the Mac's handlers.
public protocol RaycastLinks: Sendable {
    /// The app that opens `url` now, nil when none does.
    func opener(of url: URL) -> URL?
    /// Every app that can open `url`.
    func claimants(of url: URL) -> [URL]
    /// The bundle identifier of the app at `app`, nil when it has none.
    func bundleIdentifier(of app: URL) -> String?
    /// Registers the app at `app` with LaunchServices, throwing the system's error.
    func register(_ app: URL) throws
    /// Makes the app at `app` open links with `scheme`, throwing the system's error.
    func open(scheme: String, with app: URL) async throws
}

extension RaycastLinks {
    /// Who opens Raycast's links: Fudge only when its Fudge Links (at `helper`) opens both shapes. Another app is named
    /// as the Finder names it; another copy's Fudge Links, or a Fudge that declares the schemes itself (a build from
    /// before Fudge Links), is "another copy of Fudge".
    public func status(helper: URL) -> RaycastLinksStatus {
        let others = RaycastReturn.links.map { opener(of: $0) }.filter { !Self.same($0, helper) }
        guard let other = others.first else { return .fudge }
        return .elsewhere(
            other.map { app in
                Self.isFudges(bundleIdentifier(of: app)) ? RaycastLinksStatus.anotherFudge : Self.appName(app)
            })
    }

    /// The app turning the switch off gives Raycast's links back to: the first that claims both shapes and isn't
    /// Fudge's (neither this Fudge Links nor any app with Fudge's or Fudge Links' bundle identifier). Nil when there's
    /// none, since there's no public way to unregister Fudge Links.
    public func handBackTarget(helper: URL) -> URL? {
        let both = claimants(of: RaycastReturn.links[1])
        return claimants(of: RaycastReturn.links[0]).first { app in
            !Self.same(app, helper) && !Self.isFudges(bundleIdentifier(of: app)) && both.contains { Self.same($0, app) }
        }
    }

    /// **Open Raycast Links with Fudge**, or switching it on (SPEC-140 §3.2): registers Fudge Links, makes it open
    /// both schemes, then reads the status again. Nothing changes while Fudge runs from its disk image or a
    /// translocated copy, whose Fudge Links goes away. The system's message comes back when it refused.
    public func openWithFudge(helper: URL, location: AppLocation) async -> (
        status: RaycastLinksStatus, problem: String?
    ) {
        if let refusal = location.raycastLinksRefusal { return (status(helper: helper), refusal) }
        do {
            try register(helper)
        } catch {
            return (status(helper: helper), error.localizedDescription)
        }
        var problem: String?
        for scheme in RaycastReturn.schemes {
            do {
                try await open(scheme: scheme, with: helper)
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        let status = status(helper: helper)
        if problem == nil, !status.isFudge { problem = "macOS didn't make Fudge open Raycast links." }
        return (status, problem)
    }

    /// Switching it off (D-114): gives both schemes back to `app` explicitly, so the choice macOS saves names that app
    /// and Fudge Links can't take them back without a click. Then reads the status again.
    public func giveBack(to app: URL, helper: URL) async -> (status: RaycastLinksStatus, problem: String?) {
        var problem: String?
        for scheme in RaycastReturn.schemes {
            do {
                try await open(scheme: scheme, with: app)
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        let status = status(helper: helper)
        if problem == nil, status.isFudge { problem = "macOS didn't give Raycast links back to \(Self.appName(app))." }
        return (status, problem)
    }

    static func isFudges(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == FudgeVersion.bundleIdentifier || bundleIdentifier == RaycastLinksHelper.bundleIdentifier
    }

    static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return RaycastLinksHelper.path(of: a) == RaycastLinksHelper.path(of: b)
    }

    /// An app's name as the Finder shows it, without `.app`.
    public static func appName(_ app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }
}

/// A `RaycastLinks` that never touches LaunchServices: tests and snapshot runs (`--raycast-links fudge|<app name>`, or
/// `fudge,<app name>` for Fudge Links opening them with that app claiming them too).
public final class FixedRaycastLinks: RaycastLinks, @unchecked Sendable {
    private let lock = NSLock()
    private var openers: [String: URL]
    private var claimantsByScheme: [String: [URL]]
    /// What `open` throws, if anything.
    public var refusal: (any Error)?
    /// What `register` throws, if anything.
    public var registrationRefusal: (any Error)?
    /// Bundle identifiers by app path; none otherwise.
    public var identifiers: [String: String] = [:]
    /// The schemes `open` was asked to change, in order.
    public private(set) var opened: [String] = []
    /// The apps `register` was asked to register, in order.
    public private(set) var registered: [URL] = []

    /// Both schemes open `app`, the only app that claims them (nil: no app opens or claims them).
    public init(app: URL?) {
        openers = Dictionary(
            uniqueKeysWithValues: RaycastReturn.schemes.compactMap { scheme in app.map { (scheme, $0) } })
        claimantsByScheme = Dictionary(
            uniqueKeysWithValues: RaycastReturn.schemes.map { scheme in (scheme, app.map { [$0] } ?? []) })
    }

    /// For a snapshot run: `fudge` (Fudge Links at `helper`) or an app of that name in `/Applications` opens them, and
    /// any app named after a comma claims them too.
    public convenience init(snapshotValue: String, helper: URL) {
        let apps = snapshotValue.split(separator: ",").map { name in
            name == "fudge" ? helper : URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
        }
        self.init(app: apps.first)
        for app in apps.dropFirst() { claim(app) }
    }

    /// Adds `app` to the apps that claim both schemes, opening neither.
    public func claim(_ app: URL) {
        lock.withLock {
            for scheme in RaycastReturn.schemes where !(claimantsByScheme[scheme] ?? []).contains(app) {
                claimantsByScheme[scheme, default: []].append(app)
            }
        }
    }

    public func opener(of url: URL) -> URL? {
        lock.withLock { url.scheme.flatMap { openers[$0.lowercased()] } }
    }

    public func claimants(of url: URL) -> [URL] {
        lock.withLock { url.scheme.flatMap { claimantsByScheme[$0.lowercased()] } ?? [] }
    }

    public func bundleIdentifier(of app: URL) -> String? {
        lock.withLock { identifiers[app.path] }
    }

    public func register(_ app: URL) throws {
        try lock.withLock {
            registered.append(app)
            if let registrationRefusal { throw registrationRefusal }
        }
    }

    public func open(scheme: String, with app: URL) async throws {
        try lock.withLock {
            opened.append(scheme)
            if let refusal { throw refusal }
            openers[scheme] = app
            if !(claimantsByScheme[scheme] ?? []).contains(app) { claimantsByScheme[scheme, default: []].append(app) }
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
        /// **Open Raycast Links with Fudge**: registers Fudge Links and makes it the Mac's handler for `raycast` and
        /// `com.raycast`, as the Sign-in page's switch does.
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
