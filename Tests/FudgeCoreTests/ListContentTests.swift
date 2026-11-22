import Foundation
import Testing

@testable import FudgeCore

private func node(_ json: String) throws -> UINode {
    try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
}

private let now = ListContent.date(.object(["$date": .string("2026-11-20T12:00:00.000Z")]))!

/// A list shaped like scratch-folders: two sections, an empty view, items with accessories.
private let folders = #"""
    {"id":1,"type":"List","props":{"isLoading":false,"searchBarPlaceholder":"Search scratch folders"},"children":[
      {"id":2,"type":"List.EmptyView","props":{"title":"No scratch folders","description":"⌘N makes one.",
        "icon":"folder-16","actions":{"id":90,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
      {"id":3,"type":"List.Section","props":{"title":"Active","subtitle":"2"},"children":[
        {"id":4,"type":"List.Item","props":{"id":"icy-panda","title":"icy-panda","subtitle":"api spike",
          "keywords":["api","spike"],"icon":{"fileIcon":"/tmp/icy-panda"},
          "accessories":[
            {"icon":{"source":"pin-16","tintColor":"raycast-secondary-text"},"tooltip":"No marker"},
            {"tag":{"value":"2h","color":"raycast-secondary-text"},"tooltip":"Newest change"}
          ],
          "actions":{"id":91,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
        {"id":5,"type":"List.Item","props":{"title":"sunny-mesa"},"children":[]}
      ]},
      {"id":6,"type":"List.Section","props":{"title":"Stale"},"children":[
        {"id":7,"type":"List.Item","props":{"title":"amber-marble","accessories":[
          {"tag":{"value":"large tree","color":"raycast-orange"}},
          {"date":{"$date":"2026-11-19T12:00:00.000Z"}},
          {"text":{"value":"old","color":"raycast-red"},"icon":"clock-16"},
          {"text":null}
        ]},"children":[]}
      ]},
      {"id":8,"type":"List.Section","props":{"title":"Empty"},"children":[]}
    ]}
    """#

@Test func readsSectionsItemsAndAccessories() throws {
    let list = ListContent(try node(folders), searchText: "", now: now)
    #expect(list.sections.map(\.title) == ["Active", "Stale"], "empty sections are left out")
    #expect(list.sections[0].subtitle == "2")
    #expect(list.items.map(\.title) == ["icy-panda", "sunny-mesa", "amber-marble"])
    #expect(list.emptyView == nil)

    let first = list.items[0]
    #expect(first.itemId == "icy-panda")
    #expect(first.subtitle == "api spike")
    #expect(first.icon == .object(["fileIcon": .string("/tmp/icy-panda")]))
    #expect(first.actions?.id == 91)
    #expect(first.accessories.count == 2)
    #expect(first.accessories[0].text == nil && first.accessories[0].icon != nil)
    #expect(first.accessories[0].tooltip == "No marker")
    #expect(first.accessories[1].isTag && first.accessories[1].text == "2h")
    #expect(first.accessories[1].color == .string("raycast-secondary-text"))

    let stale = list.items[2].accessories
    #expect(stale.map(\.text) == ["large tree", "1d", "old"], "dates are relative; empty accessories are dropped")
    #expect(stale.map(\.isTag) == [true, false, false])
    #expect(stale[2].color == .string("raycast-red") && stale[2].icon == .string("clock-16"))
}

@Test func groupsItemsOutsideSectionsIntoUntitledOnes() throws {
    let list = ListContent(
        try node(
            #"""
            {"id":1,"type":"List","props":{},"children":[
              {"id":2,"type":"List.Item","props":{"title":"a"},"children":[]},
              {"id":3,"type":"List.Item","props":{"title":{"value":"b","tooltip":"bee"},"subtitle":{"value":"sub"}},"children":[]},
              {"id":4,"type":"List.Section","props":{"title":"S"},"children":[
                {"id":5,"type":"List.Item","props":{"title":"c"},"children":[]}
              ]},
              {"id":6,"type":"List.Item","props":{"title":"d","icon":{"value":"star-16","tooltip":"starred"}},"children":[]}
            ]}
            """#),
        searchText: "")
    #expect(list.sections.map(\.title) == [nil, "S", nil])
    #expect(list.sections.map(\.id) == [-1, 4, -3], "by their place, never their items")
    #expect(list.items[1].title == "b" && list.items[1].titleTooltip == "bee" && list.items[1].subtitle == "sub")
    #expect(list.items[3].icon == .string("star-16") && list.items[3].iconTooltip == "starred")
}

@Test func filtersByTitleAndKeywordsBestFirst() throws {
    let view = try node(folders)
    #expect(ListContent(view, searchText: "spike").items.map(\.title) == ["icy-panda"], "keywords match")
    #expect(ListContent(view, searchText: "api spike").items.isEmpty, "the subtitle isn't searched")

    let ranked = ListContent(view, searchText: "am")
    #expect(ranked.items.first?.title == "amber-marble", "the best match comes first")
    #expect(ranked.sections.first?.title == "Stale", "sections follow their best item")
}

@Test func keepsSectionOrderWhenAsked() throws {
    let json = try node(folders)
    var view = json
    view.props["filtering"] = .object(["keepSectionOrder": .bool(true)])
    let list = ListContent(view, searchText: "a")
    #expect(list.sections.map(\.title) == ["Active", "Stale"])
}

@Test func leavesFilteringToCommandsThatHandleSearch() throws {
    var view = try node(folders)
    view.props["onSearchTextChange"] = .object(["$fn": .array([.string("onSearchTextChange")])])
    #expect(!ListContent.filtersLocally(view))
    #expect(ListContent(view, searchText: "zzz").items.count == 3)

    view.props["filtering"] = .bool(true)
    #expect(ListContent.filtersLocally(view))
    view.props["filtering"] = nil
    view.props["enableFiltering"] = .bool(true)
    #expect(ListContent.filtersLocally(view))
}

@Test func showsTheEmptyViewOnlyWhenNothingMatches() throws {
    var view = try node(folders)
    let empty = ListContent(view, searchText: "zzz")
    #expect(empty.sections.isEmpty)
    #expect(empty.emptyView?.title == "No scratch folders")
    #expect(empty.emptyView?.description == "⌘N makes one.")
    #expect(empty.emptyView?.actions?.id == 90)

    view.props["isLoading"] = .bool(true)
    #expect(ListContent(view, searchText: "zzz").emptyView != nil, "a search that finds nothing says so")
    view.children = []
    #expect(ListContent(view, searchText: "").emptyView == nil, "not while loading with an empty search")
    view.props["isLoading"] = .bool(false)
    #expect(ListContent(view, searchText: "").emptyView?.title == "No Results", "Raycast's default")
}

/// FUD-107: a List of items outside any section, re-ranked by a search, keeps its section's id. The views tell sections
/// apart by it, and with the first item's id the re-ranked rows kept the old section's drawing: the highlight stayed
/// on the item selected before while the detail showed the new selection's.
@Test func aLooseSectionKeepsItsIdWhenItsItemsReRank() throws {
    func ranked(_ ids: [Int], kind: String = "List") throws -> ListContent {
        let items = ids.map {
            #"{"id":\#($0),"type":"\#(kind).Item","props":{"id":"f\#($0)","title":"f\#($0)"},"children":[]}"#
        }
        let json =
            #"{"id":1,"type":"\#(kind)","props":{"filtering":false},"children":[\#(items.joined(separator: ","))]}"#
        return ListContent(try node(json), searchText: "")
    }
    // A Grid's cells are grouped the same way, and `GridScreen` tells sections apart by the same id.
    for kind in ["List", "Grid"] {
        let before = try ranked([26, 50, 73, 96, 119], kind: kind)
        let after = try ranked([96, 50, 73, 26, 119], kind: kind)
        #expect(before.sections.map(\.id) == after.sections.map(\.id), "\(kind)")
        #expect(after.items.map(\.id) == [96, 50, 73, 26, 119], "\(kind)")
    }
}

@Test func reselectsAfterAnUpdate() throws {
    let list = ListContent(try node(folders), searchText: "")
    #expect(list.reselect(node: 5, itemId: nil) == 5, "the same node")
    #expect(list.reselect(node: 99, itemId: "icy-panda") == 4, "else the same id")
    #expect(list.reselect(node: 99, itemId: "gone") == 4, "else the first")
    #expect(ListContent(try node(folders), searchText: "zzz").reselect(node: 4, itemId: nil) == nil)
}

@Test func aNewSearchFiltersTheItemsAlreadyRead() throws {
    var view = try node(folders)
    var list = ListContent(view, searchText: "", now: now)
    for text in ["am", "a", "zzz", " spike ", ""] {
        list.search(text)
        #expect(list == ListContent(view, searchText: text, now: now), "\(text)")
    }
    // Loading with an empty search shows no empty view, and searching shows it.
    view.props["isLoading"] = .bool(true)
    list = ListContent(view, searchText: "zzz", now: now)
    #expect(list.emptyView?.title == "No scratch folders")
    list.search("")
    #expect(list.items.count == 3)
    #expect(list.emptyView == nil)
}

@Test func deferredActionsAndDetailAreFilledInWhenTheyCome() throws {
    let view = try node(
        #"""
        {"id":1,"type":"List","props":{},"children":[
          {"id":2,"type":"List.Item","props":{"title":"first","actions":{"id":9,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
          {"id":3,"type":"List.Item","props":{"title":"later","actions":{"$deferred":true},"detail":{"$deferred":true}},"children":[]},
          {"id":4,"type":"List.Item","props":{"title":"none","actions":null},"children":[]}
        ]}
        """#)
    let items = ListContent(view, searchText: "").items
    #expect(items.map(\.deferred) == [[], [.actions, .detail], []])
    #expect(items[0].actions?.type == "ActionPanel")
    #expect(items[1].actions == nil && items[1].detail == nil)

    let panel = UINode(id: 7, type: "ActionPanel")
    let filled = items[1].filled(with: ItemSlots(id: 3, actions: panel))
    #expect(filled.actions == panel)
    #expect(filled.detail == nil, "the host had no detail for it after all")
    #expect(filled.deferred.isEmpty)
    #expect(items[1].filled(with: nil) == items[1], "still on its way")
    #expect(items[0].filled(with: ItemSlots(id: 2)) == items[0], "only deferred slots are filled")
}

@Test func aHeldBackPanelsShortcutsWaitForIt() throws {
    let view = try node(
        #"""
        {"id":1,"type":"List","props":{"$shortcutSets":[
            [{"modifiers":["cmd"],"key":"backspace"},{"macOS":{"modifiers":["cmd"],"key":"p"},"Windows":{"modifiers":["ctrl"],"key":"p"}}],
            [{"modifiers":["cmd","shift"],"key":"c"}]
          ]},"children":[
          {"id":2,"type":"List.Item","props":{"title":"first","actions":{"id":9,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
          {"id":3,"type":"List.Item","props":{"title":"usual","actions":{"$deferred":true,"shortcuts":0}},"children":[]},
          {"id":4,"type":"List.Section","props":{},"children":[
            {"id":5,"type":"List.Item","props":{"title":"other","actions":{"$deferred":true,"shortcuts":1}},"children":[]}
          ]},
          {"id":6,"type":"List.Item","props":{"title":"plain","actions":{"$deferred":true}},"children":[]},
          {"id":7,"type":"List.Item","props":{"title":"bad index","actions":{"$deferred":true,"shortcuts":5}},"children":[]}
        ]}
        """#)
    let items = Dictionary(uniqueKeysWithValues: ListContent(view, searchText: "").items.map { ($0.id, $0) })
    let delete = KeyShortcut(key: "backspace", modifiers: ["cmd"])
    let print = KeyShortcut(key: "p", modifiers: ["cmd"])
    let copy = KeyShortcut(key: "c", modifiers: ["cmd", "shift"])
    #expect(items[3]?.deferredShortcuts == [delete, print], "Raycast's macOS/Windows pairs read as the macOS one")
    #expect(items[3]?.waitsForActions(delete) == true)
    #expect(items[3]?.waitsForActions(print) == true)
    #expect(items[3]?.waitsForActions(copy) == false, "another row's shortcut goes to the search field")
    #expect(items[5]?.waitsForActions(copy) == true)
    #expect(items[2]?.waitsForActions(delete) == false, "its actions are here")
    #expect(items[6]?.deferredShortcuts == [], "a panel without shortcuts")
    #expect(items[7]?.deferredShortcuts == [], "an index past the sets")
    // Once its actions come, nothing waits.
    let filled = try #require(items[3]).filled(with: ItemSlots(id: 3, actions: UINode(id: 8, type: "ActionPanel")))
    #expect(!filled.waitsForActions(delete))
    let notHeld = try node(#"{"id":1,"type":"List.Item","props":{"actions":{"$deferred":false}},"children":[]}"#)
    #expect(ListContent.deferred(notHeld) == [])
}

@Test func readsDatesWithAndWithoutFractionsAndOffsets() {
    func date(_ iso: String) -> Date? { ListContent.date(.object(["$date": .string(iso)])) }
    #expect(date("2026-11-20T12:00:00.000Z") == Date(timeIntervalSince1970: 1_795_176_000))
    #expect(date("2026-11-20T12:00:00.250Z") == Date(timeIntervalSince1970: 1_795_176_000.25))
    #expect(date("2026-11-20T12:00:00Z") == Date(timeIntervalSince1970: 1_795_176_000))
    #expect(date("2026-11-20T13:00:00+01:00") == Date(timeIntervalSince1970: 1_795_176_000))
    #expect(date("yesterday") == nil)
    #expect(ListContent.date(.string("2026-11-20T12:00:00.000Z")) == nil, "only the $date marker")
}

@Test func writesDatesRelatively() {
    func ago(_ seconds: Double) -> String { ListContent.relative(now.addingTimeInterval(-seconds), now: now) }
    #expect(ago(10) == "now")
    #expect(ago(5 * 60) == "5m")
    #expect(ago(3 * 3600) == "3h")
    #expect(ago(86400) == "1d")
    #expect(ago(15 * 86400) == "2w")
    #expect(ago(65 * 86400) == "2mo")
    #expect(ago(800 * 86400) == "2y")
}

@Test func readsTheSearchBarDropdown() throws {
    let view = try node(
        #"""
        {"id":1,"type":"List","props":{"searchBarAccessory":
          {"id":2,"type":"List.Dropdown","props":{"tooltip":"Tags filter","defaultValue":"","onChange":{"$fn":["onChange"]}},"children":[
            {"id":3,"type":"List.Dropdown.Section","props":{},"children":[
              {"id":4,"type":"List.Dropdown.Item","props":{"title":"All Tags","value":""},"children":[]}
            ]},
            {"id":5,"type":"List.Dropdown.Section","props":{"title":"Tags"},"children":[
              {"id":6,"type":"List.Dropdown.Item","props":{"title":"work","value":"work"},"children":[]},
              {"id":7,"type":"List.Dropdown.Item","props":{"title":"home","value":"home","icon":"house-16"},"children":[]}
            ]}
          ]}
        },"children":[]}
        """#)
    let dropdown = try #require(ListContent(view, searchText: "").dropdown)
    #expect(dropdown.id == 2)
    #expect(dropdown.tooltip == "Tags filter")
    #expect(dropdown.sections.map(\.title) == [nil, "Tags"])
    #expect(dropdown.items.map(\.value) == ["", "work", "home"])
    #expect(dropdown.items[2].icon == .string("house-16"))
    #expect(dropdown.initialValue(stored: "home") == "", "the default wins without storeValue")

    var stored = dropdown
    stored.storesValue = true
    #expect(stored.initialValue(stored: "home") == "home")
    #expect(stored.initialValue(stored: "gone") == "", "a stored value that's no longer an item is ignored")
    stored.defaultValue = nil
    #expect(stored.initialValue(stored: nil) == "", "else the first item")
    stored.value = "work"
    #expect(stored.initialValue(stored: "home") == "work", "a controlled value wins")
}

@Test func searchesTheDropdownsOwnItems() throws {
    let node = try JSONDecoder().decode(
        UINode.self,
        from: Data(
            #"""
            {"id":2,"type":"List.Dropdown","props":{"tooltip":"Kind","placeholder":"Find a kind"},"children":[
              {"id":3,"type":"List.Dropdown.Item","props":{"title":"Everything","value":"all"},"children":[]},
              {"id":4,"type":"List.Dropdown.Section","props":{"title":"Fruit"},"children":[
                {"id":5,"type":"List.Dropdown.Item","props":{"title":"Apple","value":"apple"},"children":[]},
                {"id":6,"type":"List.Dropdown.Item","props":{"title":"Banana","value":"banana","keywords":["yellow"]},"children":[]}
              ]},
              {"id":7,"type":"List.Dropdown.Section","props":{"title":"Empty"},"children":[]}
            ]}
            """#.utf8))
    var dropdown = try #require(SearchBarDropdown(node))
    #expect(dropdown.placeholder == "Find a kind" && dropdown.filtersLocally && !dropdown.handlesSearch)
    #expect(dropdown.sections(matching: "").map(\.title) == [nil, "Fruit"], "empty sections are left out")
    #expect(dropdown.sections(matching: "ban").flatMap(\.items).map(\.value) == ["banana"])
    #expect(dropdown.sections(matching: "yellow").flatMap(\.items).map(\.value) == ["banana"], "keywords match")
    #expect(
        dropdown.sections(matching: "fruit").flatMap(\.items).map(\.value) == ["apple"],
        "keywords default to the section's title")
    dropdown.filtersLocally = false
    #expect(dropdown.sections(matching: "zzz").flatMap(\.items).count == 3, "the extension filters")
}

@Test func asksForMorePagesNearTheEnd() throws {
    var view = try node(folders)
    #expect(ListContent(view, searchText: "").pagination == nil)
    view.props["pagination"] = .object([
        "pageSize": .number(20), "hasMore": .bool(true),
        "onLoadMore": .object(["$fn": .array([.string("pagination"), .string("onLoadMore")])]),
    ])
    let list = ListContent(view, searchText: "")
    #expect(list.pagination == .init(pageSize: 20, hasMore: true))
    #expect(list.wantsMore(near: 3, threshold: 1), "4 items: index 3 is the last")
    #expect(!list.wantsMore(near: 1, threshold: 1))
    view.props["isLoading"] = .bool(true)
    #expect(!ListContent(view, searchText: "").wantsMore(near: 3), "not while a page loads")
    view.props["isLoading"] = .bool(false)
    view.props["pagination"] = .object([
        "pageSize": .number(20), "hasMore": .bool(false),
        "onLoadMore": .object(["$fn": .array([.string("pagination"), .string("onLoadMore")])]),
    ])
    #expect(!ListContent(view, searchText: "").wantsMore(near: 3), "not when there's no more")
}

@Test func keepsStoredDropdownValues() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SearchBarDropdown.Store(file: folder.appendingPathComponent("dropdown-values.json"))
    let projects = ExtensionID(stored: "projects")!
    let key = SearchBarDropdown.Store.key(extension: projects, command: "search", dropdown: nil)
    #expect(key == "projects/search")
    #expect(store.value(for: key) == nil)
    try store.set("work", for: key)
    try store.set("x", for: SearchBarDropdown.Store.key(extension: projects, command: "search", dropdown: "tags"))
    #expect(store.value(for: key) == "work")
    #expect(store.value(for: "projects/search/tags") == "x")
}

@Test func readsColors() {
    #expect(ExtensionColor(json: .string("raycast-red")) == .named("raycast-red"))
    #expect(ExtensionColor("#ff0000") == .rgb(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(ExtensionColor("#0f08") == .rgb(red: 0, green: 1, blue: 0, alpha: 136.0 / 255))
    #expect(
        ExtensionColor(json: .object(["light": .string("#000"), "dark": .string("#fff")]))
            == .dynamic(
                light: .rgb(red: 0, green: 0, blue: 0, alpha: 1), dark: .rgb(red: 1, green: 1, blue: 1, alpha: 1))
    )
    #expect(ExtensionColor("#12345") == nil)
    #expect(ExtensionColor("nope") == nil)
}

@Test func readsHTMLColors() {
    #expect(ExtensionColor("rgb(255, 0, 0)") == .rgb(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(ExtensionColor("rgba(0,255,0,0.5)") == .rgb(red: 0, green: 1, blue: 0, alpha: 0.5))
    #expect(ExtensionColor("rgb(0 0 255 / 25%)") == .rgb(red: 0, green: 0, blue: 1, alpha: 0.25))
    #expect(ExtensionColor("rgb(100%, 50%, 0%)") == .rgb(red: 1, green: 0.5, blue: 0, alpha: 1))
    #expect(ExtensionColor("hsl(120, 100%, 50%)") == .rgb(red: 0, green: 1, blue: 0, alpha: 1))
    #expect(ExtensionColor("hsla(240deg 100% 50% / 0.5)") == .rgb(red: 0, green: 0, blue: 1, alpha: 0.5))
    #expect(ExtensionColor("hsl(0, 0%, 100%)") == .rgb(red: 1, green: 1, blue: 1, alpha: 1))
    #expect(ExtensionColor("RebeccaPurple") == ExtensionColor("#663399"))
    #expect(ExtensionColor("transparent") == .rgb(red: 0, green: 0, blue: 0, alpha: 0))
    #expect(ExtensionColor("rgb(1, 2)") == nil)
    #expect(ExtensionColor("cmyk(0, 0, 0, 0)") == nil)
}

@Test func keepsColorsReadable() {
    let purple = (0.4, 0.2, 0.6)  // rebeccapurple
    let onDark = ExtensionColor.readable(red: purple.0, green: purple.1, blue: purple.2, dark: true)
    #expect(onDark.0 > purple.0 && onDark.1 > purple.1 && onDark.2 > purple.2, "lightened on dark")
    let onLight = ExtensionColor.readable(red: purple.0, green: purple.1, blue: purple.2, dark: false)
    #expect(onLight == purple, "already dark enough on light")
    let yellow = ExtensionColor.readable(red: 1, green: 1, blue: 0, dark: false)
    #expect(yellow.0 < 1 && yellow.2 == 0, "darkened on light")
    #expect(ExtensionColor.readable(red: 1, green: 0.5, blue: 0, dark: true) == (1, 0.5, 0), "fine as it is")
    #expect(ExtensionColor(json: .object(["light": .string("#000")])) == nil)
}

@Test func readsMetadata() throws {
    let metadata = try node(
        #"""
        {"id":1,"type":"Metadata","props":{},"children":[
          {"id":2,"type":"Metadata.Label","props":{"title":"Type","text":"Folder","icon":"folder-16"},"children":[]},
          {"id":3,"type":"Metadata.Label","props":{"title":"Status","text":{"value":"Stale","color":"raycast-red"}},"children":[]},
          {"id":4,"type":"Metadata.Separator","props":{},"children":[]},
          {"id":5,"type":"Metadata.Link","props":{"title":"Remote","text":"GitHub","target":"https://github.com"},"children":[]},
          {"id":6,"type":"Metadata.TagList","props":{"title":"Tags"},"children":[
            {"id":7,"type":"Metadata.TagList.Item","props":{"text":"work","color":"#00f","onAction":{"$fn":["onAction"]}},"children":[]}
          ]}
        ]}
        """#)
    #expect(
        MetadataEntry.entries(of: metadata) == [
            .label(title: "Type", text: "Folder", color: nil, icon: .string("folder-16")),
            .label(title: "Status", text: "Stale", color: .string("raycast-red"), icon: nil),
            .separator,
            .link(title: "Remote", text: "GitHub", target: "https://github.com"),
            .tags(
                title: "Tags",
                tags: [.init(id: 7, text: "work", icon: nil, color: .string("#00f"), hasAction: true)]
            ),
        ])
}
