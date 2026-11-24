import Foundation

/// Where a call that may show an alert or a window came from (SPEC-045). Only a call the user started may bring
/// Fudge forward: activate it, show an alert, open a window, or ask for macOS's Accessibility prompt.
public enum CallOrigin: Sendable, Equatable {
    /// A command the user opened (root search, a hotkey, an alias, a menu-bar item they picked, a user-initiated
    /// `launchCommand`), or the user's own click in Fudge.
    case userInitiated
    /// A menu-bar command's interval refresh, a background `launchCommand`, anything else the user didn't start.
    case background

    /// Whether Fudge may come forward for the call.
    public var mayComeForward: Bool { self == .userInitiated }

    /// The answer a confirmation gets without asking: `false` for a background call, as if the user had picked the
    /// dismiss button; nil when the user may be asked.
    public var unaskedAnswer: Bool? { mayComeForward ? nil : false }

    /// A command's calls, by how it was launched.
    public static func launched(userInitiated: Bool) -> CallOrigin {
        userInitiated ? .userInitiated : .background
    }
}

extension MenuBarLifecycle {
    /// A menu-bar session's calls are user-initiated while its menu is open, or while an `onAction` it was sent hasn't
    /// settled, since in a menu-bar command only the user's picks send events. That holds for an instance a background
    /// refresh started too. Otherwise they follow how the instance was launched. A session that isn't this command's
    /// instance any more is background.
    public func origin(of session: String) -> CallOrigin {
        let current: String? =
            switch phase {
            case .loaded(let loaded), .unloading(let loaded): loaded
            case .idle: nil
            }
        guard current == session else { return .background }
        if isMenuOpen || runningEvents > 0 { return .userInitiated }
        return .launched(userInitiated: isUserInitiated)
    }
}

extension LaunchRequest {
    /// The request as Fudge runs it for a caller with this origin. A background caller's request is a Background
    /// launch, whatever type it asks for: it can't show the panel, argument fields or Settings, and fails where a
    /// Background launch would. Only a session the user is using launches UserInitiated.
    public func asCalled(from origin: CallOrigin) -> LaunchRequest {
        guard type == .userInitiated, !origin.mayComeForward else { return self }
        var request = self
        request.type = .background
        return request
    }
}

/// What to do about "Allow <A> to open <B>'s commands?" for one `launchCommand`.
public enum LaunchPermissionStep: Sendable, Equatable {
    /// Answered before: allowed.
    case allowed
    /// Answered before: not allowed.
    case refused
    /// Not answered yet, and the user may be asked.
    case ask
    /// Not answered yet, and the call is a background one: refused without asking, and nothing is saved, so the
    /// question comes the next time the user opens the caller.
    case refusedUnasked
}

/// What to do about which copy a `launchCommand` opens, when two or more installs can run it (SPEC-177).
public enum CopyChoiceStep: Sendable, Equatable {
    /// Chosen before: open that copy.
    case open(ExtensionID)
    /// Answered "Don't Allow" before.
    case refused
    /// Not chosen yet, and the user may be asked.
    case ask
    /// Not chosen yet, and the call is a background one: refused without asking, as `LaunchPermissionStep`'s.
    case refusedUnasked
}

extension LaunchPermissions {
    /// The step for a call with this stored answer (nil: never answered) and origin.
    public static func step(answer: Bool?, origin: CallOrigin) -> LaunchPermissionStep {
        switch answer {
        case true?: .allowed
        case false?: .refused
        case nil: origin.mayComeForward ? .ask : .refusedUnasked
        }
    }

    /// The step for a call among copies, with this stored choice (`choice(caller:among:)`) and origin.
    public static func step(choice: CopyChoice, origin: CallOrigin) -> CopyChoiceStep {
        switch choice {
        case .chosen(let id): .open(id)
        case .notAllowed: .refused
        case .unanswered: origin.mayComeForward ? .ask : .refusedUnasked
        }
    }

    /// The HUD for a background call refused without asking.
    public static func unaskedNotice(callerTitle: String, targetTitle: String) -> String {
        "\(callerTitle) wants to open \(targetTitle). Open \(callerTitle) from Fudge to allow it."
    }
}

/// Notes for background calls, each shown at most once per key per run, so an interval refresh can't repeat one.
public struct OncePerRun: Sendable {
    private var shown: Set<String> = []

    public init() {}

    /// True the first time `key` comes up, false after that.
    public mutating func first(_ key: String) -> Bool {
        shown.insert(key).inserted
    }
}
