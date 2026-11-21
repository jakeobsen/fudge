import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

private let app: Int32 = 200
private let me: Int32 = 100
/// The primary screen, with a 25-point menu bar, and a second one to its right.
private let primary = WindowScreen(
    id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleBounds: CGRect(x: 0, y: 25, width: 1440, height: 875))
private let second = WindowScreen(
    id: 2, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleBounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
private let start = CGRect(x: 100, y: 125, width: 800, height: 500)

/// One app with one focused window (AX handle 1, window number 10). Applying a change moves the window, so later
/// reads see it where it went.
private final class Desk: WindowSystem {
    typealias Handle = Int
    var frame = start
    var screenList = [primary]
    var frontmost: Int32? = app
    var focused = true
    var positionSettable = true
    var sizeSettable = true
    var fullScreen = false
    var fullScreenSettable = true
    var listed = true
    var refusal: String?
    private(set) var applied: [String] = []

    func listedWindows() -> [ListedWindow] { listed ? [ListedWindow(number: 10, pid: app, bounds: frame)] : [] }
    func screens() -> [WindowScreen] { screenList }
    func mouseLocation() -> CGPoint { .zero }
    func frontmostPid() -> Int32? { frontmost }
    func application(pid: Int32) -> JSONValue? { pid == app ? .object(["name": .string("TextEdit")]) : nil }
    func axWindows(pid: Int32) -> [AXWindow<Int>] {
        guard pid == app else { return [] }
        return [
            AXWindow(
                handle: 1, frame: frame, positionSettable: positionSettable, sizeSettable: sizeSettable,
                fullScreen: fullScreen, fullScreenSettable: fullScreenSettable, focused: focused)
        ]
    }

    func apply(_ change: WindowChange, to window: Int) throws {
        if let refusal { throw WindowManagementError.failed(refusal) }
        switch change {
        case .fullScreen:
            applied.append("full screen")
        case .exitFullScreen:
            applied.append("out of full screen")
        case .frame(let position, let size):
            if let position { frame.origin = position }
            if let size { frame.size = size }
            let at = position.map { "at \(Int($0.x)),\(Int($0.y))" }
            let sized = size.map { "size \(Int($0.width))x\(Int($0.height))" }
            applied.append([at, sized].compactMap { $0 }.joined(separator: " "))
        }
    }
}

private func run(_ command: WindowCommand, on desk: Desk, _ frames: inout WindowFrames) -> WindowCommandResult {
    WindowManager(system: desk, ownPid: me).run(command, frames: &frames)
}

@Test func aCommandSetsPositionThenSizeThenPositionAgain() {
    let desk = Desk()
    var frames = WindowFrames()
    #expect(run(.leftHalf, on: desk, &frames) == .done)
    #expect(desk.applied == ["at 0,25 size 720x875", "at 0,25"])
    #expect(desk.frame == CGRect(x: 0, y: 25, width: 720, height: 875))
}

@Test func restoreGoesBackOnceAndRemembersPerWindowWhileItsOpen() {
    let desk = Desk()
    var frames = WindowFrames()
    #expect(run(.restore, on: desk, &frames) == .done)
    #expect(desk.applied.isEmpty, "nothing kept: Restore does nothing")

    _ = run(.leftHalf, on: desk, &frames)
    _ = run(.maximize, on: desk, &frames)
    #expect(frames.frame(of: 10) == CGRect(x: 0, y: 25, width: 720, height: 875), "the frame before the last move")
    #expect(run(.restore, on: desk, &frames) == .done)
    #expect(desk.frame == CGRect(x: 0, y: 25, width: 720, height: 875))
    let count = desk.applied.count
    #expect(run(.restore, on: desk, &frames) == .done)
    #expect(desk.applied.count == count, "Restore records nothing, so a second one does nothing")

    _ = run(.rightHalf, on: desk, &frames)
    desk.listed = false
    #expect(run(.center, on: desk, &frames) == .noWindow)
    #expect(frames.frame(of: 10) == nil, "a window that's gone is dropped")
}

@Test func aFullScreenWindowTakesOnlyToggleFullScreen() {
    let desk = Desk()
    desk.fullScreen = true
    var frames = WindowFrames()
    for command in WindowCommand.allCases where command != .toggleFullScreen {
        #expect(run(command, on: desk, &frames) == .fullScreen, "\(command)")
    }
    #expect(WindowCommandResult.fullScreen == .message("Exit full screen first."))
    #expect(desk.applied.isEmpty)
    #expect(run(.toggleFullScreen, on: desk, &frames) == .done)
    desk.fullScreen = false
    #expect(run(.toggleFullScreen, on: desk, &frames) == .done)
    #expect(desk.applied == ["out of full screen", "full screen"])
    desk.fullScreenSettable = false
    #expect(run(.toggleFullScreen, on: desk, &frames) == .cantFullScreen)
}

@Test func aWindowThatCantBeResizedMovesToTheTargetsCorner() {
    let desk = Desk()
    desk.sizeSettable = false
    var frames = WindowFrames()
    #expect(run(.rightHalf, on: desk, &frames) == .done)
    #expect(desk.applied == ["at 640,25"], "the right half's corner, kept inside: 1440 - 800")
    desk.positionSettable = false
    #expect(run(.leftHalf, on: desk, &frames) == .cantMove)
    #expect(WindowCommandResult.cantMove == .message("This window can't be moved."))
    #expect(desk.applied.count == 1)
}

@Test func nextAndPreviousDisplayNeedASecondScreen() {
    let desk = Desk()
    var frames = WindowFrames()
    #expect(run(.nextDisplay, on: desk, &frames) == .oneDisplay)
    #expect(WindowCommandResult.oneDisplay == .message("There's only one display."))
    desk.screenList = [primary, second]
    #expect(run(.nextDisplay, on: desk, &frames) == .done)
    #expect(
        desk.frame == WindowLayout.moved(start, from: primary.visibleBounds, to: second.visibleBounds),
        "the same place and size relative to the next screen's visible frame")
    #expect(run(.nextDisplay, on: desk, &frames) == .done, "wraps around")
    #expect(primary.visibleBounds.contains(desk.frame))
    #expect(run(.previousDisplay, on: desk, &frames) == .done)
    #expect(second.visibleBounds.contains(desk.frame))
}

@Test func withoutAFocusedWindowNothingMoves() {
    let desk = Desk()
    var frames = WindowFrames()
    desk.focused = false
    #expect(run(.leftHalf, on: desk, &frames) == .noWindow)
    #expect(WindowCommandResult.noWindow == .message("There's no window to move."))
    desk.focused = true
    desk.frontmost = me
    #expect(run(.leftHalf, on: desk, &frames) == .noWindow, "never Fudge's own window")
    #expect(desk.applied.isEmpty)
}

@Test func aRefusedChangeSaysWhyAndRemembersNothing() {
    let desk = Desk()
    desk.refusal = "The window's app didn't accept the change"
    var frames = WindowFrames()
    #expect(
        run(.maximize, on: desk, &frames)
            == .message(String(describing: WindowManagementError.failed("The window's app didn't accept the change"))))
    #expect(frames.frame(of: 10) == nil)
}

// MARK: - Visible frames in top-left coordinates

/// Cocoa frames (bottom-left origin) of a 1440×900 primary screen at the origin and the screens around it.
@Test func visibleFramesFlipAgainstThePrimaryScreenOnly() {
    let primaryHeight: CGFloat = 900
    func topLeft(_ cocoa: CGRect) -> CGRect { PanelScreen.topLeftFrame(cocoa: cocoa, primaryHeight: primaryHeight) }
    // The primary's visible frame, under a 25-point menu bar.
    #expect(topLeft(CGRect(x: 0, y: 0, width: 1440, height: 875)) == CGRect(x: 0, y: 25, width: 1440, height: 875))
    // A screen above the primary, with its own 25-point menu bar.
    #expect(
        topLeft(CGRect(x: 0, y: 900, width: 1920, height: 1055)) == CGRect(x: 0, y: -1055, width: 1920, height: 1055))
    // One to its left with a different height, its bottom 100 points above the primary's.
    #expect(
        topLeft(CGRect(x: -1280, y: 100, width: 1280, height: 1024))
            == CGRect(x: -1280, y: -224, width: 1280, height: 1024))
    // One below it, with a Dock of 70 points at its bottom.
    #expect(
        topLeft(CGRect(x: 0, y: -1010, width: 1920, height: 1010)) == CGRect(x: 0, y: 900, width: 1920, height: 1010))
}
