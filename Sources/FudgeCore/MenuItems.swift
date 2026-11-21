import Foundation

// Search Menu Items (FUD-121): the menu bar of the app the user was in, read through the Accessibility API, to search
// and run its items. The logic lives here; the app reads the system behind `MenuSystem`, and tests and snapshot runs
// supply made-up menus (`FixedMenuSystem`). Menu titles can name documents (Window › <document>, Open Recent), so
// nothing here logs or writes them: a read lives in memory, and its rows are known by their place in it, never by
// anything taken from a menu.

/// The app whose menus are searched: the one that was frontmost when Search Menu Items opened, never Fudge.
public struct MenuTarget: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    /// Its bundle, whose icon the rows show.
    public var path: String?

    public init(pid: Int32, bundleID: String? = nil, name: String, path: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }

    /// What its menus are cached by (`MenuItemsCache`): its bundle id, else its pid.
    public var cacheKey: String { bundleID ?? "pid:\(pid)" }

    /// The app to search: the frontmost one, unless that's Fudge itself (`ownPid`), whose menus are never searched.
    public static func searched(frontmost: MenuTarget?, ownPid: Int32) -> MenuTarget? {
        guard let frontmost, frontmost.pid != ownPid else { return nil }
        return frontmost
    }
}

/// A menu item's keyboard shortcut, as the Accessibility API gives it: `kAXMenuItemCmdChar`, `CmdModifiers`,
/// `CmdGlyph` and `CmdVirtualKey`.
public struct MenuShortcut: Sendable, Equatable {
    public var character: String?
    /// `kAXMenuItemModifier…` bits. ⌘ is implied unless `noCommand` is set.
    public var modifiers: Int
    /// One of the Menu Manager's glyphs (`kMenu…Glyph`), for keys with no character of their own.
    public var glyph: Int?
    public var virtualKey: Int?

    public static let shift = 1
    public static let option = 2
    public static let control = 4
    public static let noCommand = 8

    public init(character: String? = nil, modifiers: Int = 0, glyph: Int? = nil, virtualKey: Int? = nil) {
        self.character = character
        self.modifiers = modifiers
        self.glyph = glyph
        self.virtualKey = virtualKey
    }

    /// Its keycaps, as a menu shows them: ⌃ ⌥ ⇧ ⌘, then the key. Empty when there's no key to show.
    public var keycaps: [String] {
        guard let key else { return [] }
        var caps: [String] = []
        if modifiers & Self.control != 0 { caps.append("⌃") }
        if modifiers & Self.option != 0 { caps.append("⌥") }
        if modifiers & Self.shift != 0 { caps.append("⇧") }
        if modifiers & Self.noCommand == 0 { caps.append("⌘") }
        return caps + [key]
    }

    /// The key: the glyph's symbol, else the character (a letter in upper case, a function key's private-use
    /// character by its name), else the virtual key's name.
    var key: String? {
        if let glyph, glyph != 0, let symbol = Self.glyphs[glyph] { return symbol }
        if let character, let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
            if let name = Self.functionKeys[scalar.value] { return name }
            if scalar.value >= 0x21, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) {
                return character.uppercased()
            }
            if scalar.value == 0x20 { return "Space" }
        }
        if let virtualKey, let name = Self.virtualKeys[virtualKey] { return name }
        return nil
    }

    /// The Menu Manager's glyphs (`Menus.h`) for keys a menu draws as a symbol or a name.
    static let glyphs: [Int: String] = {
        var glyphs: [Int: String] = [
            0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x05: "⇧", 0x06: "⌃", 0x07: "⌥", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩",
            0x0C: "↩", 0x0D: "↩", 0x10: "⇣", 0x11: "⌘", 0x17: "⌫", 0x18: "⇠", 0x19: "⇡", 0x1A: "⇢", 0x1B: "⎋",
            0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖", 0x67: "Help", 0x68: "↑", 0x69: "↘",
            0x6A: "↓", 0x6B: "⇟", 0x6E: "⌽", 0x8A: "⌃", 0x8C: "⏏",
        ]
        for number in 1...12 { glyphs[0x6E + number] = "F\(number)" }
        for number in 13...15 { glyphs[0x87 + number - 13] = "F\(number)" }
        for number in 16...19 { glyphs[0x8F + number - 16] = "F\(number)" }
        return glyphs
    }()

    /// AppKit's private-use characters for function keys (`NSUpArrowFunctionKey`…), which a key equivalent may be.
    static let functionKeys: [UInt32: String] = {
        var keys: [UInt32: String] = [
            0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞",
            0xF72D: "⇟",
        ]
        for number in 1...19 { keys[0xF703 + UInt32(number)] = "F\(number)" }
        return keys
    }()

    /// Virtual key codes (`kVK_…`) for keys with no character, when a menu gives only that.
    static let virtualKeys: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦", 0x73: "↖", 0x77: "↘", 0x74: "⇞",
        0x79: "⇟", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19",
    ]
}

/// One element of an app's menus as the Accessibility API gives it, read in one call: a menu bar item (File), a
/// menu (the list under it), or a menu item, whose children are its submenu.
public struct MenuNode<Handle> {
    public enum Role: Sendable, Equatable {
        /// `kAXMenuRole`: the list of items under a menu bar item or a submenu's item.
        case menu
        /// `kAXMenuBarItemRole` or `kAXMenuItemRole`.
        case item
        case other
    }

    public var role: Role
    public var title: String
    /// Whether the item is turned on; nil when the app didn't say (it didn't answer for that attribute in time), which
    /// the list shows, and a press takes as no answer.
    public var enabled: Bool?
    public var children: [Handle]
    public var shortcut: MenuShortcut?

    public init(
        role: Role, title: String, enabled: Bool? = true, children: [Handle] = [], shortcut: MenuShortcut? = nil
    ) {
        self.role = role
        self.title = title
        self.enabled = enabled
        self.children = children
        self.shortcut = shortcut
    }
}

/// What asking an app about one of its elements gave.
public enum MenuAnswer<Value> {
    case answered(Value)
    /// The element is gone: the app rebuilt its menus, or quit.
    case gone
    /// The app didn't answer within the Accessibility API's timeout.
    case noAnswer
}

/// What finding a menu item again gave (`MenuReader.current`).
public enum MenuLookup<Handle> {
    case ready(Handle)
    /// It's there, but turned off now.
    case disabled
    case gone
    case noAnswer
}

/// The place of each item among the items with the same path and title, and how many there are: what
/// `MenuReader.current` tells alike items apart by.
public func menuItemPlaces<Handle>(_ items: [FoundMenuItem<Handle>]) -> [(place: Int, count: Int)] {
    var counts: [[String]: Int] = [:]
    var places: [Int] = []
    for item in items {
        let key = item.path + [item.title]
        places.append(counts[key, default: 0])
        counts[key, default: 0] += 1
    }
    return zip(items, places).map { item, place in (place, counts[item.path + [item.title]]!) }
}

/// What pressing a menu item gave.
public enum MenuPress: Sendable, Equatable {
    case pressed
    /// The item is gone (`kAXErrorInvalidUIElement`).
    case gone
    /// The app didn't answer in time. It may still be doing it: an item that opens a dialog can hold the answer back.
    case noAnswer
    /// The app refused.
    case failed
}

/// An app's menus, as Search Menu Items reads and presses them. The app's reads the Accessibility API, whose calls
/// wait on the other app, so `MenuReader` calls it off the main thread.
public protocol MenuSystem: Sendable {
    associatedtype Handle
    /// The items of the app's menu bar (`kAXMenuBarAttribute`'s children), the Apple menu first.
    func menuBar(of pid: Int32) -> MenuAnswer<[Handle]>
    /// One element's role, title, enabled state, children and shortcut.
    func node(_ element: Handle) -> MenuAnswer<MenuNode<Handle>>
    /// Performs `kAXPressAction` on a menu item.
    func press(_ element: Handle) -> MenuPress
}

/// A menu item a read found: a leaf, enabled, with a title.
public struct FoundMenuItem<Handle> {
    public var handle: Handle
    public var title: String
    /// The titles of the menus above it, as the app gives them, the menu bar's first.
    public var path: [String]
    /// Whether it's in the app's own menu (the menu bar's second item), which the list names by the app's name.
    public var inAppMenu: Bool
    public var shortcut: MenuShortcut?
}

/// What reading an app's menus gave.
public enum MenuReadResult<Handle> {
    /// The items in menu order. `complete` is false when the read stopped at its deadline or an element didn't
    /// answer, so some may be missing.
    case items([FoundMenuItem<Handle>], complete: Bool)
    /// The app's menu bar didn't answer.
    case noAnswer
}

/// The apps whose menus are being read, across reads. An app that's still being read isn't asked again until that
/// read ends, so a hung app holds one thread at most.
public final class MenuReadsInFlight: @unchecked Sendable {
    private let condition = NSCondition()
    /// Each app being read, and whether its read was cancelled (its list went).
    private var reads: [Int32: Bool] = [:]

    public init() {}

    /// Marks `pid` as being read; false when it already is. A read that was cancelled ends at its next step, so a new
    /// one waits up to `wait` for it; one still running (a hung app) is never waited for.
    func start(_ pid: Int32, waitingForCancelledUpTo wait: Duration = .zero) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Double(wait / .milliseconds(1)) / 1000)
        while reads[pid] == true, condition.wait(until: deadline) {}
        guard reads[pid] == nil else { return false }
        reads[pid] = false
        return true
    }

    func cancel(_ pid: Int32) {
        condition.lock()
        if reads[pid] != nil { reads[pid] = true }
        condition.unlock()
    }

    func end(_ pid: Int32) {
        condition.lock()
        reads[pid] = nil
        condition.broadcast()
        condition.unlock()
    }
}

/// Cancels a read whose list went (`MenuItemsSource.read`), so it stops at its next step and the app's next read
/// needn't wait on it. Cancelling before the read starts cancels it as soon as it does.
public final class MenuReadCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    public init() {}

    public func cancel() {
        let run: (() -> Void)? = lock.withLock {
            cancelled = true
            defer { action = nil }
            return action
        }
        run?()
    }

    func onCancel(_ run: @escaping () -> Void) {
        let now = lock.withLock {
            if cancelled { return true }
            action = run
            return false
        }
        if now { run() }
    }
}

/// A read running on a thread of its own, which collects items as it finds them, in menu order, so what it found by
/// its deadline can be listed.
public final class MenuWalk<Handle>: @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var items: [FoundMenuItem<Handle>] = []
    private var answered = false
    private var complete = true
    private var stopped = false
    private var done = false

    init() {}

    /// A read that ended before it started: the app is still being read from an earlier one.
    static func noAnswer() -> MenuWalk {
        let walk = MenuWalk()
        walk.end(answered: false)
        return walk
    }

    /// Waits up to `within` for the read to end, then stops it, and gives what it found by then.
    public func finish(within: Duration) -> MenuReadResult<Handle> {
        let milliseconds = max(0, Int(within / .milliseconds(1)))
        if ended.wait(timeout: .now() + .milliseconds(milliseconds)) == .success { ended.signal() }
        return lock.withLock {
            stopped = true
            guard answered else { return .noAnswer }
            return .items(items, complete: done && complete)
        }
    }

    /// Stops the read at its next step, keeping what it found, and lets `finish` return at once.
    public func cancel() {
        lock.withLock { stopped = true }
        ended.signal()
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func menuBarAnswered() { lock.withLock { answered = true } }

    /// Adds an item; false once the read should stop.
    func add(_ item: FoundMenuItem<Handle>, limit: Int) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            items.append(item)
            if items.count >= limit {
                complete = false
                return false
            }
            return true
        }
    }

    func missed() { lock.withLock { complete = false } }

    func end(answered: Bool) {
        lock.withLock {
            if answered { self.answered = true }
            done = true
        }
        ended.signal()
    }
}

/// Reads an app's menus and finds an item again, over a `MenuSystem`.
public struct MenuReader<System: MenuSystem>: Sendable {
    public let system: System
    /// Shared by every read of the run.
    public let inFlight: MenuReadsInFlight

    /// At most this many items are read; an app with more lists the first ones.
    public static var itemLimit: Int { 5_000 }
    /// Submenus deeper than this aren't read.
    public static var depthLimit: Int { 8 }

    public init(system: System, inFlight: MenuReadsInFlight = MenuReadsInFlight()) {
        self.system = system
        self.inFlight = inFlight
    }

    /// Starts reading `pid`'s menus on a thread of its own: every enabled leaf item with a title, in menu order, but
    /// none of the Apple menu's (the menu bar's first item). An item with a submenu isn't one itself: its submenu's
    /// items are. A disabled item, or one without a title (a separator), is left out with what's under it. Call
    /// `finish(within:)` for the result.
    public func start(
        _ pid: Int32, cancel: MenuReadCancel = MenuReadCancel(), waitingForCancelledUpTo wait: Duration = .zero
    ) -> MenuWalk<System.Handle> {
        guard inFlight.start(pid, waitingForCancelledUpTo: wait) else { return .noAnswer() }
        let walk = MenuWalk<System.Handle>()
        cancel.onCancel { [inFlight] in
            inFlight.cancel(pid)
            walk.cancel()
        }
        let thread = Thread { [system, inFlight] in
            Self.walk(pid, system: system, into: walk)
            inFlight.end(pid)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        return walk
    }

    private static func walk(_ pid: Int32, system: System, into walk: MenuWalk<System.Handle>) {
        guard case .answered(let bar) = system.menuBar(of: pid) else {
            walk.end(answered: false)
            return
        }
        walk.menuBarAnswered()
        for (index, item) in bar.enumerated().dropFirst() {
            guard !walk.isStopped else { break }
            guard case .answered(let node) = system.node(item) else {
                walk.missed()
                continue
            }
            guard node.enabled != false, let title = Self.title(node) else { continue }
            let top = Top(path: [title], inAppMenu: index == 1)
            guard read(below: node, top: top, depth: 1, system: system, into: walk) else { break }
        }
        walk.end(answered: true)
    }

    /// Where a read is: the titles above it, and whether that's under the app's own menu.
    private struct Top {
        var path: [String]
        var inAppMenu: Bool
    }

    /// Reads the items in `parent`'s submenu, and theirs; false once the read should stop.
    private static func read(
        below parent: MenuNode<System.Handle>, top: Top, depth: Int, system: System,
        into walk: MenuWalk<System.Handle>
    ) -> Bool {
        for child in parent.children {
            guard !walk.isStopped else { return false }
            guard case .answered(let menu) = system.node(child) else {
                walk.missed()
                continue
            }
            guard menu.role == .menu else { continue }
            for entry in menu.children {
                guard !walk.isStopped else { return false }
                guard case .answered(let item) = system.node(entry) else {
                    walk.missed()
                    continue
                }
                guard item.role == .item, item.enabled != false, let title = Self.title(item) else { continue }
                if item.children.isEmpty {
                    let found = FoundMenuItem(
                        handle: entry, title: title, path: top.path, inAppMenu: top.inAppMenu, shortcut: item.shortcut)
                    guard walk.add(found, limit: itemLimit) else { return false }
                } else if depth < depthLimit {
                    let below = Top(path: top.path + [title], inAppMenu: top.inAppMenu)
                    guard read(below: item, top: below, depth: depth + 1, system: system, into: walk) else {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// A node's title, trimmed; nil for none (a separator, or an item drawn without one).
    private static func title(_ node: MenuNode<System.Handle>) -> String? {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : node.title
    }

    /// The item `item` names, now: the element read, if it still answers as an item with that title; else the item
    /// found again in `pid` by its whole path and title (`locate`), as the `place`th of the `count` items the read
    /// saw with that path and title. The app may have rebuilt its menus since, or been started again with another
    /// pid. An item that's turned off now is `.disabled`, and one whose state the app didn't give is `.noAnswer`:
    /// neither is pressed. Blocks.
    public func current(_ item: FoundMenuItem<System.Handle>, place: Int = 0, count: Int = 1, in pid: Int32)
        -> MenuLookup<System.Handle>
    {
        switch system.node(item.handle) {
        case .answered(let node) where node.role == .item && node.title == item.title && node.children.isEmpty:
            return Self.lookup(item.handle, enabled: node.enabled)
        case .noAnswer:
            return .noAnswer
        default:
            return locate(path: item.path, title: item.title, place: place, count: count, in: pid)
        }
    }

    /// Finds the leaf item titled `title` under the menus titled `path`, walking down from the menu bar, every title
    /// matching exactly, as the `place`th of the items found so (menus with the same title are each searched). Items
    /// alike are told apart only by their place, so when the number found isn't `count`, the number the read saw (one
    /// of two alike windows closed, say), the item is `.gone`, never pressed by a place that now means another. Any
    /// menu that doesn't answer makes it `.noAnswer`, since the number can't be known.
    public func locate(path: [String], title: String, place: Int = 0, count: Int = 1, in pid: Int32)
        -> MenuLookup<System.Handle>
    {
        guard let first = path.first else { return .gone }
        guard case .answered(let bar) = system.menuBar(of: pid) else { return .noAnswer }
        var matches: [(handle: System.Handle, enabled: Bool?)] = []
        var silent = false
        for item in bar.dropFirst() {
            switch system.node(item) {
            case .answered(let node) where node.title == first:
                if !collect(Array(path.dropFirst()), title: title, below: node, into: &matches) { silent = true }
            case .noAnswer: silent = true
            default: continue
            }
        }
        if silent { return .noAnswer }
        guard matches.count == count, matches.indices.contains(place) else { return .gone }
        return Self.lookup(matches[place].handle, enabled: matches[place].enabled)
    }

    /// Ready only when the app says the item is on now.
    private static func lookup(_ handle: System.Handle, enabled: Bool?) -> MenuLookup<System.Handle> {
        switch enabled {
        case true: .ready(handle)
        case false: .disabled
        case nil: .noAnswer
        }
    }

    /// Adds every leaf titled `title` under `path` below `parent`, in menu order; false when some menu didn't answer.
    private func collect(
        _ path: [String], title: String, below parent: MenuNode<System.Handle>,
        into matches: inout [(handle: System.Handle, enabled: Bool?)]
    ) -> Bool {
        var answered = true
        for child in parent.children {
            guard case .answered(let menu) = system.node(child) else {
                answered = false
                continue
            }
            guard menu.role == .menu else { continue }
            for entry in menu.children {
                switch system.node(entry) {
                case .answered(let item) where item.role == .item:
                    if path.isEmpty {
                        if item.title == title, item.children.isEmpty { matches.append((entry, item.enabled)) }
                    } else if item.title == path[0], !item.children.isEmpty {
                        if !collect(Array(path.dropFirst()), title: title, below: item, into: &matches) {
                            answered = false
                        }
                    }
                case .noAnswer: answered = false
                default: continue
                }
            }
        }
        return answered
    }
}

/// The menus last read for each app, by `MenuTarget.cacheKey`, in memory for the run and never written anywhere,
/// since menu titles can name documents. Search Menu Items shows an app's at once and reads them again meanwhile. It
/// holds the `limit` most recently read apps.
public struct MenuItemsCache<Value> {
    public static var limit: Int { 8 }
    private var entries: [(key: String, value: Value)] = []

    public init() {}

    public func value(for key: String) -> Value? {
        entries.first { $0.key == key }?.value
    }

    public mutating func set(_ value: Value, for key: String) {
        entries.removeAll { $0.key == key }
        entries.insert((key, value), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public var keys: [String] { entries.map(\.key) }
}
