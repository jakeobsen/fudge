import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

/// #3A7BD5, as bytes 58, 123, 213.
private let blue = PickedColor(red: 58 / 255, green: 123 / 255, blue: 213 / 255)
private let now = Date(timeIntervalSince1970: 1_795_255_200)

/// A color's bytes as a list, which `#expect` can compare.
private func bytes(_ color: PickedColor) -> [Int] {
    let bytes = color.bytes
    return [bytes.red, bytes.green, bytes.blue, bytes.alpha]
}

// MARK: - Formats

@Test func eachFormatWritesAnOpaqueColor() {
    #expect(ColorFormat.hex.string(for: blue) == "#3A7BD5")
    #expect(ColorFormat.rgb.string(for: blue) == "rgb(58, 123, 213)")
    #expect(ColorFormat.hsl.string(for: blue) == "hsl(215, 65%, 53%)")
    #expect(ColorFormat.swiftUI.string(for: blue) == "Color(red: 0.227, green: 0.482, blue: 0.835)")
    #expect(ColorFormat.uiColor.string(for: blue) == "UIColor(red: 0.227, green: 0.482, blue: 0.835, alpha: 1)")
}

@Test func eachFormatWritesAlphaWhenTheColorHasSome() {
    var half = blue
    half.alpha = 0.5
    #expect(ColorFormat.hex.string(for: half) == "#3A7BD580")
    #expect(ColorFormat.rgb.string(for: half) == "rgba(58, 123, 213, 0.502)")
    #expect(ColorFormat.hsl.string(for: half) == "hsla(215, 65%, 53%, 0.502)")
    #expect(ColorFormat.swiftUI.string(for: half) == "Color(red: 0.227, green: 0.482, blue: 0.835, opacity: 0.502)")
    #expect(ColorFormat.uiColor.string(for: half) == "UIColor(red: 0.227, green: 0.482, blue: 0.835, alpha: 0.502)")
    var clear = blue
    clear.alpha = 0
    #expect(ColorFormat.hex.string(for: clear) == "#3A7BD500")
    #expect(ColorFormat.rgb.string(for: clear) == "rgba(58, 123, 213, 0)")
}

@Test func componentsRoundToTheNearestByte() {
    // 127.5 rounds up; just under it rounds down.
    #expect(bytes(PickedColor(red: 0.5, green: 127.4 / 255, blue: 0.999)) == [128, 127, 255, 255])
    #expect(ColorFormat.hex.string(for: PickedColor(red: 0.5, green: 127.4 / 255, blue: 0.999)) == "#807FFF")
    // An alpha that rounds to 255 is opaque, so no alpha is written.
    #expect(ColorFormat.rgb.string(for: PickedColor(red: 0, green: 0, blue: 0, alpha: 0.999)) == "rgb(0, 0, 0)")
}

@Test func decimalsHaveAtMostThreePlacesAndNoTrailingZeros() {
    #expect(ColorFormat.decimal(0) == "0")
    #expect(ColorFormat.decimal(255) == "1")
    #expect(ColorFormat.decimal(51) == "0.2")
    #expect(ColorFormat.decimal(128) == "0.502")
    #expect(ColorFormat.decimal(1) == "0.004")
}

@Test func hslCoversGraysPrimariesAndTheWrapAt360() {
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 1, green: 0, blue: 0)) == "hsl(0, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 0, green: 1, blue: 0)) == "hsl(120, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 0, green: 0, blue: 1)) == "hsl(240, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 1, green: 1, blue: 1)) == "hsl(0, 0%, 100%)")
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 0, green: 0, blue: 0)) == "hsl(0, 0%, 0%)")
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 0.5, green: 0.5, blue: 0.5)) == "hsl(0, 0%, 50%)")
    // A hue of 359.5° rounds to 360, which is 0.
    #expect(ColorFormat.hsl.string(for: PickedColor(red: 1, green: 0, blue: 2 / 255)) == "hsl(0, 100%, 50%)")
}

@Test func hexAndRGBReadBackAsTheSameColor() throws {
    // Fudge's own color reader (ExtensionColor, used for extensions' colors) reads what each format writes.
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let color = PickedColor(
            red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
            blue: .random(in: 0...1, using: &generator), alpha: .random(in: 0...1, using: &generator))
        for format in [ColorFormat.hex, .rgb] {
            let parsed = try #require(ExtensionColor(format.string(for: color)))
            guard case .rgb(let r, let g, let b, let a) = parsed else {
                Issue.record("\(format.string(for: color)) isn't read as a color")
                continue
            }
            let read = PickedColor(red: r, green: g, blue: b, alpha: a)
            #expect(read.bytes.red == color.bytes.red && read.bytes.green == color.bytes.green)
            #expect(read.bytes.blue == color.bytes.blue)
            // rgba's alpha has three decimals, so it's within a byte.
            #expect(abs(read.bytes.alpha - color.bytes.alpha) <= (format == .hex ? 0 : 1))
        }
    }
}

@Test func hslIsRoundedToWholeDegreesAndPercent() throws {
    // As CSS writes it, so it can read back a little off: #3A7BD5 is hsl(215, 65%, 53%), which reads as #397AD5.
    let parsed = try #require(ExtensionColor(ColorFormat.hsl.string(for: blue)))
    guard case .rgb(let r, let g, let b, _) = parsed else {
        Issue.record("not read as a color")
        return
    }
    #expect(ColorFormat.hex.string(for: PickedColor(red: r, green: g, blue: b)) == "#397AD5")
    // Never more than 5 off on a channel (the review measured 636,056 colors).
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
        let color = PickedColor(
            red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
            blue: .random(in: 0...1, using: &generator))
        guard case .rgb(let r, let g, let b, _) = try #require(ExtensionColor(ColorFormat.hsl.string(for: color)))
        else { continue }
        let read = PickedColor(red: r, green: g, blue: b).bytes
        let bytes = color.bytes
        #expect(max(abs(read.red - bytes.red), abs(read.green - bytes.green), abs(read.blue - bytes.blue)) <= 5)
    }
}

// MARK: - sRGB

@Test func componentsAreClampedAndNaNIsZero() {
    let color = PickedColor(red: 1.2, green: -0.1, blue: .nan, alpha: 2)
    #expect(color == PickedColor(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(color.red == 1 && color.green == 0 && color.blue == 0 && color.alpha == 1)
}

/// Display P3 to sRGB by hand: both use sRGB's transfer curve and D65, so it's linear P3 times this matrix.
private func p3ToSRGB(_ p3: [Double]) -> [Double] {
    func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func encoded(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    let l = p3.map(linear)
    let matrix = [
        [1.224_940_2, -0.224_940_2, 0], [-0.042_056_9, 1.042_056_9, 0], [-0.019_637_6, -0.078_636_1, 1.098_273_7],
    ]
    return matrix.map { row in encoded(row[0] * l[0] + row[1] * l[1] + row[2] * l[2]) }
}

@Test func aDisplayP3ColorIsConvertedToSRGB() throws {
    // macOS's loupe gives the display's color space, often Display P3.
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let input = [0.2, 0.4, 0.8]
    let cgColor = try #require(CGColor(colorSpace: p3, components: input.map { CGFloat($0) } + [1]))
    let color = try #require(PickedColor(cgColor: cgColor))
    let expected = p3ToSRGB(input)
    #expect(abs(color.red - expected[0]) < 0.002)
    #expect(abs(color.green - expected[1]) < 0.002)
    #expect(abs(color.blue - expected[2]) < 0.002)
    #expect(color.alpha == 1)
    #expect(ColorFormat.hex.string(for: color) == "#1B68D3", "not the P3 numbers read as sRGB (#3366CC)")
}

@Test func aP3ColorSRGBCantShowIsClampedIntoIt() throws {
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let p3Red = try #require(CGColor(colorSpace: p3, components: [1, 0, 0, 1]))
    let red = try #require(PickedColor(cgColor: p3Red))
    // Outside sRGB: unclamped it would be about (1.09, -0.23, -0.15).
    #expect(p3ToSRGB([1, 0, 0])[0] > 1 && p3ToSRGB([1, 0, 0])[1] < 0)
    #expect(bytes(red) == [255, 0, 0, 255])
    let extended = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
    let wideColor = try #require(CGColor(colorSpace: extended, components: [1.2, -0.1, 0.5, 1]))
    let wide = try #require(PickedColor(cgColor: wideColor))
    #expect([wide.red, wide.green, wide.blue].allSatisfy { (0...1).contains($0) })
    #expect(bytes(wide) == [255, 0, 128, 255])
}

@Test func aGrayOrSRGBColorKeepsItsComponents() throws {
    let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
    let grayColor = try #require(CGColor(colorSpace: gray, components: [1, 0.5]))
    let color = try #require(PickedColor(cgColor: grayColor))
    #expect(bytes(color) == [255, 255, 255, 128])
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let sRGBColor = try #require(CGColor(colorSpace: sRGB, components: [0.2, 0.4, 0.8, 1]))
    let same = try #require(PickedColor(cgColor: sRGBColor))
    #expect(ColorFormat.hex.string(for: same) == "#3366CC")
}

// MARK: - Recent Colors' file

private func temporaryFile() throws -> URL {
    try Fixtures.temporaryDirectory().appendingPathComponent("colors.json")
}

@Test func aPickedColorGoesFirstAndIsSavedInSRGB() throws {
    let file = try temporaryFile()
    var store = RecentColorStore.load(from: file)
    store.add(PickedColor(red: 1, green: 0, blue: 0), id: "red", now: now)
    store.add(blue, id: "blue", now: now.addingTimeInterval(60))
    try store.save(to: file)
    let read = RecentColorStore.load(from: file)
    #expect(read.colors.map(\.id) == ["blue", "red"], "newest first")
    #expect(read.colors.first?.color == blue)
    #expect(read.colors.first?.pickedAt == "2026-11-21T10:01:00Z")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let first = try #require((json?["colors"] as? [[String: Any]])?.first)
    #expect(first["red"] as? Double == 58.0 / 255 && first["alpha"] as? Double == 1)
}

@Test func theSameColorPickedAgainMovesUpInsteadOfShowingTwice() {
    var store = RecentColorStore()
    store.add(blue, id: "first", now: now)
    store.add(PickedColor(red: 1, green: 1, blue: 1), id: "white", now: now)
    // The same bytes, a hair apart: the same in every format.
    store.add(PickedColor(red: 58.2 / 255, green: 123 / 255, blue: 213 / 255), id: "again", now: now)
    #expect(store.colors.map(\.id) == ["again", "white"])
}

@Test func itKeepsTheNewest32() {
    var store = RecentColorStore()
    for index in 0..<40 {
        store.add(PickedColor(red: Double(index) / 255, green: 0, blue: 0), id: "c\(index)", now: now)
    }
    #expect(store.colors.count == RecentColorStore.limit)
    #expect(RecentColorStore.limit == 32)
    #expect(store.colors.first?.id == "c39")
    #expect(store.colors.last?.id == "c8", "the oldest eight went")
}

@Test func colorsAreRemovedOneAtATimeOrCleared() {
    var store = RecentColorStore()
    store.add(blue, id: "blue", now: now)
    store.add(PickedColor(red: 1, green: 0, blue: 0), id: "red", now: now)
    let removed = store.remove(id: "blue")
    let removedAgain = store.remove(id: "blue")
    #expect(removed && !removedAgain)
    #expect(store.colors.map(\.id) == ["red"])
    store.clear()
    #expect(store.colors.isEmpty)
}

@Test func theFileKeepsWhatFudgeDoesntKnow() throws {
    let file = try temporaryFile()
    try #"""
    {"note":"mine","colors":[{"id":"a","red":0,"green":0,"blue":1,"label":"Sky"},{"id":"bad","red":"x"},
     {"id":"b","red":2,"green":-1,"blue":0.5,"alpha":0.25}]}
    """#.write(to: file, atomically: true, encoding: .utf8)
    var store = RecentColorStore.load(from: file)
    #expect(store.colors.map(\.id) == ["a", "b"])
    #expect(store.color(id: "b")?.color == PickedColor(red: 1, green: 0, blue: 0.5, alpha: 0.25), "clamped")
    #expect(store.color(id: "a")?.color.alpha == 1, "alpha is 1 unless given")
    store.remove(id: "b")
    try store.save(to: file)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(json?["note"] as? String == "mine")
    let colors = try #require(json?["colors"] as? [[String: Any]])
    #expect(colors.count == 2, "the invalid entry stays")
    #expect(colors.first?["label"] as? String == "Sky")
}

@Test func aFileFudgeCantReadIsNeverOverwritten() throws {
    let file = try temporaryFile()
    try "[1, 2]".write(to: file, atomically: true, encoding: .utf8)
    #expect(!RecentColorStore.isWritable(file))
    var store = RecentColorStore.load(from: file)
    #expect(store.colors.isEmpty)
    store.add(blue, now: now)
    #expect(throws: RecentColorStore.Unreadable.self) { try store.save(to: file) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "[1, 2]")
    let missing = try temporaryFile()
    #expect(RecentColorStore.isWritable(missing), "a missing file is fine")
}

// MARK: - Pick Color

private final class FakeSampler: ColorSampling, @unchecked Sendable {
    let color: PickedColor?
    private(set) var shown = 0
    init(_ color: PickedColor?) { self.color = color }
    func sample() async -> PickedColor? {
        shown += 1
        return color
    }
}

private actor Copies {
    var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

@Test func pickingCopiesInTheCopyFormatAndKeepsTheColor() async throws {
    let file = try temporaryFile()
    let copies = Copies()
    let sampler = FakeSampler(blue)
    let pick = ColorPick(
        sampler: sampler,
        copy: {
            await copies.add($0)
            return true
        }, file: file)
    #expect(await pick.run(format: .hex, now: { now }) == "Copied #3A7BD5")
    #expect(await pick.run(format: .rgb, now: { now }) == "Copied rgb(58, 123, 213)")
    #expect(await copies.texts == ["#3A7BD5", "rgb(58, 123, 213)"])
    #expect(sampler.shown == 2)
    #expect(RecentColorStore.load(from: file).colors.map(\.color) == [blue], "picked twice, kept once")
}

@Test func escCopiesAndKeepsNothing() async throws {
    let file = try temporaryFile()
    let copies = Copies()
    let pick = ColorPick(
        sampler: FakeSampler(nil),
        copy: {
            await copies.add($0)
            return true
        }, file: file)
    #expect(await pick.run(format: .hex) == nil, "no HUD")
    #expect(await copies.texts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func aColorRecentColorsCantSaveIsStillCopied() async throws {
    let file = try temporaryFile()
    try "not json".write(to: file, atomically: true, encoding: .utf8)
    let copies = Copies()
    let pick = ColorPick(
        sampler: FakeSampler(blue),
        copy: {
            await copies.add($0)
            return true
        }, file: file)
    #expect(await pick.run(format: .hex) == "Copied #3A7BD5, but Recent Colors can't be saved")
    #expect(await copies.texts == ["#3A7BD5"])
    #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
}

@Test func aFailedCopyIsntKept() async throws {
    let file = try temporaryFile()
    let pick = ColorPick(sampler: FakeSampler(blue), copy: { _ in false }, file: file)
    #expect(await pick.run(format: .hex) == "Couldn't copy #3A7BD5")
    #expect(RecentColorStore.load(from: file).colors.isEmpty)
}

@Test func theInertSamplerPicksNothing() async {
    #expect(await InertColorSampler().sample() == nil)
}

// MARK: - The Tools group

@Test func theToolsGroupHasPickColorAndRecentColors() {
    let tools = BuiltInCommandGroup.tools
    #expect(BuiltInCommandGroup.all.contains(tools))
    #expect(BuiltInCommandGroup.isValidName(tools.name))
    #expect(tools.title == "Tools")
    #expect(tools.commands.map(\.title) == ["Pick Color", "Recent Colors"])
    #expect(tools.commands.map(tools.commandID) == [":tools/pick-color", ":tools/recent-colors"])
    #expect(BuiltInCommandGroup.command(group: ":tools", command: "pick-color")?.command.symbol == "eyedropper")
}

// MARK: - Copy Format

@Test func theCopyFormatIsHEXUntilSetAndOnlyWrittenWhenChanged() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    #expect(FudgeSettings.load(from: file).colorFormat == .hex)
    var settings = FudgeSettings()
    settings.colorFormat = .uiColor
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).colorFormat == .uiColor)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(saved?["colorFormat"] as? String == "uicolor")
    settings.colorFormat = .hex
    try settings.save(to: file)
    let cleared = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(cleared != nil && cleared?["colorFormat"] == nil)
    try #"{"colorFormat":"cmyk"}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(FudgeSettings.load(from: file).colorFormat == .hex, "an unknown value reads as HEX")
    #expect(ColorFormat.allCases.map(\.title) == ["HEX", "RGB", "HSL", "SwiftUI", "UIColor"])
}

// MARK: - The grid

private let colors = [
    RecentColor(id: "blue", color: blue),
    RecentColor(id: "red", color: PickedColor(red: 1, green: 0, blue: 0, alpha: 0.5)),
]

@Test func recentColorsIsAGridOfSwatchesNewestFirst() throws {
    let list = ListContent(RecentColorsGrid.view(colors: colors, format: .hex), searchText: "")
    guard case .grid(let layout) = list.layout else {
        Issue.record("not a grid")
        return
    }
    #expect(layout.columns == 8)
    #expect(list.items.map(\.title) == ["#3A7BD5", "#FF000080"])
    #expect(list.items.map(\.itemId) == ["blue", "red"], "the selection follows a color across renders")
    #expect(
        list.items.map(\.content) == [
            GridItemContent(kind: .color(.string("#3A7BD5"))), GridItemContent(kind: .color(.string("#FF000080"))),
        ])
    var searched = list
    searched.search("FF00")
    #expect(searched.items.map(\.itemId) == ["red"])
}

@Test func returnCopiesInTheCopyFormatAndCommandKOffersEveryFormat() throws {
    for format in ColorFormat.allCases {
        let list = ListContent(RecentColorsGrid.view(colors: colors, format: format), searchText: "")
        let first = try #require(list.items.first)
        let entries = ActionPanelReader.sections(of: first.actions).flatMap(\.entries)
        #expect(entries.first?.title == "Copy \(format.title)", "↵ runs the first action")
        let targets = entries.map { entry -> RecentColorsGrid.Target? in
            guard case .node(let node) = entry.target else { return nil }
            return RecentColorsGrid.target(of: node, in: colors)
        }
        let copies = targets.prefix(5).compactMap { target -> ColorFormat? in
            if case .copy("blue", let format) = target { format } else { nil }
        }
        #expect(copies.first == format)
        #expect(Set(copies) == Set(ColorFormat.allCases), "each format once")
        #expect(entries.prefix(5).map(\.title) == copies.map { "Copy \($0.title)" })
        #expect(Array(targets.suffix(2)) == [.remove(id: "blue"), .clear])
        #expect(entries.suffix(2).map(\.title) == ["Remove Color", "Clear Recent Colors…"])
        #expect(
            entries.suffix(2).map(\.shortcut) == [RecentColorsGrid.removeShortcut, RecentColorsGrid.clearShortcut])
        #expect(entries.suffix(2).filter(\.destructive).count == 2)
    }
    #expect(RecentColorsGrid.removeShortcut == KeyShortcut(key: "x", modifiers: ["ctrl"]))
    #expect(RecentColorsGrid.clearShortcut == KeyShortcut(key: "x", modifiers: ["ctrl", "shift"]))
}

@Test func theSecondColorsActionsNameIt() throws {
    let list = ListContent(RecentColorsGrid.view(colors: colors, format: .hex), searchText: "")
    let second = try #require(list.items.last)
    let entries = ActionPanelReader.sections(of: second.actions).flatMap(\.entries)
    guard case .node(let node) = try #require(entries.first).target else {
        Issue.record("not a node")
        return
    }
    #expect(RecentColorsGrid.target(of: node, in: colors) == .copy(id: "red", format: .hex))
    #expect(RecentColorsGrid.target(of: second.id, in: colors) == nil, "the item itself runs nothing")
    #expect(RecentColorsGrid.target(of: 100 + 20 * 2 + 3, in: colors) == nil, "past the last color")
    #expect(RecentColorsGrid.target(of: 100 + 9, in: colors) == nil, "between the sections")
}

@Test func withNoColorsItOffersPickColor() throws {
    let list = ListContent(RecentColorsGrid.view(colors: [], format: .hex), searchText: "")
    #expect(list.items.isEmpty)
    let empty = try #require(list.emptyView)
    #expect(empty.title == "No Recent Colors")
    let pick = try #require(ActionPanelReader.sections(of: empty.actions).first?.entries.first)
    #expect(pick.title == "Pick Color")
    guard case .node(let node) = pick.target else {
        Issue.record("not a node")
        return
    }
    #expect(RecentColorsGrid.target(of: node, in: []) == .pick)
}
