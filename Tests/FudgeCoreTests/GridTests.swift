import Foundation
import Testing

@testable import FudgeCore

private func node(_ json: String) throws -> UINode {
    try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
}

/// A grid shaped like an emoji or wallpaper picker: Grid-wide layout, two sections (one overriding it), loose items
/// before them, every kind of `content`, an empty view and a search bar dropdown.
private let pictures = #"""
    {"id":1,"type":"Grid","props":{"columns":4,"aspectRatio":"16/9","fit":"fill","inset":"md",
      "searchBarAccessory":{"id":80,"type":"Grid.Dropdown","props":{"tooltip":"Kind"},"children":[
        {"id":81,"type":"Grid.Dropdown.Item","props":{"title":"All","value":"all"},"children":[]}]}},"children":[
      {"id":2,"type":"Grid.EmptyView","props":{"title":"No pictures"},"children":[]},
      {"id":3,"type":"Grid.Item","props":{"title":"Loose","content":"🙂"},"children":[]},
      {"id":4,"type":"Grid.Section","props":{"title":"Photos","subtitle":"3"},"children":[
        {"id":5,"type":"Grid.Item","props":{"id":"dunes","title":"Dunes","subtitle":"Namib",
          "keywords":["desert","sand"],"content":"/tmp/dunes.jpg",
          "accessory":{"icon":"star-16","tooltip":"Favourite"},
          "actions":{"id":90,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
        {"id":6,"type":"Grid.Item","props":{"title":"Coast","content":{"value":{"source":"coast.png","tintColor":"red"},
          "tooltip":"The coast at dawn"}},"children":[]},
        {"id":7,"type":"Grid.Item","props":{"title":"Forest","content":{"fileIcon":"/tmp/forest"}},"children":[]}
      ]},
      {"id":8,"type":"Grid.Section","props":{"title":"Colors","columns":8,"aspectRatio":"1","fit":"contain",
        "inset":"zero"},"children":[
        {"id":9,"type":"Grid.Item","props":{"title":"Red","content":{"color":"#ff0000"}},"children":[]},
        {"id":10,"type":"Grid.Item","props":{"title":"Blue","content":{"value":{"color":"raycast-blue"},
          "tooltip":"Raycast blue"}},"children":[]},
        {"id":11,"type":"List.Item","props":{"title":"Not a grid item"},"children":[]}
      ]},
      {"id":12,"type":"Grid.Section","props":{"title":"Empty"},"children":[]}
    ]}
    """#

@Test func readsAGridAsListContentWithItsLayout() throws {
    let grid = ListContent(try node(pictures), searchText: "")
    let shared = GridSectionLayout(columns: 4, aspectRatio: 16.0 / 9, fit: .fill, inset: .medium)
    #expect(grid.layout == .grid(shared))
    #expect(grid.sections.map(\.title) == [nil, "Photos", "Colors"], "loose items first; the empty section is dropped")
    #expect(grid.sections.map(\.grid) == [shared, shared, GridSectionLayout(columns: 8)])
    #expect(grid.sections[1].subtitle == "3")
    #expect(grid.items.map(\.title) == ["Loose", "Dunes", "Coast", "Forest", "Red", "Blue"], "only Grid.Items")
    #expect(!grid.isShowingDetail)
    #expect(grid.emptyView == nil)
    #expect(grid.dropdown?.id == 80)

    let dunes = grid.items[1]
    #expect(dunes.itemId == "dunes")
    #expect(dunes.subtitle == "Namib")
    #expect(dunes.keywords == ["desert", "sand"])
    #expect(dunes.actions?.id == 90)
    #expect(dunes.icon == nil)
    #expect(
        dunes.accessories == [
            ListContent.Accessory(text: nil, isTag: false, color: nil, icon: .string("star-16"), tooltip: "Favourite")
        ])
}

@Test func readsEachKindOfGridContent() throws {
    let items = ListContent(try node(pictures), searchText: "").items
    #expect(items[0].content == GridItemContent(kind: .image(.string("🙂"))))
    #expect(items[1].content == GridItemContent(kind: .image(.string("/tmp/dunes.jpg"))))
    #expect(
        items[2].content
            == GridItemContent(
                kind: .image(.object(["source": .string("coast.png"), "tintColor": .string("red")])),
                tooltip: "The coast at dawn"))
    #expect(items[3].content == GridItemContent(kind: .image(.object(["fileIcon": .string("/tmp/forest")]))))
    #expect(items[4].content == GridItemContent(kind: .color(.string("#ff0000"))))
    #expect(items[5].content == GridItemContent(kind: .color(.string("raycast-blue")), tooltip: "Raycast blue"))
    #expect(GridItemContent(nil) == nil)
    #expect(GridItemContent(.null) == nil)
    #expect(GridItemContent(.object(["color": .null])) == nil)
}

@Test func aGridFiltersAndShowsItsEmptyViewAsAListDoes() throws {
    let grid = ListContent(try node(pictures), searchText: "sand")
    #expect(grid.items.map(\.title) == ["Dunes"], "matched by keyword")
    #expect(
        grid.sections.map(\.grid) == [GridSectionLayout(columns: 4, aspectRatio: 16.0 / 9, fit: .fill, inset: .medium)])

    let none = ListContent(try node(pictures), searchText: "zzzz")
    #expect(none.items.isEmpty)
    #expect(none.emptyView?.title == "No pictures")

    let reordered = ListContent(try node(pictures), searchText: "blue")
    #expect(reordered.sections.map(\.title) == ["Colors"])
}

@Test func gridLayoutDefaultsAndItemSizes() throws {
    let plain = try node(#"{"id":1,"type":"Grid","props":{},"children":[]}"#)
    #expect(
        GridSectionLayout(grid: plain) == GridSectionLayout(columns: 5, aspectRatio: 1, fit: .contain, inset: .zero))

    for (size, columns) in [("small", 8), ("medium", 5), ("large", 3)] {
        let sized = try node(#"{"id":1,"type":"Grid","props":{"itemSize":"\#(size)"},"children":[]}"#)
        #expect(GridSectionLayout(grid: sized).columns == columns)
    }
    let both = try node(#"{"id":1,"type":"Grid","props":{"itemSize":"small","columns":2},"children":[]}"#)
    #expect(GridSectionLayout(grid: both).columns == 2, "columns wins over the deprecated itemSize")

    for (columns, clamped) in [(0, 1), (-3, 1), (9, 8), (3, 3)] {
        let odd = try node(#"{"id":1,"type":"Grid","props":{"columns":\#(columns)},"children":[]}"#)
        #expect(GridSectionLayout(grid: odd).columns == clamped)
    }
    let unknown = try node(
        #"{"id":1,"type":"Grid","props":{"fit":"stretch","inset":"xl","aspectRatio":"2/1"},"children":[]}"#)
    #expect(GridSectionLayout(grid: unknown) == GridSectionLayout(), "unknown values keep the defaults")
}

@Test func aSectionOverridesOnlyWhatItSets() throws {
    let grid = GridSectionLayout(columns: 3, aspectRatio: 4.0 / 3, fit: .fill, inset: .large)
    let section = try node(#"{"id":2,"type":"Grid.Section","props":{"columns":6},"children":[]}"#)
    #expect(
        grid.overridden(by: section) == GridSectionLayout(columns: 6, aspectRatio: 4.0 / 3, fit: .fill, inset: .large))
    let ratio = try node(#"{"id":2,"type":"Grid.Section","props":{"aspectRatio":"9/16","inset":"sm"},"children":[]}"#)
    #expect(
        grid.overridden(by: ratio) == GridSectionLayout(columns: 3, aspectRatio: 9.0 / 16, fit: .fill, inset: .small))
}

@Test func everyAspectRatio() {
    let expected: [String: Double] = [
        "1": 1, "3/2": 1.5, "2/3": 2.0 / 3, "4/3": 4.0 / 3, "3/4": 0.75, "16/9": 16.0 / 9, "9/16": 0.5625,
    ]
    for (text, ratio) in expected { #expect(GridSectionLayout.aspectRatio(text) == ratio) }
    #expect(GridSectionLayout.aspectRatio("2/1") == nil)
    #expect(GridSectionLayout.aspectRatio(nil) == nil)
}

@Test func insetPointsScaleWithTheColumns() {
    #expect(GridSectionLayout(columns: 5, inset: .zero).insetPoints == 0)
    #expect(GridSectionLayout(columns: 1, inset: .zero).insetPoints == 0)
    #expect(GridSectionLayout(columns: 5, inset: .small).insetPoints == 6)
    #expect(GridSectionLayout(columns: 5, inset: .medium).insetPoints == 12)
    #expect(GridSectionLayout(columns: 5, inset: .large).insetPoints == 20)
    #expect(GridSectionLayout(columns: 8, inset: .medium).insetPoints == 7.5)
    #expect(GridSectionLayout(columns: 4, inset: .medium).insetPoints == 15)
    #expect(GridSectionLayout(columns: 1, inset: .large).insetPoints == 100)
    #expect(
        GridSectionLayout(columns: 4, inset: .small).insetPoints == 2
            * GridSectionLayout(columns: 8, inset: .small).insetPoints)
}

// MARK: - Navigation

private typealias Section = GridNavigation.Section

private func move(_ index: Int, _ move: GridNavigation.Move, _ sections: [Section]) -> Int {
    GridNavigation.target(from: index, move: move, in: sections)
}

/// 5 columns, 7 items: a full row of 5 (0–4) and a partial row of 2 (5, 6).
private let partial = [Section(count: 7, columns: 5)]

@Test func leftAndRightStepThroughRowEnds() {
    #expect(move(4, .right, partial) == 5, "→ at a row's end goes on to the next row")
    #expect(move(5, .left, partial) == 4, "← at a row's start goes back to the previous row's end")
    #expect(move(0, .left, partial) == 0, "the first item stays")
    #expect(move(6, .right, partial) == 6, "the last item stays")
}

@Test func upAndDownKeepTheColumn() {
    #expect(move(1, .down, partial) == 6, "column 1")
    #expect(move(6, .up, partial) == 1)
    #expect(move(5, .up, partial) == 0)
    #expect(move(4, .down, partial) == 6, "a shorter last row takes its last item")
    #expect(move(3, .down, partial) == 6)
    #expect(move(0, .up, partial) == 0, "the top row stays")
    #expect(move(5, .down, partial) == 5, "the bottom row stays")
}

@Test func upAndDownCrossSections() {
    // Section A: 5 columns, 7 items (0–6). Section B: 5 columns, 3 items (7–9). Section C: 8 columns, 10 items.
    let sections = [Section(count: 7, columns: 5), Section(count: 3, columns: 5), Section(count: 10, columns: 8)]
    #expect(move(6, .down, sections) == 8, "from A's last row, column 1, to B's first row, column 1")
    #expect(move(4, .down, sections) == 6, "column 4 of A's first row goes to the row below in A")
    #expect(move(5, .down, sections) == 7)
    #expect(move(8, .up, sections) == 6, "back to A's last row, column 1")
    #expect(move(9, .up, sections) == 6, "column 2 → A's last row, which only reaches column 1")
    #expect(move(7, .up, sections) == 5)
    // B (5 columns) to C (8 columns): the nearest column by position.
    #expect(move(7, .down, sections) == 10, "column 0 of 5 → column 0 of 8")
    #expect(move(9, .down, sections) == 14, "column 2 of 5, the middle → column 4 of 8")
    #expect(move(14, .up, sections) == 9, "column 4 of 8 → column 2 of 5")
    #expect(move(17, .up, sections) == 9, "column 7 of 8 → column 4 of 5, but B's row only reaches column 2")
    #expect(move(18, .down, sections) == 18, "C's last row stays")
    #expect(move(17, .down, sections) == 19, "column 7 → C's shorter last row's last item")
}

@Test func navigationSkipsEmptySectionsAndOutOfRangeIndexes() {
    let sections = [Section(count: 2, columns: 5), Section(count: 0, columns: 5), Section(count: 2, columns: 5)]
    #expect(move(0, .down, sections) == 2)
    #expect(move(3, .up, sections) == 1)
    #expect(move(9, .down, sections) == 0, "an unknown index starts at the first item")
    #expect(move(0, .down, []) == 0)
}

@Test func arrowRule() {
    func moves(_ arrow: GridNavigation.Move, _ length: Int, _ selection: (Int, Int)?) -> Bool {
        GridNavigation.arrowMovesSelection(
            arrow, textLength: length, selection: selection.map { (location: $0.0, length: $0.1) })
    }
    // ↑↓ always move the selection.
    #expect(moves(.up, 5, (2, 0)))
    #expect(moves(.down, 5, (0, 5)))
    // ←→ do with an empty search field.
    #expect(moves(.left, 0, (0, 0)))
    #expect(moves(.right, 0, nil))
    // …or with the cursor at the end and nothing selected.
    #expect(moves(.left, 5, (5, 0)))
    #expect(moves(.right, 5, (5, 0)))
    // Otherwise they move the cursor.
    #expect(!moves(.left, 5, (2, 0)))
    #expect(!moves(.right, 5, (2, 0)))
    #expect(!moves(.right, 5, (0, 5)), "all the text selected")
    #expect(!moves(.left, 5, (3, 2)), "a selection that ends at the end")
    #expect(!moves(.right, 5, nil), "text, but no known cursor")
}

@Test func aGridAsksForMoreTwoRowsFromTheEnd() throws {
    // 30 items in 4 columns: two rows is 8 items, so index 22 is the first that asks.
    let items = (1...30).map { #"{"id":\#($0 + 1),"type":"Grid.Item","props":{"content":"🙂"},"children":[]}"# }
    let grid = ListContent(
        try node(
            #"{"id":1,"type":"Grid","props":{"columns":4,"pagination":{"pageSize":30,"hasMore":true,"#
                + #""onLoadMore":{"$fn":["pagination","onLoadMore"]}}},"children":["#
                + items.joined(separator: ",") + "]}"),
        searchText: "")
    #expect(grid.gridSections == [GridNavigation.Section(count: 30, columns: 4)])
    #expect(!grid.wantsMore(near: 21))
    #expect(grid.wantsMore(near: 22))
    #expect(
        ListContent(try node(#"{"id":1,"type":"List","props":{},"children":[]}"#), searchText: "").gridSections == nil)
}
