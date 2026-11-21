import CoreGraphics
import Foundation

// `WindowManagement` (FUD-93). The logic lives here; the app reads the window list and the Accessibility API behind
// `WindowSystem`, and tests supply a fake. Only public APIs are used, and those can't list Spaces, so Fudge reports
// one desktop per screen: the Space showing on it now.

/// A window as `CGWindowListCopyWindowInfo` lists it.
public struct ListedWindow: Sendable, Equatable {
    /// `kCGWindowNumber`: the window's id for extensions, as a string.
    public var number: Int
    /// `kCGWindowOwnerPID`.
    public var pid: Int32
    /// `kCGWindowLayer`: 0 for an app's ordinary windows.
    public var layer: Int
    /// `kCGWindowBounds`: origin at the primary screen's top left, y down, as Raycast gives them.
    public var bounds: CGRect
    /// `kCGWindowName`, which macOS gives only to apps with Screen Recording permission.
    public var title: String?
    /// `kCGWindowAlpha`: 0 for a window that's there but invisible.
    public var alpha: Double

    public init(number: Int, pid: Int32, layer: Int = 0, bounds: CGRect, title: String? = nil, alpha: Double = 1) {
        self.number = number
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.title = title
        self.alpha = alpha
    }
}

/// One of an app's windows as the Accessibility API has it (`kAXWindowsAttribute`). `handle` is the system's own
/// reference to it, an `AXUIElement` in the app.
public struct AXWindow<Handle> {
    public var handle: Handle
    /// `kAXPositionAttribute` and `kAXSizeAttribute`, in the window list's coordinates; nil when either is missing.
    public var frame: CGRect?
    /// `kAXTitleAttribute`.
    public var title: String?
    public var positionSettable: Bool
    public var sizeSettable: Bool
    /// `AXFullScreen`.
    public var fullScreen: Bool
    public var fullScreenSettable: Bool
    /// Whether it's the app's `kAXFocusedWindowAttribute`.
    public var focused: Bool
    /// `kAXMinimizedAttribute`. A minimized window isn't in the window list, so it's never matched to one.
    public var minimized: Bool

    public init(
        handle: Handle, frame: CGRect?, title: String? = nil, positionSettable: Bool = true,
        sizeSettable: Bool = true, fullScreen: Bool = false, fullScreenSettable: Bool = true, focused: Bool = false,
        minimized: Bool = false
    ) {
        self.handle = handle
        self.frame = frame
        self.title = title
        self.positionSettable = positionSettable
        self.sizeSettable = sizeSettable
        self.fullScreen = fullScreen
        self.fullScreenSettable = fullScreenSettable
        self.focused = focused
        self.minimized = minimized
    }
}

/// A screen: its `CGDirectDisplayID` and its bounds in the window list's coordinates (`CGDisplayBounds`).
public struct WindowScreen: Sendable, Equatable {
    public var id: UInt32
    public var bounds: CGRect
    /// The part windows go in, without the menu bar and the Dock (`NSScreen.visibleFrame`), in the same top-left
    /// coordinates as `bounds` (`PanelScreen.topLeftFrame`).
    public var visibleBounds: CGRect

    /// The screen's desktop: one per screen, for this run.
    var desktopId: String { "screen-\(id)" }

    public init(id: UInt32, bounds: CGRect, visibleBounds: CGRect? = nil) {
        self.id = id
        self.bounds = bounds
        self.visibleBounds = visibleBounds ?? bounds
    }
}

/// What `setWindowBounds` asks of a window.
public enum WindowChange: Sendable, Equatable {
    /// A new position, size or both; nil leaves that part as it is.
    case frame(position: CGPoint?, size: CGSize?)
    case fullScreen
    /// Out of macOS full screen, for Fudge's Toggle Full Screen.
    case exitFullScreen
}

/// What WindowManagement reads and changes. The app's reads the system off the main thread, since the Accessibility
/// API waits on other apps.
public protocol WindowSystem {
    associatedtype Handle
    /// The windows on screen, front to back.
    func listedWindows() -> [ListedWindow]
    /// The screens, the primary one first.
    func screens() -> [WindowScreen]
    /// The mouse, in the window list's coordinates.
    func mouseLocation() -> CGPoint
    /// The frontmost application.
    func frontmostPid() -> Int32?
    /// Raycast's `Application` for the app `pid`, or nil when it isn't a regular app (one with a Dock icon).
    func application(pid: Int32) -> JSONValue?
    /// The app's windows, as the Accessibility API lists them: front to back, as `kAXWindowsAttribute` has them.
    func axWindows(pid: Int32) -> [AXWindow<Handle>]
    /// Makes `change` to the window. Throws `WindowManagementError.failed` when the app refuses it.
    func apply(_ change: WindowChange, to window: Handle) throws
}

/// Why a WindowManagement call failed. `description` is the message the extension's promise rejects with.
public enum WindowManagementError: Error, Equatable, Sendable, CustomStringConvertible {
    case accessibilityNeeded
    case noActiveWindow
    case noWindow(id: String)
    /// The window closed while Fudge was changing it.
    case windowClosed
    case otherDesktop
    case cantMove
    case cantResize
    case cantMakeFullScreen
    case invalidOptions(String)
    case failed(String)

    public var description: String {
        switch self {
        case .accessibilityNeeded:
            "Fudge needs Accessibility permission to manage windows. "
                + "Allow Fudge in System Settings → Privacy & Security → Accessibility."
        case .noActiveWindow: "There is no active window"
        case .noWindow(let id): "No window with id \(id)"
        case .windowClosed: "The window closed before it could be changed"
        case .otherDesktop: "Fudge can't move windows between desktops."
        case .cantMove: "This window can't be moved"
        case .cantResize: "This window can't be resized"
        case .cantMakeFullScreen: "This window can't be made full screen"
        case .invalidOptions(let problem): "setWindowBounds: \(problem)"
        case .failed(let message): message
        }
    }
}

/// `WindowManagement`'s four calls, over a `WindowSystem`.
public struct WindowManager<System: WindowSystem> {
    public let system: System
    /// Fudge's own windows are never listed.
    public let ownPid: Int32

    public init(system: System, ownPid: Int32) {
        self.system = system
        self.ownPid = ownPid
    }

    /// `getDesktops()`: one per screen, the Space showing on it now.
    public func desktops() -> [JSONValue] {
        let reading = Reading(self)
        let active = reading.activeScreen()
        return reading.screens.map { screen in
            let front = reading.windows.first { reading.screen(of: $0)?.id == screen.id }
            let fullScreen = front.flatMap { reading.ax(for: $0)?.fullScreen } ?? false
            return .object([
                "id": .string(screen.desktopId),
                "screenId": .string(String(screen.id)),
                "size": .object([
                    "width": .number(Double(screen.bounds.width)), "height": .number(Double(screen.bounds.height)),
                ]),
                "active": .bool(screen.id == active?.id),
                "type": .string(fullScreen ? "FullScreen" : "User"),
            ])
        }
    }

    /// `getActiveWindow()`: the frontmost app's focused window.
    public func activeWindow() throws -> JSONValue {
        let reading = Reading(self)
        guard let active = reading.activeWindow(), let json = reading.json(active, active: true) else {
            throw WindowManagementError.noActiveWindow
        }
        return json
    }

    /// `getWindowsOnActiveDesktop()`: the windows on the active desktop's screen, front to back. Each screen is its
    /// own desktop, so a window on another screen isn't on the active desktop.
    public func windowsOnActiveDesktop() -> [JSONValue] {
        let reading = Reading(self)
        let desktop = reading.activeScreen()?.id
        let active = reading.activeWindow()?.number
        return reading.windows.filter { reading.screen(of: $0)?.id == desktop }.compactMap {
            reading.json($0, active: $0.number == active)
        }
    }

    /// `setWindowBounds(options)`: moves or resizes the window with `options.id`, or makes it full screen. Parts of
    /// the position or size left out keep their current value.
    public func setBounds(_ options: JSONValue) throws {
        guard case .object(let options) = options, case .string(let id) = options["id"] else {
            throw WindowManagementError.invalidOptions("id must be a string")
        }
        let reading = Reading(self)
        guard let number = Int(id), let listed = reading.windows.first(where: { $0.number == number }) else {
            throw WindowManagementError.noWindow(id: id)
        }
        let window = reading.ax(for: listed)
        if let desktop = options["desktopId"], desktop != .null {
            guard case .string(let wanted) = desktop else {
                throw WindowManagementError.invalidOptions("desktopId must be a string")
            }
            guard wanted == reading.screen(of: listed)?.desktopId else {
                throw WindowManagementError.otherDesktop
            }
        }
        switch options["bounds"] {
        case .string("fullscreen"):
            guard let window, window.fullScreenSettable else { throw WindowManagementError.cantMakeFullScreen }
            if !window.fullScreen { try system.apply(.fullScreen, to: window.handle) }
        case .object(let bounds):
            let position = try Self.parts(of: bounds["position"], named: "position", keys: ("x", "y"))
            let size = try Self.parts(of: bounds["size"], named: "size", keys: ("width", "height"))
            if [size.0, size.1].contains(where: { $0.map { $0 <= 0 } ?? false }) {
                throw WindowManagementError.invalidOptions("a window's width and height must be more than 0")
            }
            let moves = position.0 != nil || position.1 != nil
            let resizes = size.0 != nil || size.1 != nil
            guard moves || resizes else { return }
            if moves, window?.positionSettable != true { throw WindowManagementError.cantMove }
            if resizes, window?.sizeSettable != true { throw WindowManagementError.cantResize }
            guard let window else { return }
            let current = window.frame ?? listed.bounds
            try system.apply(
                .frame(
                    position: moves ? CGPoint(x: position.0 ?? current.minX, y: position.1 ?? current.minY) : nil,
                    size: resizes
                        ? CGSize(width: size.0 ?? current.width, height: size.1 ?? current.height) : nil),
                to: window.handle)
        default:
            throw WindowManagementError.invalidOptions(#"bounds must be an object or "fullscreen""#)
        }
    }

    /// The two optional numbers of a `position` or `size`.
    private static func parts(of value: JSONValue?, named name: String, keys: (String, String)) throws -> (
        Double?, Double?
    ) {
        guard let value, value != .null else { return (nil, nil) }
        guard case .object(let object) = value else {
            throw WindowManagementError.invalidOptions("\(name) must be an object")
        }
        func number(_ key: String) throws -> Double? {
            guard let part = object[key], part != .null else { return nil }
            guard case .number(let number) = part, number.isFinite else {
                throw WindowManagementError.invalidOptions("\(name).\(key) must be a number")
            }
            return number
        }
        return (try number(keys.0), try number(keys.1))
    }

    /// What one call reads from the system, each app's windows asked for at most once. Internal, so Fudge's own
    /// window commands (`WindowManager.run`) find windows exactly as the API does.
    final class Reading {
        let manager: WindowManager
        let screens: [WindowScreen]
        /// The windows extensions see, front to back: on screen, ordinary (layer 0), visible, and a regular app's,
        /// never Fudge's own.
        private(set) var windows: [ListedWindow] = []
        private var applications: [Int32: JSONValue?] = [:]
        private var axWindows: [Int32: [AXWindow<System.Handle>]] = [:]
        /// For each app, its listed windows' numbers and the index of the AX window each is (`WindowMatch.pairs`).
        private var pairings: [Int32: [Int: Int]] = [:]

        init(_ manager: WindowManager) {
            self.manager = manager
            screens = manager.system.screens()
            windows = manager.system.listedWindows().filter {
                $0.layer == 0 && $0.alpha > 0 && $0.pid != manager.ownPid && application($0.pid) != nil
            }
        }

        func application(_ pid: Int32) -> JSONValue? {
            if let known = applications[pid] { return known }
            let found = manager.system.application(pid: pid)
            applications[pid] = found
            return found
        }

        func axWindows(_ pid: Int32) -> [AXWindow<System.Handle>] {
            if let known = axWindows[pid] { return known }
            let found = manager.system.axWindows(pid: pid)
            axWindows[pid] = found
            return found
        }

        /// The Accessibility API's window for `listed`, from its app's pairing.
        func ax(for listed: ListedWindow) -> AXWindow<System.Handle>? {
            pairing(listed.pid)[listed.number].map { axWindows(listed.pid)[$0] }
        }

        /// The app's listed windows paired one to one with its AX windows (`WindowMatch.pairs`), both front to back.
        /// Minimized AX windows take no part: the window list never has them.
        func pairing(_ pid: Int32) -> [Int: Int] {
            if let known = pairings[pid] { return known }
            let listed = windows.filter { $0.pid == pid }
            let candidates = axWindows(pid).map { (frame: $0.minimized ? nil : $0.frame, title: $0.title) }
            var found: [Int: Int] = [:]
            for (window, index) in zip(listed, WindowMatch.pairs(listed, among: candidates)) {
                if let index { found[window.number] = index }
            }
            pairings[pid] = found
            return found
        }

        /// The screen holding most of the window; the primary one when it's on none.
        func screen(of window: ListedWindow) -> WindowScreen? {
            PanelScreen.mostOf(window.bounds, on: screens.map(\.bounds)).map { screens[$0] } ?? screens.first
        }

        /// The frontmost app's focused window: the listed window paired with its focused AX window.
        func activeWindow() -> ListedWindow? {
            guard let pid = manager.system.frontmostPid(), pid != manager.ownPid,
                let focused = axWindows(pid).firstIndex(where: \.focused)
            else { return nil }
            let pairing = pairing(pid)
            return windows.first { $0.pid == pid && pairing[$0.number] == focused }
        }

        /// The desktop of the active window, or of the frontmost app's topmost window (`screen(of:)`, so a window
        /// on no screen is on the primary one, as its `desktopId` says), else the mouse's screen, else the primary one.
        func activeScreen() -> WindowScreen? {
            let pid = manager.system.frontmostPid()
            if let front = activeWindow() ?? windows.first(where: { $0.pid == pid }), let screen = screen(of: front) {
                return screen
            }
            let mouse = manager.system.mouseLocation()
            return screens.first { $0.bounds.contains(mouse) } ?? screens.first
        }

        /// Raycast's `Window` for `listed`.
        func json(_ listed: ListedWindow, active: Bool) -> JSONValue? {
            guard let application = application(listed.pid) else { return nil }
            let ax = ax(for: listed)
            let fullScreen = ax?.fullScreen ?? false
            let bounds: JSONValue =
                fullScreen
                ? .string("fullscreen")
                : .object([
                    "position": .object([
                        "x": .number(Double(listed.bounds.minX)), "y": .number(Double(listed.bounds.minY)),
                    ]),
                    "size": .object([
                        "width": .number(Double(listed.bounds.width)),
                        "height": .number(Double(listed.bounds.height)),
                    ]),
                ])
            return .object([
                "id": .string(String(listed.number)),
                "application": application,
                "bounds": bounds,
                "desktopId": screen(of: listed).map { .string($0.desktopId) } ?? .null,
                "positionable": .bool(ax?.positionSettable ?? false),
                "resizable": .bool(ax?.sizeSettable ?? false),
                "fullScreenSettable": .bool(ax?.fullScreenSettable ?? false),
                "active": .bool(active),
            ])
        }
    }
}

extension WindowManager: Sendable where System: Sendable {}

/// Which of an app's Accessibility windows is a window from the window list. The two APIs share no id, so it's one
/// in the same place at the same size, to within a point, with the same title when both have one. Without Screen
/// Recording the window list has no titles, and an app's windows of one size in one place (two browser windows
/// filling the screen) all match each other, so an app's windows are paired one to one, front to back in both lists.
public enum WindowMatch {
    /// For each of an app's `listed` windows (front to back), the index of its AX window among `candidates` (each an
    /// AX window's frame and title, front to back), or nil. No candidate is used twice. First each listed window with
    /// a title takes the first free candidate in its place with that title; then the others, front to back, take the
    /// first free candidate in their place. So the front window gets the front one, the next the next, and a window
    /// with tabs in its place gets the tab with its title, else the first.
    public static func pairs(_ listed: [ListedWindow], among candidates: [(frame: CGRect?, title: String?)]) -> [Int?] {
        var paired = [Int?](repeating: nil, count: listed.count)
        var taken = Set<Int>()
        func take(_ window: Int, where fits: (Int) -> Bool) {
            guard
                let index = candidates.indices.first(where: {
                    !taken.contains($0)
                        && matches(listed[window], frame: candidates[$0].frame, title: candidates[$0].title)
                        && fits($0)
                })
            else { return }
            paired[window] = index
            taken.insert(index)
        }
        for window in listed.indices {
            guard let title = listed[window].title, !title.isEmpty else { continue }
            take(window) { candidates[$0].title == title }
        }
        for window in listed.indices where paired[window] == nil {
            take(window) { _ in true }
        }
        return paired
    }

    /// Which of `candidates` is `listed`, when it's the app's only listed window.
    public static func index(of listed: ListedWindow, among candidates: [(frame: CGRect?, title: String?)]) -> Int? {
        pairs([listed], among: candidates)[0]
    }

    static func matches(_ listed: ListedWindow, frame: CGRect?, title: String?) -> Bool {
        guard let frame else { return false }
        let bounds = listed.bounds
        let close = [
            (frame.minX, bounds.minX), (frame.minY, bounds.minY), (frame.width, bounds.width),
            (frame.height, bounds.height),
        ].allSatisfy { abs($0.0 - $0.1) <= 1 }
        guard close else { return false }
        if let title, !title.isEmpty, let listedTitle = listed.title, !listedTitle.isEmpty {
            return title == listedTitle
        }
        return true
    }
}
