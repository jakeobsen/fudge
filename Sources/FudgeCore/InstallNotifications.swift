import Foundation

/// What macOS says about Fudge's notifications (SPEC-156 F, G), as `SystemInstallNotifications` reads it from
/// `UNUserNotificationCenter`'s settings: never asked, allowed (banners or alerts), allowed with the style None (kept in
/// Notification Center only), off, or a read that failed.
public enum NotificationPermission: String, Sendable, Equatable, CaseIterable {
    case notAsked = "not-asked"
    case allowed
    case quiet
    case off
    case unknown

    /// Whether a notification may be posted: macOS allows it, shown or only kept in Notification Center.
    public var mayPost: Bool { self == .allowed || self == .quiet }

    /// The Notifications page's line for it, and its button: Ask Now while macOS hasn't been asked, else Open
    /// Notification Settings.
    public var statusLine: String {
        switch self {
        case .notAsked: "macOS asks whether Fudge may show notifications when you first install or update an extension."
        case .allowed: "macOS shows Fudge's notifications."
        case .quiet: "macOS keeps Fudge's notifications in Notification Center without showing them."
        case .off: "Notifications for Fudge are off in macOS. Turn them on in System Settings to see these."
        case .unknown: "macOS didn't say whether Fudge may show notifications."
        }
    }

    public var buttonTitle: String { self == .notAsked ? "Ask Now" : "Open Notification Settings" }

    /// The pane Open Notification Settings opens.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
}

/// Posting, asking and reading macOS's answer. The app's `SystemInstallNotifications` is the only code that calls
/// `UNUserNotificationCenter` (SPEC-156 C.6); snapshot runs get `FixedInstallNotifications`, tests a recording fake.
public protocol InstallNotifications: Sendable {
    /// macOS's answer, read and never asked.
    func permission() async -> NotificationPermission
    /// Asks macOS once (`requestAuthorization(options: [.alert])`); only from the user's actions (G).
    func requestPermission() async
    /// Posts at once, with no sound; throws when macOS refuses it.
    func post(_ notice: InstallNotice) async throws
}

/// A fixed answer and nothing posted, for snapshot runs (`--notifications not-asked|allowed|quiet|off|unknown`).
public struct FixedInstallNotifications: InstallNotifications {
    public let fixed: NotificationPermission

    public init(_ fixed: NotificationPermission) { self.fixed = fixed }

    /// `--notifications <value>` in a snapshot run's arguments, else not asked.
    public init(arguments: [String]) {
        let value = arguments.firstIndex(of: "--notifications").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        self.init(value.flatMap(NotificationPermission.init(rawValue:)) ?? .notAsked)
    }

    public func permission() async -> NotificationPermission { fixed }
    public func requestPermission() async {}
    public func post(_ notice: InstallNotice) async throws {}

    /// The notifications, picked once at launch: a snapshot run always gets the fixed answer from its arguments, and
    /// `system` (the only code that touches `UNUserNotificationCenter`) is called only when it isn't one.
    public static func pick(
        snapshot: Bool, arguments: [String], system: () -> any InstallNotifications
    ) -> any InstallNotifications {
        snapshot ? FixedInstallNotifications(arguments: arguments) : system()
    }
}

/// The two switches on Settings → Notifications (`notifyInstallFinished`, `notifyInstallFailed`).
public struct InstallNotificationSwitches: Sendable, Equatable {
    public var finished: Bool
    public var failed: Bool

    public init(finished: Bool, failed: Bool) {
        self.finished = finished
        self.failed = failed
    }

    public init(_ settings: FudgeSettings) {
        self.init(finished: settings.notifyInstallFinished, failed: settings.notifyInstallFailed)
    }

    /// Whether either is on, so a confirmed install asks macOS (G).
    public var any: Bool { finished || failed }
}

/// An install or update from the Extension Store that ended: from the store's report (`store.installEnded`), or from a
/// build's outcome while no store session is loaded.
public struct InstallEnd: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case installed
        case failed
        /// `fudge build`'s 75: another build of it was running. Neither, so nothing is said.
        case alreadyBuilding
    }

    /// The build, when there was one; a refusal before any build has none.
    public var build: InstallBuild?
    public var name: String
    public var dir: String
    public var title: String
    public var updating: Bool
    public var outcome: Outcome

    public init(build: InstallBuild?, name: String, dir: String, title: String, updating: Bool, outcome: Outcome) {
        self.build = build
        self.name = name
        self.dir = dir
        self.title = title
        self.updating = updating
        self.outcome = outcome
    }

    /// The store's report (`store.installEnded`): `{ build?: { pid, startedAt }, name, dir, title, updating, outcome }`,
    /// `outcome` "installed" or "failed"; nil when anything is off.
    public init?(report: JSONValue) {
        guard case .object(let values) = report, case .string(let name) = values["name"],
            ExtensionManifest.isValidName(name), case .string(let dir) = values["dir"],
            StoreBuildRecord.isValidFolder(dir), case .string(let title) = values["title"],
            case .bool(let updating) = values["updating"], case .string(let outcomeName) = values["outcome"]
        else { return nil }
        let outcome: Outcome
        switch outcomeName {
        case "installed": outcome = .installed
        case "failed": outcome = .failed
        default: return nil
        }
        var build: InstallBuild?
        switch values["build"] {
        case nil, .null:
            build = nil
        case .object(let fields):
            guard case .number(let pid) = fields["pid"], pid.rounded() == pid, pid >= 1, pid <= Double(Int32.max),
                case .string(let startedAt) = fields["startedAt"], StoreBuildRecord.time(startedAt) != nil
            else { return nil }
            build = InstallBuild(pid: Int32(pid), startedAt: startedAt)
        default:
            return nil
        }
        self.init(build: build, name: name, dir: dir, title: title, updating: updating, outcome: outcome)
    }

    /// A build that ended while no store session was loaded, from its record and the status it wrote.
    public init(record: StoreBuildRecord, status: Int32) {
        let outcome: Outcome =
            status == 0 ? .installed : status == Int32(BuildError.alreadyBuildingStatus) ? .alreadyBuilding : .failed
        self.init(
            build: record.build, name: record.name, dir: record.dir, title: record.title, updating: record.updating,
            outcome: outcome)
    }
}

/// What a notification opens: the extension's row, and its failure view when it failed. It's the notification's
/// `userInfo`, checked before anything is done with a click (SPEC-156 E.3). `repository` is room for extension
/// repositories, never set here and passed on untouched.
public struct NoticeTarget: Sendable, Equatable {
    public var name: String
    public var dir: String
    public var failed: Bool
    public var repository: String?

    public init(name: String, dir: String, failed: Bool, repository: String? = nil) {
        self.name = name
        self.dir = dir
        self.failed = failed
        self.repository = repository
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["name": name, "dir": dir, "failed": failed]
        if let repository { info["repository"] = repository }
        return info
    }

    /// The target in a notification's `userInfo`, or nil when anything is off: a name that isn't valid, a folder that
    /// isn't one of the store's (a path), `failed` missing or not a boolean, a `repository` that isn't a string.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let name = userInfo["name"] as? String, ExtensionManifest.isValidName(name),
            let dir = userInfo["dir"] as? String, StoreBuildRecord.isValidFolder(dir),
            let failed = StoreBuildRecord.boolean(userInfo["failed"])
        else { return nil }
        let repository = userInfo["repository"]
        guard repository == nil || repository is String else { return nil }
        self.init(name: name, dir: dir, failed: failed, repository: repository as? String)
    }

    /// The target as the store gets it, from a click (`nextNotificationClick`) or in its launch context.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "dir": .string(dir), "failed": .bool(failed)]
        if let repository { object["repository"] = .string(repository) }
        return .object(object)
    }

    /// The store's `launchContext` for it: `{ "storeNotification": { name, dir, failed } }`.
    public var launchContext: JSONValue { .object(["storeNotification": json]) }
}

/// One notification (SPEC-156 C.3): finished `<title> is installed` or `is updated`, with no body; failed `Couldn't
/// install <title>` or `Couldn't update <title>`, with `Click to see what went wrong.`. Its identifier is
/// `store:<name>`, so a newer one for the same extension replaces the older one in Notification Center.
public struct InstallNotice: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String?
    public var target: NoticeTarget

    /// The longest extension title a notification shows.
    public static let maxTitle = 100

    public init(identifier: String, title: String, body: String?, target: NoticeTarget) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.target = target
    }

    /// The notice for `end`; nil for a 75, which says nothing.
    public init?(_ end: InstallEnd) {
        let title = Self.plain(end.title)
        let failed: Bool
        switch end.outcome {
        case .alreadyBuilding: return nil
        case .installed: failed = false
        case .failed: failed = true
        }
        let text =
            failed
            ? "Couldn't \(end.updating ? "update" : "install") \(title)"
            : "\(title) is \(end.updating ? "updated" : "installed")"
        self.init(
            identifier: "store:\(end.name)", title: text, body: failed ? "Click to see what went wrong." : nil,
            target: NoticeTarget(name: end.name, dir: end.dir, failed: failed))
    }

    /// The title as plain text on one line, cut to `maxTitle` characters; an empty one is "An extension".
    static func plain(_ title: String) -> String {
        let line = String(
            String.UnicodeScalarView(
                title.unicodeScalars.map {
                    $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
                })
        )
        .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "An extension" : String(line.prefix(maxTitle))
    }
}

/// The store's answer to `store.installEnded`: whether its screen is up, and whether a notification went out.
public struct InstallAnswer: Sendable, Equatable {
    public var onScreen: Bool
    public var notified: Bool

    /// As the store gets it: `{ onScreen, notified }`.
    public var json: JSONValue { .object(["onScreen": .bool(onScreen), "notified": .bool(notified)]) }

    public init(onScreen: Bool, notified: Bool) {
        self.onScreen = onScreen
        self.notified = notified
    }
}

/// The one place that decides whether an install's end gets a notification (SPEC-156 C.1, C.2), once per build. A
/// build is known by its pid and its record's `startedAt`. While a store session is loaded, only its reports decide;
/// with none loaded, a build's outcome does, and the session's end reads the folder once for outcomes it left. The
/// last `memory` builds' answers are kept for the run.
public struct InstallNotices: Sendable {
    public static let memory = 256

    private var answers: [InstallBuild: InstallAnswer] = [:]
    private var order: [InstallBuild] = []

    public init() {}

    /// The answer this build already got, if any.
    public func answer(for build: InstallBuild?) -> InstallAnswer? {
        build.flatMap { answers[$0] }
    }

    /// Whether `end` gets a notification, and the notice to post when it does. A build decided before gets its first
    /// answer and no notice. `onScreen`: the panel is visible and its command is a store session.
    public mutating func decide(
        _ end: InstallEnd, onScreen: Bool, switches: InstallNotificationSwitches, permission: NotificationPermission
    ) -> (answer: InstallAnswer, notice: InstallNotice?) {
        if let earlier = answer(for: end.build) { return (earlier, nil) }
        let wanted: Bool
        switch end.outcome {
        case .installed: wanted = switches.finished
        case .failed: wanted = switches.failed
        case .alreadyBuilding: wanted = false
        }
        let notice = !onScreen && wanted && permission.mayPost ? InstallNotice(end) : nil
        let answer = InstallAnswer(onScreen: onScreen, notified: notice != nil)
        remember(end.build, answer)
        return (answer, notice)
    }

    /// Counts `build` as decided with nothing posted: an outcome found at launch, which ended while Fudge wasn't running,
    /// or a notice macOS refused.
    public mutating func markDecided(_ build: InstallBuild, onScreen: Bool = false) {
        remember(build, InstallAnswer(onScreen: onScreen, notified: false), replacing: true)
    }

    private mutating func remember(_ build: InstallBuild?, _ answer: InstallAnswer, replacing: Bool = false) {
        guard let build else { return }
        if answers[build] != nil {
            if replacing { answers[build] = answer }
            return
        }
        answers[build] = answer
        order.append(build)
        if order.count > Self.memory {
            answers[order.removeFirst()] = nil
        }
    }
}

/// Where a notification's click goes (SPEC-156 E.1, E.2): to the store session that's loaded, through the
/// `store.nextNotificationClick` call it keeps waiting (or kept for its next call when none waits), else a launch of the
/// store with the target as its launch context. A session that ends drops its waiting call and its kept click.
extension ExtensionStore {
    /// The store session on the screen's command (SPEC-156 C.1, E.2): that command's session, when it's the store's and
    /// still running in the host. One whose host stopped counts as none, so a click launches the store again rather than
    /// wait for a call that can't come, and the store isn't on screen for an install's end.
    public static func sessionOnScreen(
        _ session: String?, extensionName: String?, isRunning: (String) -> Bool
    ) -> String? {
        guard let session, extensionName == Self.extensionName, isRunning(session) else { return nil }
        return session
    }
}

public struct NotificationClicks<Call: Sendable>: Sendable {
    public enum Route: Sendable {
        /// Answer this waiting call with the target.
        case answer(Call, NoticeTarget)
        /// No call waits: the target is kept for the session's next one.
        case kept
        /// No store session is loaded: launch the store with the target as its launch context.
        case launch(NoticeTarget)
    }

    private var waiting: (session: String, call: Call)?
    private var kept: (session: String, target: NoticeTarget)?

    public init() {}

    /// A click on `target`, with the loaded store session's id when there is one.
    public mutating func click(_ target: NoticeTarget, loadedSession: String?) -> Route {
        guard let session = loadedSession else { return .launch(target) }
        if let waiting, waiting.session == session {
            self.waiting = nil
            return .answer(waiting.call, target)
        }
        kept = (session, target)
        return .kept
    }

    /// The store session's `nextNotificationClick` call: answered at once with a kept click, else kept waiting. A newer
    /// call from the session replaces an older one, which is returned to be answered with nothing.
    public mutating func wait(session: String, call: Call) -> (now: NoticeTarget?, replaced: Call?) {
        if let kept, kept.session == session {
            self.kept = nil
            return (kept.target, nil)
        }
        let replaced = waiting?.session == session ? waiting?.call : nil
        waiting = (session, call)
        return (nil, replaced)
    }

    /// The session ended: its waiting call (to be dropped) and kept click go.
    public mutating func ended(session: String) -> Call? {
        if kept?.session == session { kept = nil }
        guard let waiting, waiting.session == session else { return nil }
        self.waiting = nil
        return waiting.call
    }
}
