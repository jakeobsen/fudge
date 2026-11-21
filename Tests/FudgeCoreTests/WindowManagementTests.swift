import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

// WindowManagement (FUD-93). A fake window list and Accessibility API: these tests never read or move real windows.

private final class FakeWindows: WindowSystem {
    typealias Handle = Int

    var listed: [ListedWindow] = []
    var screenList = [
        WindowScreen(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        WindowScreen(id: 2, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
    ]
    var mouse = CGPoint(x: 100, y: 100)
    var frontmost: Int32? = textEdit
    var apps: [Int32: JSONValue] = [textEdit: appJSON("TextEdit"), safari: appJSON("Safari")]
    var ax: [Int32: [AXWindow<Int>]] = [:]
    var refusal: String?
    private(set) var applied: [String] = []

    func listedWindows() -> [ListedWindow] { listed }
    func screens() -> [WindowScreen] { screenList }
    func mouseLocation() -> CGPoint { mouse }
    func frontmostPid() -> Int32? { frontmost }
    func application(pid: Int32) -> JSONValue? { apps[pid] }
    func axWindows(pid: Int32) -> [AXWindow<Int>] { ax[pid] ?? [] }

    func apply(_ change: WindowChange, to window: Int) throws {
        if let refusal { throw WindowManagementError.failed(refusal) }
        switch change {
        case .fullScreen:
            applied.append("\(window) full screen")
        case .frame(let position, let size):
            let at = position.map { "at \(Int($0.x)),\(Int($0.y))" }
            let sized = size.map { "size \(Int($0.width))x\(Int($0.height))" }
            applied.append(([String(window)] + [at, sized].compactMap { $0 }).joined(separator: " "))
        }
    }
}

private let me: Int32 = 100
private let textEdit: Int32 = 200
private let safari: Int32 = 300
/// An app with no Dock icon, such as a helper: its windows aren't listed.
private let helper: Int32 = 400

private func appJSON(_ name: String) -> JSONValue {
    .object(["name": .string(name), "path": .string("/Applications/\(name).app")])
}

private let editor = CGRect(x: 100, y: 80, width: 800, height: 600)
private let browser = CGRect(x: 1600, y: 50, width: 1200, height: 900)
private let docs = CGRect(x: 200, y: 300, width: 600, height: 400)

/// TextEdit's focused window on the first screen; behind it Safari's two, one on the second screen and one on the
/// first; and some windows that aren't listed: a menu bar extra, an invisible one, Fudge's own and a helper's.
private func desk() -> FakeWindows {
    let system = FakeWindows()
    system.listed = [
        ListedWindow(number: 5, pid: textEdit, layer: 25, bounds: CGRect(x: 1300, y: 0, width: 30, height: 24)),
        ListedWindow(number: 11, pid: textEdit, bounds: editor, title: "Notes.txt"),
        ListedWindow(number: 6, pid: textEdit, bounds: editor, alpha: 0),
        ListedWindow(number: 7, pid: me, bounds: CGRect(x: 400, y: 200, width: 750, height: 475)),
        ListedWindow(number: 8, pid: helper, bounds: CGRect(x: 10, y: 10, width: 300, height: 200)),
        ListedWindow(number: 12, pid: safari, bounds: browser),
        ListedWindow(number: 13, pid: safari, bounds: docs),
    ]
    system.ax = [
        textEdit: [AXWindow(handle: 1, frame: editor, title: "Notes.txt", focused: true)],
        safari: [
            AXWindow(handle: 2, frame: browser, title: "Start Page", sizeSettable: false, fullScreenSettable: false),
            AXWindow(handle: 3, frame: docs, title: "Docs"),
        ],
    ]
    return system
}

private func manager(_ system: FakeWindows) -> WindowManager<FakeWindows> {
    WindowManager(system: system, ownPid: me)
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func field(_ value: JSONValue, _ key: String) -> JSONValue? {
    if case .object(let object) = value { return object[key] }
    return nil
}

// MARK: - Windows

@Test func windowsAreTheVisibleOrdinaryWindowsOfRegularAppsFrontToBack() throws {
    let system = desk()
    let windows = manager(system).windowsOnActiveDesktop()
    #expect(windows.map { field($0, "id") } == [.string("11"), .string("13")])
    #expect(
        windows[0]
            == .object([
                "id": .string("11"),
                "application": appJSON("TextEdit"),
                "bounds": .object([
                    "position": .object(["x": .number(100), "y": .number(80)]),
                    "size": .object(["width": .number(800), "height": .number(600)]),
                ]),
                "desktopId": .string("screen-1"),
                "positionable": .bool(true),
                "resizable": .bool(true),
                "fullScreenSettable": .bool(true),
                "active": .bool(true),
            ]))
    #expect(field(windows[1], "desktopId") == .string("screen-1"))
    #expect(field(windows[1], "active") == .bool(false))

    system.frontmost = safari
    let safariWindows = manager(system).windowsOnActiveDesktop()
    #expect(safariWindows.map { field($0, "id") } == [.string("12")])
    #expect(field(safariWindows[0], "desktopId") == .string("screen-2"), "the screen holding most of it")
    #expect(field(safariWindows[0], "resizable") == .bool(false))
    #expect(field(safariWindows[0], "fullScreenSettable") == .bool(false))
}

@Test func onlyTheActiveDesktopsWindowsAreOnIt() {
    // Two screens, each its own desktop: the active one is the screen with the frontmost app's topmost window.
    let system = desk()
    func ids() -> [JSONValue?] { manager(system).windowsOnActiveDesktop().map { field($0, "id") } }
    #expect(ids() == [.string("11"), .string("13")], "TextEdit in front: the first screen's windows")
    system.frontmost = safari
    #expect(ids() == [.string("12")], "Safari's topmost window is on the second screen")
    system.frontmost = helper
    system.mouse = CGPoint(x: 2000, y: 500)
    #expect(ids() == [.string("12")], "no window in front: the mouse's screen")
    system.listed.removeAll { $0.number == 12 }
    #expect(ids() == [], "an empty desktop")
}

@Test func aFullScreenWindowsBoundsAreFullscreen() {
    let system = desk()
    system.frontmost = safari
    system.ax[safari]?[0].fullScreen = true
    let windows = manager(system).windowsOnActiveDesktop()
    #expect(field(windows[0], "bounds") == .string("fullscreen"))
}

@Test func aWindowTheAccessibilityAPIDoesntHaveCanBeListedButNotMoved() {
    let system = desk()
    system.ax[safari] = []
    let safariWindow = manager(system).windowsOnActiveDesktop()[1]
    #expect(field(safariWindow, "positionable") == .bool(false))
    #expect(field(safariWindow, "resizable") == .bool(false))
    #expect(field(safariWindow, "fullScreenSettable") == .bool(false))
}

@Test func theActiveWindowIsTheFrontmostAppsFocusedOne() throws {
    let system = desk()
    #expect(field(try manager(system).activeWindow(), "id") == .string("11"))

    system.frontmost = safari
    #expect(throws: WindowManagementError.noActiveWindow, "Safari has no focused window") {
        try manager(system).activeWindow()
    }
    system.ax[safari]?[0].focused = true
    #expect(field(try manager(system).activeWindow(), "id") == .string("12"))
    #expect(manager(system).windowsOnActiveDesktop().map { field($0, "active") } == [.bool(true)])
    system.ax[safari]?[0].focused = false
    system.ax[safari]?[1].focused = true
    #expect(field(try manager(system).activeWindow(), "id") == .string("13"), "focused, though not topmost")
    #expect(
        manager(system).windowsOnActiveDesktop().map { field($0, "active") } == [.bool(false), .bool(true)],
        "its screen is the active desktop")
    #expect(manager(system).desktops().map { field($0, "active") } == [.bool(true), .bool(false)])

    system.frontmost = me
    #expect(throws: WindowManagementError.noActiveWindow, "Fudge's own windows are never one") {
        try manager(system).activeWindow()
    }
    system.frontmost = nil
    #expect(throws: WindowManagementError.noActiveWindow) { try manager(system).activeWindow() }
}

// MARK: - Matching the window list to the Accessibility API

@Test func aListedWindowIsTheAXWindowInItsPlaceToWithinAPoint() {
    let listed = ListedWindow(number: 1, pid: textEdit, bounds: editor, title: "Notes.txt")
    func index(_ candidates: [(frame: CGRect?, title: String?)]) -> Int? {
        WindowMatch.index(of: listed, among: candidates)
    }
    #expect(index([(editor.offsetBy(dx: 0.5, dy: -1), nil)]) == 0, "within a point")
    #expect(index([(CGRect(x: 100, y: 80, width: 801, height: 599), nil)]) == 0)
    #expect(index([(editor.offsetBy(dx: 2, dy: 0), nil)]) == nil, "two points off")
    #expect(index([(CGRect(x: 100, y: 80, width: 800, height: 598), nil)]) == nil)
    #expect(index([(nil, "Notes.txt")]) == nil, "no frame, no match")
    #expect(
        index([(editor, "Other.txt"), (editor, "Notes.txt")]) == 1, "the same place, told apart by the title")
    #expect(
        index([(editor, nil), (editor, "Notes.txt")]) == 1,
        "tabs in the same place: the one with the window's title")
    #expect(index([(editor, ""), (editor, nil)]) == 0, "else the first")
    let untitled = ListedWindow(number: 1, pid: textEdit, bounds: editor)
    #expect(
        WindowMatch.index(of: untitled, among: [(editor, "Notes.txt")]) == 0,
        "without Screen Recording, the window list has no titles")
    #expect(WindowMatch.index(of: listed, among: []) == nil)
}

@Test func anAppsWindowsInOnePlacePairOneToOneFrontToBack() {
    // Without Screen Recording the window list has no titles, so an app's windows of one size in one place (two
    // browser windows filling the screen) all match each other: each takes the next free AX window, front to back.
    func untitled(_ number: Int) -> ListedWindow { ListedWindow(number: number, pid: safari, bounds: browser) }
    let two = [untitled(1), untitled(2)]
    #expect(WindowMatch.pairs(two, among: [(browser, "Front"), (browser, "Back")]) == [0, 1])
    let three = [untitled(1), untitled(2), untitled(3)]
    #expect(WindowMatch.pairs(three, among: [(browser, "A"), (browser, "B"), (browser, "C")]) == [0, 1, 2])
    #expect(WindowMatch.pairs(three, among: [(browser, nil), (browser, nil)]) == [0, 1, nil], "one AX window short")
    #expect(
        WindowMatch.pairs(three, among: [(docs, "Docs"), (browser, "A"), (browser, "B"), (browser, "C")]) == [1, 2, 3],
        "a window elsewhere is never taken")

    // A matching title still wins, and its AX window is no one else's.
    let titled = [
        ListedWindow(number: 1, pid: safari, bounds: browser, title: "B"),
        ListedWindow(number: 2, pid: safari, bounds: browser, title: "A"),
    ]
    #expect(WindowMatch.pairs(titled, among: [(browser, "A"), (browser, "B")]) == [1, 0])
    let mixed = [untitled(1), ListedWindow(number: 2, pid: safari, bounds: browser, title: "A")]
    #expect(
        WindowMatch.pairs(mixed, among: [(browser, "A"), (browser, "B")]) == [1, 0],
        "the titled window takes its own first, the untitled one the next free")
    #expect(WindowMatch.pairs([], among: [(browser, nil)]) == [])
}

@Test func sameSizeWindowsOfOneAppAreEachTheirOwn() throws {
    // Three Safari windows filling the same place, no titles in the window list: each listed window is its own AX
    // window, so moving the back one moves the back one, and the focused one is the active one.
    let system = desk()
    system.frontmost = safari
    system.listed = [
        ListedWindow(number: 21, pid: safari, bounds: browser),
        ListedWindow(number: 22, pid: safari, bounds: browser),
        ListedWindow(number: 23, pid: safari, bounds: browser),
    ]
    system.ax[safari] = [
        AXWindow(handle: 31, frame: browser, title: "Front"),
        AXWindow(handle: 32, frame: browser, title: "Middle"),
        AXWindow(handle: 33, frame: browser, title: "Back", sizeSettable: false),
    ]
    try manager(system).setBounds(json(#"{"id":"23","bounds":{"position":{"x":1500}}}"#))
    try manager(system).setBounds(json(#"{"id":"22","bounds":{"position":{"x":1550}}}"#))
    try manager(system).setBounds(json(#"{"id":"21","bounds":{"position":{"x":1600}}}"#))
    #expect(system.applied == ["33 at 1500,50", "32 at 1550,50", "31 at 1600,50"])
    #expect(
        manager(system).windowsOnActiveDesktop().map { field($0, "resizable") }
            == [.bool(true), .bool(true), .bool(false)], "each reports its own AX window")

    system.ax[safari]?[2].focused = true
    #expect(field(try manager(system).activeWindow(), "id") == .string("23"), "the focused one, at the back")
    #expect(
        manager(system).windowsOnActiveDesktop().map { field($0, "active") }
            == [.bool(false), .bool(false), .bool(true)])

    // A minimized window isn't in the window list, so it takes no part, wherever the Accessibility API lists it.
    system.ax[safari]?.insert(AXWindow(handle: 30, frame: browser, title: "Minimized", minimized: true), at: 0)
    try manager(system).setBounds(json(#"{"id":"21","bounds":{"position":{"x":1600}}}"#))
    #expect(system.applied.last == "31 at 1600,50")
    #expect(field(try manager(system).activeWindow(), "id") == .string("23"))
}

// MARK: - Desktops

@Test func eachScreenIsOneDesktopTheActiveOneHoldingTheFrontmostWindow() throws {
    let system = desk()
    #expect(
        manager(system).desktops() == [
            .object([
                "id": .string("screen-1"), "screenId": .string("1"),
                "size": .object(["width": .number(1440), "height": .number(900)]),
                "active": .bool(true), "type": .string("User"),
            ]),
            .object([
                "id": .string("screen-2"), "screenId": .string("2"),
                "size": .object(["width": .number(1920), "height": .number(1080)]),
                "active": .bool(false), "type": .string("User"),
            ]),
        ])

    system.frontmost = safari
    #expect(manager(system).desktops().map { field($0, "active") } == [.bool(false), .bool(true)])

    // An app with no window on screen: the mouse's screen.
    system.frontmost = helper
    system.mouse = CGPoint(x: 2000, y: 500)
    #expect(manager(system).desktops().map { field($0, "active") } == [.bool(false), .bool(true)])
    system.mouse = CGPoint(x: -50, y: -50)
    #expect(
        manager(system).desktops().map { field($0, "active") } == [.bool(true), .bool(false)],
        "else the primary screen")
}

@Test func aScreenWhoseFrontWindowIsFullScreenIsAFullScreenDesktop() {
    let system = desk()
    system.ax[safari]?[0].fullScreen = true
    #expect(manager(system).desktops().map { field($0, "type") } == [.string("User"), .string("FullScreen")])
    system.ax[textEdit]?[0].fullScreen = true
    #expect(
        manager(system).desktops().map { field($0, "type") } == [.string("FullScreen"), .string("FullScreen")])
}

// MARK: - setWindowBounds

@Test func boundsLeftOutKeepTheirCurrentValue() throws {
    let system = desk()
    let windows = manager(system)
    try windows.setBounds(json(#"{"id":"11","bounds":{"position":{"x":300}}}"#))
    try windows.setBounds(json(#"{"id":"11","bounds":{"size":{"height":500}}}"#))
    try windows.setBounds(json(#"{"id":"11","bounds":{"position":{"x":0,"y":25},"size":{"width":720,"height":900}}}"#))
    try windows.setBounds(json(#"{"id":"11","bounds":{"position":{"y":40}},"desktopId":"screen-1"}"#))
    try windows.setBounds(json(#"{"id":"11","bounds":{}}"#))
    try windows.setBounds(json(#"{"id":"11","bounds":{"position":{},"size":null}}"#))
    #expect(
        system.applied == [
            "1 at 300,80",
            "1 size 800x500",
            "1 at 0,25 size 720x900",
            "1 at 100,40",
        ], "nothing to change, nothing applied")
}

@Test func aWindowBecomesFullScreenWhenItCan() throws {
    let system = desk()
    try manager(system).setBounds(json(#"{"id":"11","bounds":"fullscreen"}"#))
    #expect(system.applied == ["1 full screen"])
    system.ax[textEdit]?[0].fullScreen = true
    try manager(system).setBounds(json(#"{"id":"11","bounds":"fullscreen"}"#))
    #expect(system.applied == ["1 full screen"], "already full screen")
    #expect(throws: WindowManagementError.cantMakeFullScreen) {
        try manager(system).setBounds(json(#"{"id":"12","bounds":"fullscreen"}"#))
    }
}

@Test func setWindowBoundsRefusesWhatItCantDo() throws {
    let system = desk()
    let windows = manager(system)
    func refusal(_ options: String) throws -> WindowManagementError? {
        do {
            try windows.setBounds(json(options))
            return nil
        } catch let error as WindowManagementError {
            return error
        }
    }
    #expect(try refusal(#"{"id":"999","bounds":{}}"#) == .noWindow(id: "999"))
    #expect(try refusal(#"{"id":"abc","bounds":{}}"#) == .noWindow(id: "abc"))
    #expect(try refusal(#"{"id":"7","bounds":{}}"#) == .noWindow(id: "7"), "Fudge's own window isn't one")
    #expect(try refusal(#"{"id":"12","bounds":{"size":{"width":300}}}"#) == .cantResize)
    #expect(
        try refusal(#"{"id":"11","bounds":{"position":{"x":5}},"desktopId":"screen-2"}"#) == .otherDesktop)
    #expect(try refusal(#"{"bounds":{}}"#) == .invalidOptions("id must be a string"))
    #expect(try refusal(#"{"id":"11"}"#) == .invalidOptions(#"bounds must be an object or "fullscreen""#))
    #expect(
        try refusal(#"{"id":"11","bounds":"big"}"#) == .invalidOptions(#"bounds must be an object or "fullscreen""#))
    #expect(try refusal(#"{"id":"11","bounds":{"position":5}}"#) == .invalidOptions("position must be an object"))
    #expect(
        try refusal(#"{"id":"11","bounds":{"position":{"x":"5"}}}"#) == .invalidOptions("position.x must be a number"))
    #expect(
        try refusal(#"{"id":"11","bounds":{"size":{"width":0}}}"#)
            == .invalidOptions("a window's width and height must be more than 0"))
    #expect(try refusal(#"{"id":"11","bounds":{},"desktopId":5}"#) == .invalidOptions("desktopId must be a string"))

    system.ax[safari]?[0].positionSettable = false
    #expect(try refusal(#"{"id":"12","bounds":{"position":{"y":5}}}"#) == .cantMove)
    system.ax[safari] = []
    #expect(try refusal(#"{"id":"12","bounds":{"position":{"y":5}}}"#) == .cantMove, "no Accessibility window")
    #expect(try refusal(#"{"id":"12","bounds":"fullscreen"}"#) == .cantMakeFullScreen)

    system.refusal = "TextEdit didn't move the window"
    #expect(try refusal(#"{"id":"11","bounds":{"position":{"x":5}}}"#) == .failed("TextEdit didn't move the window"))
    #expect(system.applied.isEmpty, "nothing applied on a refusal")
}

@Test func windowManagementErrorsCarryTheMessagesExtensionsSee() {
    #expect(
        WindowManagementError.accessibilityNeeded.description
            == "Fudge needs Accessibility permission to manage windows. "
            + "Allow Fudge in System Settings → Privacy & Security → Accessibility.")
    #expect(WindowManagementError.noActiveWindow.description == "There is no active window")
    #expect(WindowManagementError.noWindow(id: "42").description == "No window with id 42")
    #expect(WindowManagementError.otherDesktop.description == "Fudge can't move windows between desktops.")
    #expect(WindowManagementError.cantMove.description == "This window can't be moved")
    #expect(WindowManagementError.cantResize.description == "This window can't be resized")
    #expect(WindowManagementError.cantMakeFullScreen.description == "This window can't be made full screen")
    #expect(WindowManagementError.invalidOptions("x").description == "setWindowBounds: x")
}
