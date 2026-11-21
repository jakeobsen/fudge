import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

// SPEC-094: custom positions and saved layouts. Every window here is made up; nothing touches a real window.

private let me: Int32 = 100
private let editor: Int32 = 200
private let browser: Int32 = 300
/// A process with windows that isn't a regular app.
private let helper: Int32 = 400

/// The primary screen, with a 25-point menu bar, and a second one to its right.
private let displayA = WindowScreen(
    id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleBounds: CGRect(x: 0, y: 25, width: 1440, height: 875), name: "Display A")
private let displayB = WindowScreen(
    id: 2, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080), name: "Display B")

/// Apps and their windows, front to back. A change moves the window, so later reads see it where it went.
private final class Room: WindowSystem {
    typealias Handle = Int

    struct Window {
        var number: Int
        var pid: Int32
        var frame: CGRect
        var title: String?
        var standard = true
        var fullScreen = false
        var positionSettable = true
        var sizeSettable = true
    }

    var windows: [Window]
    var screenList = [displayA, displayB]
    var frontmost: Int32?
    var focused: Int?
    let bundleIds: [Int32: String] = [
        me: "io.github.jakeobsen.fudge", editor: "com.example.editor", browser: "com.example.browser",
    ]

    init(_ windows: [Window], frontmost: Int32? = nil, focused: Int? = nil) {
        self.windows = windows
        self.frontmost = frontmost
        self.focused = focused
    }

    func listedWindows() -> [ListedWindow] {
        windows.map { ListedWindow(number: $0.number, pid: $0.pid, bounds: $0.frame, title: $0.title) }
    }
    func screens() -> [WindowScreen] { screenList }
    func mouseLocation() -> CGPoint { .zero }
    func frontmostPid() -> Int32? { frontmost }
    func application(pid: Int32) -> JSONValue? {
        bundleIds[pid].map { .object(["name": .string($0), "bundleId": .string($0)]) }
    }
    func axWindows(pid: Int32) -> [AXWindow<Int>] {
        windows.filter { $0.pid == pid }.map {
            AXWindow(
                handle: $0.number, frame: $0.frame, title: $0.title, positionSettable: $0.positionSettable,
                sizeSettable: $0.sizeSettable, fullScreen: $0.fullScreen, focused: $0.number == focused,
                standard: $0.standard)
        }
    }

    func apply(_ change: WindowChange, to window: Int) throws {
        guard let index = windows.firstIndex(where: { $0.number == window }) else {
            throw WindowManagementError.windowClosed
        }
        if case .frame(let position, let size) = change {
            if let position { windows[index].frame.origin = position }
            if let size { windows[index].frame.size = size }
        }
    }

    func frame(_ number: Int) -> CGRect? { windows.first { $0.number == number }?.frame }
}

private func manager(_ room: Room) -> WindowManager<Room> { WindowManager(system: room, ownPid: me) }

private let left70 = WindowFractions(x: 0, y: 0, width: 0.7, height: 1)

// MARK: - Fractions and frames

@Test func fractionsBecomeFramesInEachScreensVisibleFrame() {
    #expect(left70.frame(in: displayA.visibleBounds) == CGRect(x: 0, y: 25, width: 1008, height: 875))
    #expect(
        WindowFractions(x: 0.5, y: 0.5, width: 0.5, height: 0.5).frame(in: displayB.visibleBounds)
            == CGRect(x: 2400, y: 540, width: 960, height: 540))
    // A screen above the primary one, at negative y.
    let above = CGRect(x: 0, y: -1055, width: 1920, height: 1055)
    #expect(
        WindowFractions(x: 0, y: 0.2, width: 1, height: 0.8).frame(in: above)
            == CGRect(x: 0, y: -844, width: 1920, height: 844))
    // Edges are whole points, so neighbouring positions meet without a gap on an odd width.
    let odd = CGRect(x: 0, y: 0, width: 1441, height: 900)
    let first = WindowFractions(x: 0, y: 0, width: 1.0 / 3, height: 1).frame(in: odd)
    let rest = WindowFractions(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1).frame(in: odd)
    #expect(first.maxX == rest.minX && rest.maxX == 1441)
}

@Test func aFrameBecomesFractionsOfThePartOfItInsideTheVisibleFrame() throws {
    let visible = displayA.visibleBounds
    let fractions = try #require(WindowFractions(CGRect(x: 144, y: 200, width: 720, height: 350), in: visible))
    #expect(fractions == WindowFractions(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
    #expect(fractions.frame(in: visible) == CGRect(x: 144, y: 200, width: 720, height: 350))
    // Under the menu bar and past the left edge: only the part inside counts.
    let past = try #require(WindowFractions(CGRect(x: -100, y: 0, width: 400, height: 300), in: visible))
    #expect(past == WindowFractions(x: 0, y: 0, width: 300.0 / 1440, height: 275.0 / 875))
    #expect(WindowFractions(CGRect(x: 2000, y: 100, width: 100, height: 100), in: visible) == nil)
}

@Test func fractionsAreValidOnlyForASizeInsideTheScreen() {
    #expect(left70.isValid)
    #expect(WindowFractions(x: 0.6, y: 0, width: 0.4, height: 1).isValid)
    #expect(WindowFractions(x: 0.3, y: 0, width: 0.7 + 1e-12, height: 1).isValid, "rounding")
    #expect(!WindowFractions(x: 0.5, y: 0, width: 0.6, height: 1).isValid, "past the right edge")
    #expect(!WindowFractions(x: 0, y: 0.5, width: 1, height: 0.6).isValid, "past the bottom")
    #expect(!WindowFractions(x: 0, y: 0, width: 0, height: 1).isValid)
    #expect(!WindowFractions(x: -0.1, y: 0, width: 0.5, height: 1).isValid)
    #expect(!WindowFractions(x: 0, y: 0, width: 1.1, height: 1).isValid)
    #expect(!WindowFractions(x: .nan, y: 0, width: 0.5, height: 1).isValid)
    #expect(!WindowFractions(x: 0, y: 0, width: .infinity, height: 1).isValid)
    // At least 5% each way, whatever the screen (SPEC-102 §3).
    #expect(!WindowFractions(x: 1, y: 0, width: 1e-12, height: 1).isValid, "a sliver at the edge")
    #expect(!WindowFractions(x: 0.98, y: 0, width: 0.05, height: 1).isValid)
    #expect(!WindowFractions(x: 0, y: 0, width: 0.04, height: 1).isValid)
    #expect(!WindowFractions(x: 0, y: 0, width: 1, height: 0.049).isValid)
    #expect(WindowFractions(x: 0.95, y: 0.95, width: 0.05, height: 0.05).isValid)
}

@Test func aSmallFrameIsPlacedAtLeast100PointsAndOnTheScreen() {
    let small = CGRect(x: 0, y: 0, width: 800, height: 600)
    let corner = WindowFractions(x: 0.95, y: 0.95, width: 0.05, height: 0.05)
    // 40 × 30 pt would be 5% here: it grows to 100 pt, moved back inside the screen.
    #expect(corner.frame(in: small) == CGRect(x: 700, y: 500, width: 100, height: 100))
    #expect(
        WindowFractions(x: 0, y: 0, width: 0.05, height: 1).frame(in: small)
            == CGRect(x: 0, y: 0, width: 100, height: 600))
    let big = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    // On a big screen 5% of its width is already more than 100 pt; its height, 72 pt, grows and moves back up.
    #expect(corner.frame(in: big) == CGRect(x: 2432, y: 1340, width: 128, height: 100))
    // A screen narrower than 100 pt gets the whole side.
    #expect(corner.frame(in: CGRect(x: 0, y: 0, width: 80, height: 600)).width == 80)
}

@Test func aSavedWindowSmallerThanTheMinimumIsKeptAtTheMinimum() throws {
    // A 30 × 20 pt window near the right edge of a 1440 pt screen.
    let saved = try #require(WindowFractions(CGRect(x: 1400, y: 25, width: 30, height: 20), in: displayA.visibleBounds))
    #expect(saved == WindowFractions(x: 0.95, y: 0, width: 0.05, height: 0.05))
}

// MARK: - Custom positions

@Test func aCustomPositionMovesTheFrontWindowAsLeftHalfDoes() {
    let start = CGRect(x: 100, y: 125, width: 800, height: 500)
    let room = Room([.init(number: 10, pid: editor, frame: start)], frontmost: editor, focused: 10)
    var frames = WindowFrames()
    #expect(manager(room).run(position: left70, frames: &frames) == .done)
    #expect(room.frame(10) == CGRect(x: 0, y: 25, width: 1008, height: 875))
    #expect(manager(room).run(.restore, frames: &frames) == .done)
    #expect(room.frame(10) == start, "Restore goes back from a custom position too")
    // On the second screen, it's that screen's visible frame.
    room.windows[0].frame = CGRect(x: 1600, y: 100, width: 600, height: 400)
    #expect(manager(room).run(position: left70, frames: &frames) == .done)
    #expect(room.frame(10) == CGRect(x: 1440, y: 0, width: 1344, height: 1080))
}

@Test func aCustomPositionFollowsTheWindowCommandsRules() {
    let start = CGRect(x: 100, y: 125, width: 800, height: 500)
    let room = Room([.init(number: 10, pid: editor, frame: start)], frontmost: editor, focused: 10)
    var frames = WindowFrames()
    room.windows[0].fullScreen = true
    #expect(manager(room).run(position: left70, frames: &frames) == .fullScreen)
    room.windows[0].fullScreen = false
    room.windows[0].sizeSettable = false
    #expect(manager(room).run(position: left70, frames: &frames) == .done)
    #expect(room.frame(10) == CGRect(x: 0, y: 25, width: 800, height: 500), "its own size, at the target's corner")
    room.windows[0].positionSettable = false
    #expect(manager(room).run(position: left70, frames: &frames) == .cantMove)
    room.focused = nil
    #expect(manager(room).run(position: left70, frames: &frames) == .noWindow)
}

// MARK: - Saving and applying layouts

/// Two apps on two screens, with windows layouts don't take: Fudge's own, a panel, a non-regular app's, and a
/// full-screen one.
private func desk() -> Room {
    Room([
        .init(number: 21, pid: browser, frame: CGRect(x: 0, y: 25, width: 720, height: 875), title: "Secret plans"),
        .init(number: 10, pid: editor, frame: CGRect(x: 1440, y: 0, width: 960, height: 1080), title: "notes.txt"),
        .init(number: 5, pid: me, frame: CGRect(x: 400, y: 200, width: 640, height: 400)),
        .init(number: 22, pid: browser, frame: CGRect(x: 720, y: 25, width: 720, height: 875), title: "Bank"),
        .init(
            number: 23, pid: browser, frame: CGRect(x: 100, y: 100, width: 300, height: 200), title: "Downloads",
            standard: false),
        .init(number: 40, pid: helper, frame: CGRect(x: 0, y: 25, width: 200, height: 200)),
        .init(number: 11, pid: editor, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), fullScreen: true),
    ])
}

@Test func savingALayoutKeepsBundleIdsPlacesScreensAndFractionsOnly() throws {
    let saved = manager(desk()).captureLayout()
    let screenA = SavedScreen(name: "Display A", index: 0)
    #expect(
        saved == [
            SavedWindow(
                bundleId: "com.example.browser", index: 0, screen: screenA,
                frame: WindowFractions(x: 0, y: 0, width: 0.5, height: 1)),
            // The panel isn't a standard window, so it takes no place.
            SavedWindow(
                bundleId: "com.example.browser", index: 1, screen: screenA,
                frame: WindowFractions(x: 0.5, y: 0, width: 0.5, height: 1)),
            // The full-screen window takes the editor's second place, but isn't kept.
            SavedWindow(
                bundleId: "com.example.editor", index: 0, screen: SavedScreen(name: "Display B", index: 1),
                frame: WindowFractions(x: 0, y: 0, width: 0.5, height: 1)),
        ])
    // No title reaches the file.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-layouts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("window-layouts.json")
    try WindowLayoutStore(layouts: [SavedWindowLayout(name: "Desk", windows: saved)]).save(to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    for title in ["Secret plans", "Bank", "notes.txt", "Downloads"] { #expect(!text.contains(title)) }
}

@Test func applyingALayoutPlacesEachAppsWindowsByPlaceAndSkipsTheRest() {
    let room = desk()
    let before = room.frame(21)
    let layout = SavedWindowLayout(
        name: "Desk",
        windows: [
            SavedWindow(
                bundleId: "com.example.browser", index: 0, screen: SavedScreen(name: "Display A", index: 0),
                frame: WindowFractions(x: 0, y: 0, width: 0.25, height: 1)),
            // Found by its name, though its place changed.
            SavedWindow(
                bundleId: "com.example.browser", index: 1, screen: SavedScreen(name: "Display B", index: 5),
                frame: WindowFractions(x: 0, y: 0, width: 1, height: 0.5)),
            // The browser has no third window now.
            SavedWindow(
                bundleId: "com.example.browser", index: 2, screen: SavedScreen(name: "Display A", index: 0),
                frame: left70),
            // A screen that's gone: the one in its place.
            SavedWindow(
                bundleId: "com.example.editor", index: 0, screen: SavedScreen(name: "Gone", index: 1),
                frame: WindowFractions(x: 0.5, y: 0, width: 0.5, height: 1)),
            // Full screen.
            SavedWindow(
                bundleId: "com.example.editor", index: 1, screen: SavedScreen(name: "Display A", index: 0),
                frame: left70),
            // Not running, so not launched.
            SavedWindow(
                bundleId: "com.example.mail", index: 0, screen: SavedScreen(name: "Display A", index: 0), frame: left70),
        ])
    var frames = WindowFrames()
    let placement = manager(room).apply(layout, frames: &frames)
    #expect(placement == LayoutPlacement(placed: 3, skipped: 3))
    #expect(placement.message == "Placed 3 windows; skipped 3")
    #expect(room.frame(21) == CGRect(x: 0, y: 25, width: 360, height: 875))
    #expect(room.frame(22) == CGRect(x: 1440, y: 0, width: 1920, height: 540))
    #expect(room.frame(10) == CGRect(x: 2400, y: 0, width: 960, height: 1080))
    #expect(room.frame(23) == CGRect(x: 100, y: 100, width: 300, height: 200), "the panel isn't touched")
    #expect(room.frame(5) == CGRect(x: 400, y: 200, width: 640, height: 400), "nor Fudge's own window")
    #expect(frames.frame(of: 21) == before, "Restore can put each back")
}

@Test func oneAppAndPlaceNamedTwiceIsPlacedOnce() {
    // A hand-edited file names the browser's front window twice: it's placed once, by the first, and the second is
    // skipped (SPEC-102 §3).
    let room = desk()
    let first = WindowFractions(x: 0, y: 0, width: 0.25, height: 1)
    let screenA = SavedScreen(name: "Display A", index: 0)
    let layout = SavedWindowLayout(
        name: "Twice",
        windows: [
            SavedWindow(bundleId: "com.example.browser", index: 0, screen: screenA, frame: first),
            SavedWindow(bundleId: "com.example.browser", index: 0, screen: screenA, frame: left70),
        ])
    var frames = WindowFrames()
    #expect(manager(room).apply(layout, frames: &frames) == LayoutPlacement(placed: 1, skipped: 1))
    #expect(room.frame(21) == first.frame(in: displayA.visibleBounds))
}

@Test func aWindowThatCantMoveIsSkipped() {
    let room = desk()
    room.windows[0].positionSettable = false
    room.windows[0].sizeSettable = false
    let layout = SavedWindowLayout(
        name: "One",
        windows: [
            SavedWindow(
                bundleId: "com.example.browser", index: 0, screen: SavedScreen(name: "Display A", index: 0),
                frame: left70)
        ])
    var frames = WindowFrames()
    #expect(manager(room).apply(layout, frames: &frames) == LayoutPlacement(placed: 0, skipped: 1))
    #expect(frames.frame(of: 21) == nil)
}

@Test func aSavedScreenIsFoundByNameThenByPlace() {
    let a = WindowScreen(id: 1, bounds: .zero, name: "Studio Display")
    let b = WindowScreen(id: 2, bounds: .zero, name: "Studio Display")
    let c = WindowScreen(id: 3, bounds: .zero, name: "Built-in Display")
    let screens = [a, b, c]
    #expect(SavedScreen(name: "Built-in Display", index: 0).match(in: screens) == c)
    #expect(SavedScreen(name: "Studio Display", index: 1).match(in: screens) == b, "two of one model: its place")
    #expect(SavedScreen(name: "Studio Display", index: 2).match(in: screens) == a, "else the first of them")
    #expect(SavedScreen(name: "Other", index: 2).match(in: screens) == c, "no such name: its place")
    #expect(SavedScreen(name: "Other", index: 7).match(in: screens) == a, "else the primary")
    #expect(SavedScreen(name: "", index: 1).match(in: screens) == b)
    #expect(SavedScreen(name: "Other", index: 0).match(in: []) == nil)
}

@Test func theHUDCountsPlacedAndSkippedWindows() {
    #expect(LayoutPlacement(placed: 5, skipped: 2).message == "Placed 5 windows; skipped 2")
    #expect(LayoutPlacement(placed: 1, skipped: 0).message == "Placed 1 window")
    #expect(LayoutPlacement(placed: 0, skipped: 1).message == "Placed 0 windows; skipped 1")
}

// MARK: - The file

private final class Folder {
    let url: URL
    var file: URL { url.appendingPathComponent("window-layouts.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fudge-window-layouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }
    func read() throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)) else {
            return [:]
        }
        return object
    }
}

private let windowEntry =
    #"{"bundleId":"com.example.editor","index":0,"screen":{"name":"Display A","index":0},"x":0,"y":0,"width":0.5,"height":1}"#

@Test func theStoreRoundTripsAndKeepsWhatItDoesntKnow() throws {
    let folder = try Folder()
    try folder.write(
        #"{"newer":true,"positions":[{"id":"p1","name":"Left 70%","x":0,"y":0,"width":0.7,"height":1,"color":"red"}],"#
            + #""layouts":[{"id":"l1","name":"Coding","createdAt":"2026-11-21T10:00:00Z","note":"mine","windows":["#
            + windowEntry + "]}]}")
    var store = WindowLayoutStore.load(from: folder.file)
    #expect(store.positions == [CustomWindowPosition(id: "p1", name: "Left 70%", frame: left70)])
    #expect(store.layouts.map(\.name) == ["Coding"] && store.layouts.first?.windows.count == 1)
    var edited = try #require(store.position(id: "p1"))
    edited.name = "Wide Left"
    store.replace(edited)
    store.renameLayout(id: "l1", to: "Writing")
    store.add(CustomWindowPosition(id: "p2", name: "Right 30%", frame: .init(x: 0.7, y: 0, width: 0.3, height: 1)))
    try store.save(to: folder.file)

    let object = try folder.read()
    #expect(object["newer"] == .bool(true))
    guard case .array(let positions) = object["positions"], case .array(let layouts) = object["layouts"],
        case .object(let first) = positions.first, case .object(let layout) = layouts.first
    else {
        Issue.record("not a layouts file")
        return
    }
    #expect(first["color"] == .string("red") && first["name"] == .string("Wide Left"))
    #expect(layout["note"] == .string("mine") && layout["name"] == .string("Writing"))
    let again = WindowLayoutStore.load(from: folder.file)
    #expect(again.positions.map(\.name) == ["Wide Left", "Right 30%"])
    #expect(again.layouts.first?.createdAt == "2026-11-21T10:00:00Z")
    #expect(again.removePositionKeepingCount(id: "p1") == 1)
}

extension WindowLayoutStore {
    fileprivate func removePositionKeepingCount(id: String) -> Int {
        var copy = self
        copy.removePosition(id: id)
        return copy.positions.count
    }
}

@Test func handEditedEntriesThatArentValidAreLeftOutAndKeptInTheFile() throws {
    let folder = try Folder()
    let badPositions = [
        #"{"id":"a","name":"Too far","x":1.2,"y":0,"width":0.5,"height":1}"#,
        #"{"id":"b","name":"No width","x":0,"y":0,"width":0,"height":1}"#,
        #"{"id":"c","name":"Past the edge","x":0.5,"y":0,"width":0.6,"height":1}"#,
        #"{"id":"Not Valid","name":"Bad id","x":0,"y":0,"width":0.5,"height":1}"#,
        #"{"id":"e","name":"","x":0,"y":0,"width":0.5,"height":1}"#,
        #"{"id":"f","name":"No height","x":0,"y":0,"width":0.5}"#,
        #"{"id":"g","name":"Negative","x":-0.1,"y":0,"width":0.5,"height":1}"#,
        #"{"id":"h","name":"Sliver","x":1,"y":0,"width":1e-12,"height":1}"#,
    ]
    let good = #"{"id":"ok","name":"Left 70%","x":0,"y":0,"width":0.7,"height":1}"#
    let mixed =
        #"{"id":"l1","name":"Mixed","windows":["# + windowEntry + ","
        + #"{"bundleId":"com.example.editor","index":-1,"screen":{"name":"A","index":0},"x":0,"y":0,"width":1,"height":1},"#
        + #"{"bundleId":"com.example.editor","index":1.5,"screen":{"name":"A","index":0},"x":0,"y":0,"width":1,"height":1},"#
        + #"{"bundleId":"com.example.editor","index":2,"x":0,"y":0,"width":1,"height":1},"#
        + #"{"bundleId":"","index":0,"screen":{"name":"A","index":0},"x":0,"y":0,"width":1,"height":1},"#
        + #"{"bundleId":"com.example.editor","index":3,"screen":{"name":"A","index":0},"x":0.5,"y":0,"width":0.6,"height":1}"#
        + "]}"
    let empty =
        #"{"id":"l2","name":"Nothing valid","windows":[{"bundleId":"com.example.editor","index":0,"screen":{"name":"A","index":0},"x":2,"y":0,"width":1,"height":1}]}"#
    try folder.write(
        #"{"positions":["# + (badPositions + [good]).joined(separator: ",") + #"],"layouts":["# + mixed + ","
            + empty + "]}")
    var store = WindowLayoutStore.load(from: folder.file)
    #expect(store.positions.map(\.id) == ["ok"])
    #expect(store.layouts.map(\.name) == ["Mixed"], "a layout with no valid window isn't one")
    #expect(store.layouts.first?.windows.count == 1, "its invalid windows are left out")
    #expect(store.layouts.flatMap(\.windows).allSatisfy { $0.frame.isValid })
    store.add(
        CustomWindowPosition(id: "new", name: "Right Third", frame: .init(x: 2 / 3, y: 0, width: 1 / 3, height: 1)))
    store.renameLayout(id: "l1", to: "Renamed")
    try store.save(to: folder.file)
    let object = try folder.read()
    guard case .array(let positions) = object["positions"], case .array(let layouts) = object["layouts"],
        case .object(let renamed) = layouts.first, case .array(let windows) = renamed["windows"]
    else {
        Issue.record("not a layouts file")
        return
    }
    #expect(positions.count == badPositions.count + 2, "the invalid ones are still there")
    #expect(layouts.count == 2 && windows.count == 6, "a rename leaves the windows as they were")
    #expect(WindowLayoutStore.load(from: folder.file).positions.map(\.id) == ["ok", "new"])
}

@Test func aFileThatIsntALayoutsObjectIsNeverOverwritten() throws {
    for text in [#"{"positions":"nope"}"#, #"{"layouts":{}}"#, "[1]", "not json"] {
        let folder = try Folder()
        try folder.write(text)
        let store = WindowLayoutStore.load(from: folder.file)
        #expect(store.positions.isEmpty && store.layouts.isEmpty)
        #expect(!WindowLayoutStore.isWritable(folder.file))
        var edited = store
        edited.add(CustomWindowPosition(name: "Left 70%", frame: left70))
        #expect(throws: WindowLayoutStore.Unreadable.self) { try edited.save(to: folder.file) }
        #expect(try String(contentsOf: folder.file, encoding: .utf8) == text)
    }
    let folder = try Folder()
    #expect(WindowLayoutStore.isWritable(folder.file), "a missing file is an empty one")
    try folder.write("  \n")
    #expect(WindowLayoutStore.isWritable(folder.file), "and so is a blank one")
}

// MARK: - The commands

@Test func theGroupGainsSaveLayoutThePositionsAndTheLayouts() throws {
    let right = CustomWindowPosition(id: "r", name: "Right 30%", frame: .init(x: 0.7, y: 0, width: 0.3, height: 1))
    let left = CustomWindowPosition(id: "l", name: "Left 70%", frame: left70)
    let coding = SavedWindowLayout(
        id: "c", name: "Coding",
        windows: [
            SavedWindow(
                bundleId: "com.example.editor", index: 0, screen: SavedScreen(name: "A", index: 0), frame: left70)
        ])
    var store = WindowLayoutStore(positions: [right, left], layouts: [coding])
    let group = try #require(
        BuiltInCommandGroup.all(with: store).first { $0.name == BuiltInCommandGroup.windowManagement.name })
    let added = Array(group.commands.dropFirst(BuiltInCommandGroup.windowManagement.commands.count))
    #expect(added.map(\.name) == ["save-layout", "position-l", "position-r", "layout-c"])
    #expect(added.map(\.title) == ["Save Layout…", "Left 70%", "Right 30%", "Apply Coding"])
    #expect(added.allSatisfy { $0.keywords.contains("window") })
    for command in added {
        #expect(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil, "\(command.symbol)")
        #expect(ExtensionManifest.isValidName(command.name))
    }
    #expect(
        BuiltInCommandGroup.commandIDs(in: BuiltInCommandGroup.all(with: store)).contains(
            ":window-management/position-l"))
    #expect(store.command(named: "save-layout") == .saveLayout)
    #expect(store.command(named: "position-r") == .position(right))
    #expect(store.command(named: "layout-c") == .layout(coding))
    #expect(store.command(named: "left-half") == nil && store.command(named: "position-x") == nil)
    let found = RootSearch.rank(RootItem.builtInCommands(of: group), query: "coding", history: LaunchHistory())
    #expect(found.first?.title == "Apply Coding")

    // A deleted position's command goes; the fixed commands stay as they are.
    store.removePosition(id: "r")
    let after = try #require(
        BuiltInCommandGroup.all(with: store).first { $0.name == BuiltInCommandGroup.windowManagement.name })
    #expect(!after.commands.contains { $0.name == "position-r" })
    #expect(
        Array(after.commands.prefix(WindowCommand.allCases.count)).map(\.name) == WindowCommand.allCases.map(\.rawValue)
    )
    #expect(
        BuiltInCommandGroup.all(with: WindowLayoutStore()).flatMap(\.commands).map(\.name)
            == BuiltInCommandGroup.all.flatMap(\.commands).map(\.name) + ["save-layout"])
}

// MARK: - Editing

@Test func aPositionDraftSaysWhatsWrong() {
    let existing = [CustomWindowPosition(id: "p1", name: "Left 70%", frame: left70)]
    #expect(PositionDraft().problems(among: existing) == .init(name: "Enter a name."))
    #expect(
        PositionDraft(name: " left 70% ").problems(among: existing).name == "Another position is called “left 70%”.")
    var editing = PositionDraft(editing: existing[0])
    #expect(editing.problems(among: existing).isEmpty, "it may keep its own name")
    editing.name = String(repeating: "x", count: 65)
    #expect(editing.problems(among: existing).name == "Use at most 64 characters, on one line.")
    func frameProblem(_ x: String, _ y: String, _ width: String, _ height: String) -> String? {
        PositionDraft(name: "New", x: x, y: y, width: width, height: height).problems(among: existing).frame
    }
    #expect(frameProblem("abc", "0", "50", "100") == "Each value is a percentage from 0 to 100.")
    #expect(frameProblem("120", "0", "50", "100") == "Each value is a percentage from 0 to 100.")
    #expect(frameProblem("0", "-5", "50", "100") == "Each value is a percentage from 0 to 100.")
    #expect(frameProblem("0", "0", "0", "100") == "Width and height must each be at least 5%.")
    #expect(frameProblem("99.99", "0", "0.01", "100") == "Width and height must each be at least 5%.", "#124's note")
    #expect(frameProblem("0", "0", "50", "4.9") == "Width and height must each be at least 5%.")
    #expect(frameProblem("95", "95", "5", "5") == nil)
    #expect(frameProblem("50", "0", "60", "100") == "It must fit on the screen: X + Width and Y + Height at most 100%.")
    #expect(frameProblem("70 %", "0", "30%", "100") == nil)
    #expect(frameProblem("33,5", "0", "66.5", "100") == nil, "a decimal comma reads too")
}

@Test func aPositionDraftShowsAndSavesPercentages() throws {
    #expect(PositionDraft.percent(0.7) == "70")
    #expect(PositionDraft.percent(1.0 / 3) == "33.33")
    #expect(PositionDraft.percent(0.125) == "12.5")
    #expect(PositionDraft.percent(0) == "0")
    var store = WindowLayoutStore()
    let saved = try #require(PositionDraft(name: " Left 70% ", width: "70").save(into: &store))
    #expect(saved.name == "Left 70%" && saved.frame == left70)
    #expect(ExtensionManifest.isValidName(saved.commandName))
    var editing = PositionDraft(editing: saved)
    #expect(editing.width == "70" && editing.height == "100")
    editing.width = "60"
    editing.save(into: &store)
    #expect(store.positions.count == 1 && store.positions.first?.id == saved.id)
    #expect(store.positions.first?.frame.width == 0.6)
}

@Test func aLayoutDraftNamesAndSavesALayout() throws {
    let windows = [
        SavedWindow(bundleId: "com.example.editor", index: 0, screen: SavedScreen(name: "A", index: 0), frame: left70),
        SavedWindow(bundleId: "com.example.editor", index: 1, screen: SavedScreen(name: "A", index: 0), frame: left70),
        SavedWindow(bundleId: "com.example.browser", index: 0, screen: SavedScreen(name: "B", index: 1), frame: left70),
    ]
    var store = WindowLayoutStore()
    var draft = LayoutDraft(windows: windows)
    #expect(draft.summary == "3 windows of 2 apps")
    #expect(LayoutDraft(windows: Array(windows.prefix(1))).summary == "1 window of 1 app")
    #expect(draft.problem(among: store.layouts) == "Enter a name.")
    draft.name = " Coding "
    #expect(draft.problem(among: store.layouts) == nil)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    draft.save(into: &store, now: now)
    let layout = try #require(store.layouts.first)
    #expect(layout.name == "Coding" && layout.windows == windows && layout.createdAt == now.formatted(.iso8601))
    #expect(
        LayoutDraft(name: "coding", windows: windows).problem(among: store.layouts)
            == "Another layout is called “coding”.")
    var rename = LayoutDraft(renaming: layout)
    #expect(rename.problem(among: store.layouts) == nil)
    rename.name = "Writing"
    rename.save(into: &store)
    #expect(store.layouts.map(\.name) == ["Writing"] && store.layouts.first?.windows == windows)
}

@Test func theSaveLayoutFormHasANameAndWhatItSaves() {
    let windows = [
        SavedWindow(bundleId: "com.example.editor", index: 0, screen: SavedScreen(name: "A", index: 0), frame: left70)
    ]
    let content = FormContent(LayoutForm.view(draft: LayoutDraft(windows: windows), problem: "Enter a name."))
    #expect(content.fields.map(\.kind) == [.textField, .description])
    #expect(content.fields[0].fieldId == LayoutForm.Field.name && content.fields[0].error == "Enter a name.")
    #expect(content.fields[1].text == "1 window of 1 app")
    let draft = LayoutForm.draft(LayoutDraft(windows: windows), with: [LayoutForm.Field.name: .string("Desk")])
    #expect(draft.name == "Desk" && draft.windows == windows)
}
