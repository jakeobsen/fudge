import CoreGraphics
import Foundation

/// "Show Fudge on": which screen the panel opens on (`showOnScreen` in `settings.json`).
public enum ShowOnScreen: String, Sendable, CaseIterable, Identifiable {
    case mouse
    case primary
    case activeWindow

    public static let `default` = ShowOnScreen.mouse
    public var id: Self { self }

    public var title: String {
        switch self {
        case .mouse: "Screen with mouse"
        case .primary: "Primary screen"
        case .activeWindow: "Screen with active window"
        }
    }

    /// A missing or unknown value is the default.
    public init(settingsValue value: Any?) {
        self = (value as? String).flatMap(Self.init(rawValue:)) ?? .default
    }

    /// The `settings.json` value: nil for the default, which isn't written.
    public var settingsValue: String? { self == .default ? nil : rawValue }
}

/// "Escape key behavior" (`escapeBehavior` in `settings.json`).
public enum EscapeBehavior: String, Sendable, CaseIterable, Identifiable {
    case back
    case closeAndReset

    public static let `default` = EscapeBehavior.back
    public var id: Self { self }

    public var title: String {
        switch self {
        case .back: "Navigate back or close window"
        case .closeAndReset: "Close window and pop to root"
        }
    }

    public init(settingsValue value: Any?) {
        self = (value as? String).flatMap(Self.init(rawValue:)) ?? .default
    }

    public var settingsValue: String? { self == .default ? nil : rawValue }
}

/// Picks the screen the panel opens on. Frames are in Cocoa coordinates (origin at the primary screen's bottom
/// left, y up), and `screens.first` is the primary screen, as `NSScreen.screens` has them.
public enum PanelScreen {
    /// The index of the screen to use; nil when there are no screens (the caller falls back to the main one).
    /// "Screen with active window" takes the screen holding most of the window, and falls back to the mouse's
    /// when there's no window or it's on no screen.
    public static func choose(
        setting: ShowOnScreen, screens: [CGRect], mouse: CGPoint, activeWindowFrame: CGRect?
    ) -> Int? {
        guard !screens.isEmpty else { return nil }
        switch setting {
        case .primary:
            return 0
        case .activeWindow:
            if let window = activeWindowFrame, let index = mostOf(window, on: screens) { return index }
            return withMouse(mouse, on: screens)
        case .mouse:
            return withMouse(mouse, on: screens)
        }
    }

    /// A window's bounds as `CGWindowListCopyWindowInfo` gives them (origin at the primary screen's top left, y
    /// down), in Cocoa coordinates.
    public static func cocoaFrame(windowListBounds bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX, y: primaryHeight - bounds.minY - bounds.height, width: bounds.width, height: bounds.height)
    }

    /// A Cocoa frame (bottom-left origin, such as `NSScreen.visibleFrame`) in the window list's and the Accessibility
    /// API's top-left coordinates, against the primary screen's height: the same flip as `cocoaFrame`, which is its
    /// own inverse. Never against another screen's height.
    public static func topLeftFrame(cocoa frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        cocoaFrame(windowListBounds: frame, primaryHeight: primaryHeight)
    }

    /// The screen the mouse is on, as `NSMouseInRect` reads a point in an unflipped rect.
    static func withMouse(_ mouse: CGPoint, on screens: [CGRect]) -> Int? {
        screens.firstIndex { mouse.x >= $0.minX && mouse.x < $0.maxX && mouse.y > $0.minY && mouse.y <= $0.maxY }
    }

    /// The screen holding the largest part of `window`; nil when it's on none.
    static func mostOf(_ window: CGRect, on screens: [CGRect]) -> Int? {
        let areas = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }
}

/// What Esc does next in the panel, by "Escape key behavior" (`EscapeBehavior`).
public enum EscapeAction: Sendable, Equatable {
    case closeDropdown
    /// Closes the action panel's open submenu, or the panel itself.
    case closeActionPanel
    /// Closes the Quick Look preview, and does nothing else.
    case closeQuickLook
    case popView
    case clearSearch
    case leaveCommand
    /// Leaves a failure for root search.
    case dismissFailure
    case hide
    /// Hides the panel at once and starts over on root search, as Pop to Root Search's reset does.
    case hideAndReset

    /// The panel's state, as far as Esc goes.
    public struct State: Sendable, Equatable {
        public enum Screen: Sendable, Equatable {
            case root(queryEmpty: Bool)
            /// A running command: how many views deep, whether its search text is empty, whether it's a Form.
            case command(depth: Int, searchEmpty: Bool, isForm: Bool)
            case failure
        }

        public var dropdownOpen: Bool
        public var actionPanelOpen: Bool
        public var quickLookOpen: Bool
        public var screen: Screen

        public init(
            dropdownOpen: Bool = false, actionPanelOpen: Bool = false, quickLookOpen: Bool = false, screen: Screen
        ) {
            self.dropdownOpen = dropdownOpen
            self.actionPanelOpen = actionPanelOpen
            self.quickLookOpen = quickLookOpen
            self.screen = screen
        }
    }

    /// Popovers (the dropdown's panel, the action panel) close first either way, then the Quick Look preview. A
    /// Form keeps navigating back, since Esc belongs to it there.
    public static func next(behavior: EscapeBehavior, state: State) -> EscapeAction {
        if state.dropdownOpen { return .closeDropdown }
        if state.actionPanelOpen { return .closeActionPanel }
        if state.quickLookOpen { return .closeQuickLook }
        var behavior = behavior
        if case .command(_, _, true) = state.screen { behavior = .back }
        guard behavior == .back else { return .hideAndReset }
        switch state.screen {
        case .root(let queryEmpty):
            return queryEmpty ? .hide : .clearSearch
        case .failure:
            return .dismissFailure
        case .command(let depth, let searchEmpty, _):
            if depth > 1 { return .popView }
            if !searchEmpty { return .clearSearch }
            return .leaveCommand
        }
    }
}
