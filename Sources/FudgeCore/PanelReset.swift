import Foundation

/// "Pop to Root Search": how long the panel may stay hidden before it opens on an empty root search again. It's
/// `resetAfterSeconds` in `settings.json`: 0, 30, 60 or 90, or "never". A missing key, or any other value, is 90.
public enum PanelResetSetting: Sendable, Equatable, CaseIterable, Identifiable {
    case immediately
    case after30Seconds
    case after1Minute
    case after90Seconds
    case never

    public static let `default` = PanelResetSetting.after90Seconds

    public var id: Self { self }

    /// How long the panel must stay hidden; nil for never.
    public var limit: Duration? {
        switch self {
        case .immediately: .zero
        case .after30Seconds: .seconds(30)
        case .after1Minute: .seconds(60)
        case .after90Seconds: .seconds(90)
        case .never: nil
        }
    }

    public var title: String {
        switch self {
        case .immediately: "Immediately"
        case .after30Seconds: "After 30 seconds"
        case .after1Minute: "After 1 minute"
        case .after90Seconds: "After 90 seconds"
        case .never: "Never"
        }
    }

    /// Reads the `settings.json` value. A JSON `false` isn't 0, and anything that isn't one of the five reads as 90.
    public init(settingsValue value: Any?) {
        if let text = value as? String, text == "never" {
            self = .never
            return
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let seconds = number as? Int
        else {
            self = .default
            return
        }
        self = Self.allCases.first { $0.limit == .seconds(seconds) } ?? .default
    }

    /// The `settings.json` value: nil for the default, which isn't written.
    public var settingsValue: Any? {
        switch self {
        case .never: "never"
        case .after90Seconds: nil
        default: limit.map { Int($0.components.seconds) }
        }
    }
}

/// Remembers when the panel was hidden, and tells a path that's about to show it whether to reset it first
/// (FUD-48). Only time spent hidden counts: showing the panel forgets the hide. Time is measured on a clock that
/// keeps running while the Mac sleeps, so a panel hidden overnight resets. `now` is injected so tests fix it.
public final class PanelReset {
    public var setting: PanelResetSetting
    public private(set) var hiddenAt: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant

    public init(
        setting: PanelResetSetting = .default, now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.setting = setting
        self.now = now
    }

    /// The panel was hidden, by any path.
    public func panelHidden() {
        hiddenAt = now()
    }

    /// The panel was shown: time spent visible never counts, so a panel left open isn't reset under the user.
    public func panelShown() {
        hiddenAt = nil
    }

    /// Whether the panel, hidden now, has been hidden long enough to reset before a path shows it. A yes forgets
    /// the hide, so asking twice resets once. A no keeps it: a no-view command run while hidden doesn't use it up.
    public func takeDue() -> Bool {
        guard let hiddenAt, Self.isDue(hiddenFor: now() - hiddenAt, setting: setting) else { return false }
        self.hiddenAt = nil
        return true
    }

    /// Runs a path that shows the panel: first `reset`, when it's due, then the path's own `build`. Building on
    /// top of the reset is what keeps a hotkey's or `launchCommand`'s target on screen after a long hide; a reset
    /// after the build (as in `presented()`) would throw the target away.
    public func enter<T>(reset: () -> Void, build: () -> T) -> T {
        if takeDue() { reset() }
        return build()
    }

    public static func isDue(hiddenFor duration: Duration, setting: PanelResetSetting) -> Bool {
        guard let limit = setting.limit else { return false }
        return duration >= limit
    }
}
