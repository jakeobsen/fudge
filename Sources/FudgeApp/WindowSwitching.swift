import AppKit
import ApplicationServices
import FudgeCore

// The system side of Switch Windows (FUD-120): the running apps, the window list and the Accessibility API. The logic
// is `WindowSwitcher` in FudgeCore. Public APIs only. Nothing here logs or stores a window's title.

/// What Switch Windows reads and does: the system's windows, or a snapshot run's made-up ones. `AppDelegate` gives
/// `LauncherModel` one.
@MainActor
protocol WindowSwitching: AnyObject {
    /// Whether the windows may be read: Accessibility, checked as for a call the user started.
    func mayRead() -> Bool
    /// Reads the windows, off the main thread.
    func read() async -> WindowListing
}

/// Until the app delegate sets one: no windows.
final class NoWindowSwitching: WindowSwitching {
    func mayRead() -> Bool { true }
    func read() async -> WindowListing { .empty }
}

/// The system's windows, through `SystemWindowSwitch`. It keeps which apps were active most recently, from the time
/// it's made, for the order of the apps with no window on screen.
@MainActor
final class SystemWindowSwitching: WindowSwitching {
    private let accessibility: () -> Bool
    private var recent = RecentApps()
    private let inFlight = WindowReadsInFlight()

    /// `accessibility` is the Accessibility check (`SystemCalls.mayReadWindows`).
    init(accessibility: @escaping () -> Bool) {
        self.accessibility = accessibility
        if let front = NSWorkspace.shared.frontmostApplication { recent.activated(front.processIdentifier) }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.recent.activated(pid) }
            }
        }
    }

    func mayRead() -> Bool { accessibility() }

    func read() async -> WindowListing {
        let switcher = WindowSwitcher(
            system: SystemWindowSwitch.current(recent: recent.pids), ownPid: ProcessInfo.processInfo.processIdentifier,
            inFlight: inFlight)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: switcher.listing()) }
        }
    }
}

/// Snapshot runs' windows: made up, from `--windows <file>` (`FixedWindowSystem`), so a snapshot never reads the
/// window list or the Accessibility API, and nothing it shows is the user's. Without the flag, Switch Windows shows
/// that it needs Accessibility.
@MainActor
final class FixedWindowSwitching: WindowSwitching {
    private let file: URL?

    init(file: URL?) {
        self.file = file
    }

    func mayRead() -> Bool { file != nil }

    func read() async -> WindowListing {
        guard let file else { return .empty }
        let switcher = WindowSwitcher(
            system: FixedWindowSystem.load(from: file), ownPid: ProcessInfo.processInfo.processIdentifier,
            inFlight: WindowReadsInFlight())
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: switcher.listing()) }
        }
    }
}

/// The running apps, the window list and the Accessibility API, for one read. What AppKit answers on the main thread
/// (the apps, the frontmost one, the screens' names) is read there first, by `current`; the rest runs off it.
struct SystemWindowSwitch: WindowSwitchSystem {
    typealias Handle = AXUIElement

    let appList: [SwitcherApp]
    let recent: [Int32]
    let frontmost: Int32?
    let screenList: [NamedScreen]

    @MainActor
    static func current(recent: [Int32]) -> SystemWindowSwitch {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }.map { app in
            SwitcherApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                // Safari's bundle in /Applications is a link, whose icon would carry the alias arrow.
                path: app.bundleURL?.resolvingSymlinksInPath().path)
        }
        let screens = NSScreen.screens.compactMap { screen -> NamedScreen? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return NamedScreen(name: screen.localizedName, bounds: CGDisplayBounds(number.uint32Value))
        }
        return SystemWindowSwitch(
            appList: apps, recent: recent, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            screenList: screens)
    }

    func apps() -> [SwitcherApp] { appList }
    func recentlyActive() -> [Int32] { recent }
    func frontmostPid() -> Int32? { frontmost }
    func listedWindows() -> [ListedWindow] { SystemWindows.onScreenWindows() }
    func screens() -> [NamedScreen] { screenList }

    /// What one window's read asks for, in one call (`AXUIElementCopyMultipleAttributeValues`).
    private static let attributes = [
        kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXSubroleAttribute,
    ]

    /// The app's windows. `kAXErrorCannotComplete` is the Accessibility API's timeout (`SystemWindows.timeout`): the
    /// app didn't answer.
    func windows(of pid: Int32) -> AppWindowsRead<AXUIElement> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, SystemWindows.timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete { return .noAnswer }
        guard error == .success, let windows = value as? [AXUIElement] else { return .answered([]) }
        var focusedValue: CFTypeRef?
        let focused =
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success
            ? focusedValue : nil
        var read: [SwitchableWindow<AXUIElement>] = []
        for window in windows {
            AXUIElementSetMessagingTimeout(window, SystemWindows.timeout)
            var values: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                window, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            if result == .cannotComplete { return .noAnswer }
            guard result == .success, let list = values as? [AnyObject], list.count == Self.attributes.count else {
                continue
            }
            var frame: CGRect?
            if let position = Self.point(list[1]), let size = Self.size(list[2]) {
                frame = CGRect(origin: position, size: size)
            }
            read.append(
                SwitchableWindow(
                    handle: window, title: list[0] as? String, frame: frame, minimized: (list[3] as? Bool) ?? false,
                    standard: (list[4] as? String) == kAXStandardWindowSubrole,
                    focused: focused.map { CFEqual($0, window) } ?? false))
        }
        return .answered(read)
    }

    func unminimize(_ window: AXUIElement) throws {
        try Self.check(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse))
    }

    func raise(_ window: AXUIElement) throws {
        try Self.check(AXUIElementPerformAction(window, kAXRaiseAction as CFString))
        // Its app's main window too, so it's the one that has the keyboard once the app is active.
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Unhides the app if it's hidden and activates it; then asks the Accessibility API to make it frontmost as well,
    /// in case the system declined the activation of an app by one that isn't active.
    func activate(pid: Int32) throws {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw WindowManagementError.failed("The app has quit.")
        }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, SystemWindows.timeout)
        _ = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    func close(_ window: AXUIElement) throws {
        var button: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
        if error == .invalidUIElement { throw WindowManagementError.windowClosed }
        guard error == .success, let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            throw WindowManagementError.failed("This window has no close button.")
        }
        // The button is a new element, so it gets the same timeout as the reads: a hung app holds it 2 s, not 6.
        let close = button as! AXUIElement
        AXUIElementSetMessagingTimeout(close, SystemWindows.timeout)
        try Self.check(AXUIElementPerformAction(close, kAXPressAction as CFString))
    }

    func terminate(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    func sameWindow(_ one: AXUIElement, _ other: AXUIElement) -> Bool {
        CFEqual(one, other)
    }

    private static func check(_ error: AXError) throws {
        guard error == .success else {
            if error == .invalidUIElement { throw WindowManagementError.windowClosed }
            throw WindowManagementError.failed(
                "The window's app didn't accept it (Accessibility error \(error.rawValue)).")
        }
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
