import Foundation

/// A key pressed before the selected List or Grid item's actions came (`Item.deferred`): ↵, ⌘↵ and ⌘K wait for
/// them rather than doing nothing, and so does a shortcut of those actions, which the host names with the item
/// (`Item.waitsForActions`). Other keys don't wait: they'd hold back the search field's ⌘A or ⌘V.
///
/// `LauncherModel` holds one at a time. Another key that waits replaces it, and its time starts over. Esc, the panel
/// hiding, and leaving the view (a push, a pop, another command, root search) drop it, saying nothing: a held key
/// never runs or times out out of sight. If the actions haven't come `timeout` after the press, it's dropped with a
/// failure toast (`timeoutMessage`) and never tried again.
public struct HeldKey: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// ↵, the primary action.
        case primary
        /// ⌘↵, the secondary action.
        case secondary
        /// ⌘K, the action panel.
        case actionPanel
        /// One of the actions' own shortcuts.
        case shortcut(KeyShortcut)
    }

    public static let timeout: Duration = .seconds(2)
    public static let timeoutMessage = "This command didn't send its actions in time."

    public let key: Key
    /// The command session, its view (`depth`) and the item it was pressed on.
    public let session: String
    public let depth: Int
    public let node: Int
    /// When it gives up: `timeout` after the press.
    public let deadline: ContinuousClock.Instant

    public init(_ key: Key, session: String, depth: Int, node: Int, pressedAt: ContinuousClock.Instant) {
        self.key = key
        self.session = session
        self.depth = depth
        self.node = node
        deadline = pressedAt + Self.timeout
    }

    /// What the launcher shows when the key is settled.
    public struct Screen: Sendable, Equatable {
        /// Whether the panel is on screen.
        public var panelShown: Bool
        /// The command on screen, and its view, if any.
        public var session: String?
        public var depth: Int
        /// The selected List or Grid item, and whether its actions have come.
        public var selected: Int?
        public var actionsCame: Bool

        public init(panelShown: Bool, session: String?, depth: Int, selected: Int?, actionsCame: Bool) {
            self.panelShown = panelShown
            self.session = session
            self.depth = depth
            self.selected = selected
            self.actionsCame = actionsCame
        }
    }

    /// Whether the key still belongs to what's on screen: the panel is shown, with the same command, view and
    /// selected item.
    public func applies(to screen: Screen) -> Bool {
        screen.panelShown && screen.session == session && screen.depth == depth && screen.selected == node
    }

    public enum Outcome: Sendable, Equatable {
        /// The actions haven't come yet, and there's time left.
        case wait
        /// They came in time: run the key.
        case run(Key)
        /// The panel hid, the view changed or the selection moved: drop it, saying nothing.
        case drop
        /// They didn't come in time: drop it, with the toast.
        case timedOut
    }

    /// What to do with the key at `now`, with `screen` on show. Actions that come at the deadline or later are too
    /// late, so the key never runs more than `timeout` after it was pressed.
    public func outcome(at now: ContinuousClock.Instant, on screen: Screen) -> Outcome {
        guard applies(to: screen) else { return .drop }
        if now >= deadline { return .timedOut }
        return screen.actionsCame ? .run(key) : .wait
    }
}
