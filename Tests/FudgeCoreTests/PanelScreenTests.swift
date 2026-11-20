import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

/// The primary screen at the origin, and a second one to its right.
private let sideBySide = [
    CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080),
]
/// The primary screen, and a second one stacked above it (Cocoa's y goes up).
private let stacked = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 900, width: 1440, height: 900)]

@Test func eachSettingPicksItsScreen() {
    let mouseOnSecond = CGPoint(x: 2000, y: 500)
    let windowOnSecond = CGRect(x: 1600, y: 100, width: 800, height: 600)
    #expect(PanelScreen.choose(setting: .mouse, screens: sideBySide, mouse: mouseOnSecond, activeWindowFrame: nil) == 1)
    #expect(
        PanelScreen.choose(
            setting: .primary, screens: sideBySide, mouse: mouseOnSecond, activeWindowFrame: windowOnSecond)
            == 0)
    #expect(
        PanelScreen.choose(
            setting: .activeWindow, screens: sideBySide, mouse: CGPoint(x: 10, y: 10), activeWindowFrame: windowOnSecond
        )
            == 1)
    #expect(
        PanelScreen.choose(setting: .activeWindow, screens: sideBySide, mouse: mouseOnSecond, activeWindowFrame: nil)
            == 1,
        "no active window: the mouse's screen")
    #expect(
        PanelScreen.choose(
            setting: .activeWindow, screens: sideBySide, mouse: mouseOnSecond,
            activeWindowFrame: CGRect(x: -5000, y: -5000, width: 10, height: 10)) == 1,
        "a window on no screen: the mouse's screen")
    #expect(PanelScreen.choose(setting: .mouse, screens: [], mouse: .zero, activeWindowFrame: nil) == nil)
}

@Test func aWindowSpanningTwoScreensGoesToTheOneHoldingMostOfIt() {
    let mostlySecond = CGRect(x: 1240, y: 100, width: 1000, height: 600)  // 200 on the first, 800 on the second
    #expect(
        PanelScreen.choose(setting: .activeWindow, screens: sideBySide, mouse: .zero, activeWindowFrame: mostlySecond)
            == 1)
    let mostlyFirst = CGRect(x: 640, y: 100, width: 1000, height: 600)  // 800 on the first, 200 on the second
    #expect(
        PanelScreen.choose(setting: .activeWindow, screens: sideBySide, mouse: .zero, activeWindowFrame: mostlyFirst)
            == 0)
}

@Test func windowListBoundsAreFlippedBeforeChoosingWithStackedScreens() {
    // CGWindowList measures from the primary screen's top left, y down: a window 200 pt above the primary
    // screen's top edge is on the upper screen, at Cocoa y 900 + ...
    let upperWindow = CGRect(x: 100, y: -700, width: 800, height: 500)
    let flipped = PanelScreen.cocoaFrame(windowListBounds: upperWindow, primaryHeight: 900)
    #expect(flipped == CGRect(x: 100, y: 1100, width: 800, height: 500))
    #expect(PanelScreen.choose(setting: .activeWindow, screens: stacked, mouse: .zero, activeWindowFrame: flipped) == 1)
    let lowerWindow = PanelScreen.cocoaFrame(
        windowListBounds: CGRect(x: 100, y: 100, width: 800, height: 500), primaryHeight: 900)
    #expect(lowerWindow == CGRect(x: 100, y: 300, width: 800, height: 500))
    #expect(
        PanelScreen.choose(setting: .activeWindow, screens: stacked, mouse: .zero, activeWindowFrame: lowerWindow) == 0)
    // Unflipped, the upper window would have been read as being on the lower screen, or on none.
    #expect(
        PanelScreen.choose(setting: .activeWindow, screens: stacked, mouse: .zero, activeWindowFrame: upperWindow) != 1)
}

@Test(arguments: EscapeBehavior.allCases)
func popoversCloseFirstEitherWay(behavior: EscapeBehavior) {
    let root = EscapeAction.State.Screen.root(queryEmpty: false)
    #expect(
        EscapeAction.next(behavior: behavior, state: .init(dropdownOpen: true, actionPanelOpen: true, screen: root))
            == .closeDropdown)
    #expect(
        EscapeAction.next(behavior: behavior, state: .init(actionPanelOpen: true, screen: root)) == .closeActionPanel)
}

@Test func navigateBackGoesOneStepAtATime() {
    func next(_ screen: EscapeAction.State.Screen) -> EscapeAction {
        EscapeAction.next(behavior: .back, state: .init(screen: screen))
    }
    #expect(next(.root(queryEmpty: false)) == .clearSearch)
    #expect(next(.root(queryEmpty: true)) == .hide)
    #expect(next(.command(depth: 2, searchEmpty: false, isForm: false)) == .popView, "a pushed view first")
    #expect(next(.command(depth: 1, searchEmpty: false, isForm: false)) == .clearSearch)
    #expect(next(.command(depth: 1, searchEmpty: true, isForm: false)) == .leaveCommand)
    #expect(next(.failure) == .dismissFailure)
}

@Test func closeAndResetHidesAtOnceExceptInAForm() {
    func next(_ screen: EscapeAction.State.Screen) -> EscapeAction {
        EscapeAction.next(behavior: .closeAndReset, state: .init(screen: screen))
    }
    #expect(next(.root(queryEmpty: false)) == .hideAndReset)
    #expect(next(.root(queryEmpty: true)) == .hideAndReset)
    #expect(next(.command(depth: 3, searchEmpty: false, isForm: false)) == .hideAndReset, "even with a pushed view")
    #expect(next(.failure) == .hideAndReset)
    #expect(next(.command(depth: 1, searchEmpty: true, isForm: true)) == .leaveCommand, "Esc is the Form's own key")
}

@Test func bothSettingsRoundTripAndTheirDefaultsArentWritten() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    try Data(#"{ "theme": "dark", "showOnScreen": "nowhere", "escapeBehavior": 3 }"#.utf8).write(to: file)
    var settings = FudgeSettings.load(from: file)
    #expect(settings.showOnScreen == .mouse, "an unknown value is the default")
    #expect(settings.escapeBehavior == .back)

    settings.showOnScreen = .activeWindow
    settings.escapeBehavior = .closeAndReset
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).showOnScreen == .activeWindow)
    #expect(FudgeSettings.load(from: file).escapeBehavior == .closeAndReset)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["showOnScreen"] as? String == "activeWindow")
    #expect(object["escapeBehavior"] as? String == "closeAndReset")
    #expect(object["theme"] as? String == "dark")

    settings.showOnScreen = .mouse
    settings.escapeBehavior = .back
    try settings.save(to: file)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["showOnScreen"] == nil && object["escapeBehavior"] == nil, "defaults aren't written")
}
