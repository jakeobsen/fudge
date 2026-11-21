import AppKit
import ApplicationServices
import FudgeCore

// The system side of Search Menu Items: an app's menus through the Accessibility API. The logic is `MenuReader` and
// `MenuItemsSearch` in FudgeCore. Only public APIs; nothing here that waits on the other app runs on the main thread.

/// What Search Menu Items reads and does, for the launcher: the system's menus, or a snapshot run's made-up ones
/// (`--menu-items`). The app delegate sets it.
@MainActor
protocol MenuItemsAccess {
    /// The app the user was in: the frontmost one, which the panel never takes over. Nil when that's Fudge itself.
    func target() -> MenuTarget?
    /// Whether Fudge may read other apps' menus, checked as for a call the user started: macOS's prompt at the first
    /// refusal in a run, and Fudge's offer at the next.
    func mayRead() -> Bool
    var source: any MenuItemsSource { get }
    /// Makes `target` the active app, if it isn't.
    func activate(_ target: MenuTarget) async
}

/// Before the app delegate sets one: no app, so nothing is read.
struct NoMenuItemsAccess: MenuItemsAccess {
    func target() -> MenuTarget? { nil }
    func mayRead() -> Bool { false }
    var source: any MenuItemsSource { MenuItemsSearch(reader: MenuReader(system: FixedMenuSystem(menus: []))) }
    func activate(_ target: MenuTarget) async {}
}

/// The system's menus.
struct SystemMenuItemsAccess: MenuItemsAccess {
    let mayReadMenus: () -> Bool
    let source: any MenuItemsSource = MenuItemsSearch(reader: MenuReader(system: SystemMenus()))

    func target() -> MenuTarget? {
        let frontmost = NSWorkspace.shared.frontmostApplication.map { app in
            MenuTarget(
                pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "The app",
                path: app.bundleURL?.path)
        }
        return MenuTarget.searched(frontmost: frontmost, ownPid: ProcessInfo.processInfo.processIdentifier)
    }

    func mayRead() -> Bool { mayReadMenus() }

    func activate(_ target: MenuTarget) async {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isActive else { return }
        app.activate()
        // `activate()` may be declined while Fudge isn't the active app; the app's own Accessibility element can
        // still be made frontmost.
        let pid = target.pid
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, SystemWindows.timeout)
                AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                continuation.resume()
            }
        }
    }
}

/// A snapshot run's made-up app and menus. Nothing is pressed for real: `FixedMenuSystem` only records it.
struct FixedMenuItemsAccess: MenuItemsAccess {
    let file: FixedMenuFile?
    let source: any MenuItemsSource

    init(file: URL?) {
        self.file = file.flatMap(FixedMenuFile.load)
        source = MenuItemsSearch(reader: MenuReader(system: FixedMenuSystem(menus: self.file?.menus ?? [])))
    }

    /// Without `--menu-items` there's no app, and the list says so: snapshots never read a real app's menus.
    func target() -> MenuTarget? { file?.target }
    func mayRead() -> Bool { file != nil }
    func activate(_ target: MenuTarget) async {}
}

/// An app's menus through the Accessibility API, each call waiting at most `SystemWindows.timeout` for the app.
struct SystemMenus: MenuSystem, Sendable {
    typealias Handle = AXUIElement

    func menuBar(of pid: Int32) -> MenuAnswer<[AXUIElement]> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, SystemWindows.timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value)
        switch error {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .answered([]) }
            let bar = value as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, SystemWindows.timeout)
            var children: CFTypeRef?
            let childrenError = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children)
            guard childrenError == .success else { return Self.failure(childrenError) }
            return .answered(children as? [AXUIElement] ?? [])
        case .noValue, .attributeUnsupported:
            // An app with no menu bar of its own.
            return .answered([])
        default:
            return Self.failure(error)
        }
    }

    /// The attributes `node` reads, in one call, in this order.
    private static let attributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdVirtualKeyAttribute,
    ]

    func node(_ element: AXUIElement) -> MenuAnswer<MenuNode<AXUIElement>> {
        AXUIElementSetMessagingTimeout(element, SystemWindows.timeout)
        var result: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, [], &result)
        guard error == .success, let values = result as? [AnyObject], values.count == 8 else {
            return Self.failure(error == .success ? .failure : error)
        }
        // A value the element doesn't have comes back as an AXValue holding the error.
        func value(_ index: Int) -> AnyObject? {
            let value = values[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        let role: MenuNode<AXUIElement>.Role =
            switch value(0) as? String {
            case kAXMenuRole: .menu
            case kAXMenuItemRole, kAXMenuBarItemRole: .item
            default: .other
            }
        // An item without AXEnabled is on, as the list shows it; one whose AXEnabled the app couldn't give (it timed out,
        // say) is unknown, so a press doesn't take it as on.
        var enabled: Bool? = (value(2) as? NSNumber)?.boolValue
        if enabled == nil, let error = Self.error(values[2]), error == .attributeUnsupported || error == .noValue {
            enabled = true
        }
        let character = (value(4) as? String).flatMap { $0.isEmpty ? nil : $0 }
        let glyph = (value(6) as? NSNumber)?.intValue
        let virtualKey = (value(7) as? NSNumber)?.intValue
        var shortcut: MenuShortcut?
        if character != nil || (glyph ?? 0) != 0 || virtualKey != nil {
            shortcut = MenuShortcut(
                character: character, modifiers: (value(5) as? NSNumber)?.intValue ?? 0, glyph: glyph,
                virtualKey: virtualKey)
        }
        return .answered(
            MenuNode(
                role: role, title: value(1) as? String ?? "", enabled: enabled,
                children: value(3) as? [AXUIElement] ?? [], shortcut: shortcut))
    }

    func press(_ element: AXUIElement) -> MenuPress {
        AXUIElementSetMessagingTimeout(element, SystemWindows.timeout)
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success: return .pressed
        case .invalidUIElement: return .gone
        case .cannotComplete: return .noAnswer
        default: return .failed
        }
    }

    /// The error an attribute's value holds, when `AXUIElementCopyMultipleAttributeValues` couldn't read it.
    private static func error(_ value: AnyObject) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var error = AXError.success
        guard AXValueGetType(value as! AXValue) == .axError, AXValueGetValue(value as! AXValue, .axError, &error)
        else { return nil }
        return error
    }

    /// An error as an answer: the element is gone, or the app didn't answer (in time, or at all).
    private static func failure<Value>(_ error: AXError) -> MenuAnswer<Value> {
        error == .invalidUIElement ? .gone : .noAnswer
    }
}
