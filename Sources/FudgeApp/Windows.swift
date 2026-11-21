import AppKit
import ApplicationServices
import FudgeCore

// The system side of `WindowManagement`: the window list (`CGWindowListCopyWindowInfo`) and the Accessibility API.
// The logic is `WindowManager` in FudgeCore. Only public APIs; nothing here runs on the main thread except `current`,
// since the Accessibility API waits on other apps.

/// The windows, screens and Accessibility API, read off the main thread. What AppKit only answers on the main thread
/// (the frontmost app, the regular apps) is read there first, by `current()`.
struct SystemWindows: WindowSystem, Sendable {
    typealias Handle = AXUIElement

    /// How long an Accessibility call waits for a hung app, instead of the system's 6 s.
    static let timeout: Float = 2

    let frontmost: Int32?
    /// Raycast's `Application` for each regular app (one with a Dock icon), by pid.
    let applications: [Int32: JSONValue]
    /// Each screen's visible frame (no menu bar or Dock) in top-left coordinates, by display id, read with the rest
    /// on the main thread.
    let visibleFrames: [UInt32: CGRect]

    @MainActor
    static func current() -> SystemWindows {
        var applications: [Int32: JSONValue] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL {
                applications[app.processIdentifier] = ApplicationResolver.application(at: url)
            }
        }
        // `visibleFrame` is in Cocoa coordinates; flipped against the primary screen (`screens[0]`, at the origin),
        // never against the screen's own, it lines up with `CGDisplayBounds`.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var visibleFrames: [UInt32: CGRect] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                visibleFrames[number.uint32Value] = PanelScreen.topLeftFrame(
                    cocoa: screen.visibleFrame, primaryHeight: primaryHeight)
            }
        }
        return SystemWindows(
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, applications: applications,
            visibleFrames: visibleFrames)
    }

    func listedWindows() -> [ListedWindow] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: dictionary)
            else { return nil }
            return ListedWindow(
                number: number, pid: pid, layer: layer, bounds: bounds,
                title: entry[kCGWindowName as String] as? String,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    func screens() -> [WindowScreen] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).sorted { $0 == main && $1 != main }.map {
            WindowScreen(id: $0, bounds: CGDisplayBounds($0), visibleBounds: visibleFrames[$0])
        }
    }

    func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func frontmostPid() -> Int32? { frontmost }

    func application(pid: Int32) -> JSONValue? { applications[pid] }

    func axWindows(pid: Int32) -> [AXWindow<AXUIElement>] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        guard let windows = Self.value(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let focused = Self.value(app, kAXFocusedWindowAttribute)
        return windows.map { window in
            AXUIElementSetMessagingTimeout(window, Self.timeout)
            var frame: CGRect?
            if let position = Self.point(window), let size = Self.size(window) {
                frame = CGRect(origin: position, size: size)
            }
            return AXWindow(
                handle: window, frame: frame, title: Self.value(window, kAXTitleAttribute) as? String,
                positionSettable: Self.isSettable(window, kAXPositionAttribute),
                sizeSettable: Self.isSettable(window, kAXSizeAttribute),
                fullScreen: (Self.value(window, Self.fullScreen) as? Bool) ?? false,
                fullScreenSettable: Self.isSettable(window, Self.fullScreen),
                focused: focused.map { CFEqual($0, window) } ?? false,
                minimized: (Self.value(window, kAXMinimizedAttribute) as? Bool) ?? false)
        }
    }

    func apply(_ change: WindowChange, to window: AXUIElement) throws {
        switch change {
        case .fullScreen:
            try Self.set(window, Self.fullScreen, kCFBooleanTrue)
        case .exitFullScreen:
            try Self.set(window, Self.fullScreen, kCFBooleanFalse)
        case .frame(let position, let size):
            // Size first, so a window that's moving to a smaller place isn't pushed back by its old size; then again
            // after the move, which can change what size the app allows.
            if var size, let value = AXValueCreate(.cgSize, &size) { try Self.set(window, kAXSizeAttribute, value) }
            if var position, let value = AXValueCreate(.cgPoint, &position) {
                try Self.set(window, kAXPositionAttribute, value)
            }
            if position != nil, var size, let value = AXValueCreate(.cgSize, &size) {
                try Self.set(window, kAXSizeAttribute, value)
            }
        }
    }

    /// `AXFullScreen`, which the headers don't name.
    private static let fullScreen = "AXFullScreen"

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        guard let value = value(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = value(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard error == .success else {
            if error == .invalidUIElement { throw WindowManagementError.windowClosed }
            throw WindowManagementError.failed(
                "The window's app didn't accept the change (Accessibility error \(error.rawValue))")
        }
    }
}
