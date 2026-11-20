import Foundation
import Testing

@testable import FudgeCore

private func form(_ children: String) throws -> FormContent {
    let json = #"{"id":1,"type":"Form","props":{},"children":["# + children + "]}"
    return FormContent(try JSONDecoder().decode(UINode.self, from: Data(json.utf8)))
}

private let dropdownJSON = #"""
    {"id":2,"type":"Form.Dropdown","props":{"id":"lang","title":"Language","placeholder":"Pick one",
      "onChange":{"$fn":["onChange"]}},"children":[
      {"id":3,"type":"Form.Dropdown.Item","props":{"value":"swift","title":"Swift","keywords":["apple"]},"children":[]},
      {"id":4,"type":"Form.Dropdown.Section","props":{"title":"Web"},"children":[
        {"id":5,"type":"Form.Dropdown.Item","props":{"value":"ts","title":"TypeScript"},"children":[]},
        {"id":6,"type":"Form.Dropdown.Item","props":{"value":"js","title":"JavaScript"},"children":[]}]}]}
    """#

private let tagPickerJSON = #"""
    {"id":10,"type":"Form.TagPicker","props":{"id":"tags","placeholder":"Tags"},"children":[
      {"id":11,"type":"Form.TagPicker.Item","props":{"value":"red","title":"Red","icon":"🔴"},"children":[]},
      {"id":12,"type":"Form.TagPicker.Item","props":{"value":"green","title":"Green"},"children":[]},
      {"id":13,"type":"Form.TagPicker.Item","props":{"value":"blue","title":"Blue"},"children":[]}]}
    """#

@Test func readsAFormDropdownAndStartsOnItsFirstItem() throws {
    let field = try #require(try form(dropdownJSON).fields.first)
    #expect(field.kind == .dropdown && field.isEditable)
    #expect(field.placeholder == "Pick one")
    let options = try #require(field.options)
    #expect(options.sections.map(\.title) == [nil, "Web"])
    #expect(options.items.map(\.value) == ["swift", "ts", "js"])
    #expect(options.items[1].keywords == ["Web"], "an item's keywords default to its section's title")
    // With no value or defaultValue, the first item is chosen, and the extension has to hear it (onChange).
    #expect(field.initialValue() == .string("swift"))
    #expect(field.registeredValue == .null)

    let withDefault = try #require(
        try form(dropdownJSON.replacingOccurrences(of: #""placeholder":"Pick one","#, with: #""defaultValue":"js","#))
            .fields.first)
    #expect(withDefault.initialValue() == .string("js") && withDefault.registeredValue == .string("js"))
}

@Test func aDropdownFiltersItsItemsOrLeavesThatToTheExtension() throws {
    let options = try #require(try form(dropdownJSON).fields.first?.options)
    #expect(options.filtersLocally)
    #expect(options.sections(matching: "script").flatMap(\.items).map(\.value) == ["ts", "js"])
    #expect(options.sections(matching: "apple").flatMap(\.items).map(\.value) == ["swift"], "keywords match too")
    #expect(options.sections(matching: "web").map(\.title) == ["Web"], "section titles are keywords")

    let searching = try #require(
        try form(
            dropdownJSON.replacingOccurrences(
                of: #""onChange":{"$fn":["onChange"]}"#,
                with: #""onSearchTextChange":{"$fn":["onSearchTextChange"]},"throttle":true,"isLoading":true"#)
        ).fields.first?.options)
    #expect(!searching.filtersLocally && searching.handlesSearch && searching.throttle && searching.isLoading)
    #expect(searching.sections(matching: "script").flatMap(\.items).count == 3, "the extension filters")
}

@Test func aDropdownWhoseItemsComeLaterTakesTheFirstThen() throws {
    let empty = try #require(
        try form(#"{"id":2,"type":"Form.Dropdown","props":{"id":"lang"},"children":[]}"#).fields.first)
    #expect(empty.initialValue() == .null && empty.registeredValue == .null, "nothing to choose yet, nothing to tell")
    let loaded = try #require(try form(dropdownJSON).fields.first)
    #expect(loaded.firstItemValue(replacing: .null) == .string("swift"))
    #expect(loaded.firstItemValue(replacing: .string("ts")) == nil, "a choice stays")
    let controlled = try #require(
        try form(dropdownJSON.replacingOccurrences(of: #""placeholder":"Pick one","#, with: #""value":"ts","#))
            .fields.first)
    #expect(controlled.firstItemValue(replacing: .null) == nil, "the extension decides")
}

@Test func readsATagPickerAndPicksEachItemOnce() throws {
    let field = try #require(try form(tagPickerJSON).fields.first)
    #expect(field.kind == .tagPicker && field.isEditable)
    #expect(field.tags.map(\.value) == ["red", "green", "blue"])
    #expect(field.tags[0].icon == .string("🔴") && field.tags[1].title == "Green")
    #expect(field.initialValue() == .array([]) && field.registeredValue == .array([]))

    var chosen = TagPicking.adding("green", to: [], items: field.tags)
    chosen = TagPicking.adding("red", to: chosen, items: field.tags)
    #expect(chosen == ["green", "red"], "in the order picked")
    #expect(TagPicking.adding("red", to: chosen, items: field.tags) == chosen, "no duplicates")
    #expect(TagPicking.adding("purple", to: chosen, items: field.tags) == chosen, "only the TagPicker's own items")
    #expect(TagPicking.removing("green", from: chosen) == ["red"])
    #expect(TagPicking.values(.array([.string("a"), .number(1), .string("b")])) == ["a", "b"])
    #expect(TagPicking.values(nil).isEmpty)

    #expect(TagPicking.suggestions(field.tags, chosen: chosen, query: "").map(\.value) == ["blue"])
    #expect(TagPicking.suggestions(field.tags, chosen: [], query: "re").map(\.value) == ["red", "green"])
}

@Test func aStoredValueStartsTheFieldAheadOfItsDefault() throws {
    let fields = try form(
        #"""
        {"id":2,"type":"Form.TextField","props":{"id":"name","storeValue":true,"defaultValue":"default"},"children":[]},
        {"id":3,"type":"Form.TextField","props":{"id":"title","storeValue":true,"value":"controlled"},"children":[]},
        {"id":4,"type":"Form.TextField","props":{"id":"plain","defaultValue":"default"},"children":[]},
        {"id":5,"type":"Form.PasswordField","props":{"id":"secret","storeValue":true},"children":[]},
        {"id":6,"type":"Form.Checkbox","props":{"id":"done","storeValue":true},"children":[]}
        """#
    ).fields
    #expect(fields[0].storesValue && fields[0].initialValue(stored: .string("kept")) == .string("kept"))
    #expect(fields[0].registeredValue == .string("default"), "so the extension hears the stored value")
    #expect(fields[1].initialValue(stored: .string("kept")) == .string("controlled"), "a controlled value wins")
    #expect(fields[2].initialValue(stored: .string("kept")) == .string("default"), "only with storeValue")
    #expect(!fields[3].storesValue, "a PasswordField is never stored")
    #expect(fields[3].initialValue(stored: .string("hunter2")) == .string(""))
    #expect(fields[4].initialValue(stored: .bool(true)) == .bool(true))
    // Values of the wrong type are ignored.
    #expect(fields[0].initialValue(stored: .bool(true)) == .string("default"))
    #expect(fields[4].initialValue(stored: .string("yes")) == .bool(false))
}

@Test func aStoredChoiceMustStillBeAnItem() throws {
    let stored = dropdownJSON.replacingOccurrences(of: #""placeholder":"Pick one","#, with: #""storeValue":true,"#)
    let dropdown = try #require(try form(stored).fields.first)
    #expect(dropdown.initialValue(stored: .string("js")) == .string("js"))
    #expect(dropdown.initialValue(stored: .string("cobol")) == .string("swift"), "a vanished item is ignored")

    let tags = try #require(
        try form(tagPickerJSON.replacingOccurrences(of: #""placeholder":"Tags""#, with: #""storeValue":true"#))
            .fields.first)
    #expect(tags.initialValue(stored: .array([.string("blue")])) == .array([.string("blue")]))
    #expect(tags.initialValue(stored: .array([.string("blue"), .string("gone")])) == .array([]))
    #expect(tags.initialValue(stored: .string("blue")) == .array([]))
}

@Test func keepsOnlyTheValuesOfFieldsThatStoreThem() throws {
    let content = try form(
        #"""
        {"id":2,"type":"Form.TextField","props":{"id":"name","storeValue":true},"children":[]},
        {"id":3,"type":"Form.TextField","props":{"id":"other"},"children":[]},
        {"id":4,"type":"Form.PasswordField","props":{"id":"secret","storeValue":true},"children":[]}
        """#)
    let submitted: [String: JSONValue] = ["name": .string("a"), "other": .string("b"), "secret": .string("c")]
    #expect(content.valuesToStore(submitted) == ["name": .string("a")])
}

@Test func storesSubmittedValuesByExtensionCommandAndField() throws {
    let store = FormValueStore(directory: try Fixtures.temporaryDirectory().appendingPathComponent("form-values"))
    #expect(store.load(extension: "notes", command: "new").isEmpty)
    try store.save(["title": .string("Hello"), "tags": .array([.string("red")])], extension: "notes", command: "new")
    try store.save(["title": .string("Other command")], extension: "notes", command: "edit")
    try store.save(["done": .bool(true)], extension: "notes", command: "new")
    try store.save(["title": .string("Elsewhere")], extension: "todo", command: "new")
    #expect(
        store.load(extension: "notes", command: "new")
            == ["title": .string("Hello"), "tags": .array([.string("red")]), "done": .bool(true)])
    #expect(store.load(extension: "notes", command: "edit") == ["title": .string("Other command")])
    #expect(store.load(extension: "todo", command: "new") == ["title": .string("Elsewhere")])

    // A Date crosses the bridge as a $date marker and comes back the same.
    let date: JSONValue = .object(["$date": .string("2026-11-20T12:00:00.000Z")])
    try store.save(["due": date], extension: "notes", command: "new")
    #expect(store.load(extension: "notes", command: "new")["due"] == date)
}

@Test func focusEventsCarryTheFieldAndItsValue() throws {
    let field = try #require(
        try form(
            #"{"id":2,"type":"Form.TextField","props":{"id":"name","onFocus":{"$fn":["onFocus"]},"onBlur":{"$fn":["onBlur"]}},"children":[]}"#
        ).fields.first)
    #expect(field.hasOnFocus && field.hasOnBlur)
    #expect(
        field.focusEvent("blur", value: .string("typed"))
            == .object([
                "target": .object(["id": .string("name"), "value": .string("typed")]), "type": .string("blur"),
            ]))
    let plain = try #require(try form(dropdownJSON).fields.first)
    #expect(!plain.hasOnFocus && !plain.hasOnBlur)
}

private func storedDropdown(items: String) throws -> FormContent.Field {
    try #require(
        try form(
            #"{"id":2,"type":"Form.Dropdown","props":{"id":"color","storeValue":true},"children":["# + items + "]}"
        )
        .fields.first)
}

private func colorItem(_ id: Int, _ value: String) -> String {
    #"{"id":\#(id),"type":"Form.Dropdown.Item","props":{"value":"\#(value)","title":"\#(value)"},"children":[]}"#
}

@Test func aStoredChoiceWaitsForItemsThatArriveLater() throws {
    let blue: JSONValue = .string("blue")
    // First render: no items yet. Nothing to choose, and the stored value waits.
    let first = try storedDropdown(items: "").start(current: nil, stored: blue)
    #expect(first == FieldStart(value: .null, reports: false, pending: blue))
    // The items arrive, the stored one among them: it's taken ahead of the first item, and the extension hears it.
    let loaded = try storedDropdown(items: colorItem(3, "red") + "," + colorItem(4, "blue"))
    #expect(
        loaded.start(current: first.value, stored: first.pending)
            == FieldStart(value: blue, reports: true, pending: nil))

    // Items that don't include it yet: the first item shows meanwhile, and the stored value keeps waiting.
    let partial = try storedDropdown(items: colorItem(3, "red"))
    let meanwhile = partial.start(current: .null, stored: blue)
    #expect(meanwhile == FieldStart(value: .string("red"), reports: true, pending: blue))
    #expect(loaded.start(current: meanwhile.value, stored: meanwhile.pending).value == blue, "taken when it arrives")

    // Once nothing waits (the user changed the field, so the app dropped it), later items change nothing.
    #expect(
        loaded.start(current: .string("red"), stored: nil)
            == FieldStart(value: .string("red"), reports: false, pending: nil))
    // A controlled dropdown never waits: the extension decides.
    let controlled = try #require(
        try form(
            #"{"id":2,"type":"Form.Dropdown","props":{"id":"color","storeValue":true,"value":"red"},"children":[]}"#
        )
        .fields.first)
    #expect(controlled.start(current: nil, stored: blue).pending == nil)
    // A value of the wrong type never waits.
    #expect(try storedDropdown(items: "").start(current: nil, stored: .bool(true)).pending == nil)
}

@Test func storedTagsWaitForTheirItemsToo() throws {
    func tags(_ items: [String]) throws -> FormContent.Field {
        let children = items.enumerated().map { index, value in
            #"{"id":\#(index + 3),"type":"Form.TagPicker.Item","props":{"value":"\#(value)","title":"\#(value)"},"children":[]}"#
        }
        let json =
            #"{"id":2,"type":"Form.TagPicker","props":{"id":"tags","storeValue":true},"children":["#
            + children.joined(separator: ",") + "]}"
        return try #require(try form(json).fields.first)
    }
    let stored: JSONValue = .array([.string("b"), .string("c")])
    let first = try tags([]).start(current: nil, stored: stored)
    #expect(first == FieldStart(value: .array([]), reports: false, pending: stored))
    let some = try tags(["a", "b"]).start(current: first.value, stored: first.pending)
    #expect(some == FieldStart(value: .array([]), reports: false, pending: stored), "not all of them yet")
    let all = try tags(["a", "b", "c"]).start(current: some.value, stored: some.pending)
    #expect(all == FieldStart(value: stored, reports: true, pending: nil))
}

@Test func aFieldSeenTheFirstTimeStartsAsBefore() throws {
    let dropdown = try storedDropdown(items: colorItem(3, "red") + "," + colorItem(4, "blue"))
    #expect(
        dropdown.start(current: nil, stored: .string("blue"))
            == FieldStart(value: .string("blue"), reports: true, pending: nil))
    #expect(dropdown.start(current: nil, stored: nil) == FieldStart(value: .string("red"), reports: true, pending: nil))
    let text = try #require(
        try form(#"{"id":2,"type":"Form.TextField","props":{"id":"name","defaultValue":"x"},"children":[]}"#).fields
            .first)
    #expect(text.start(current: nil, stored: nil) == FieldStart(value: .string("x"), reports: false, pending: nil))
    #expect(
        text.start(current: .string("typed"), stored: nil)
            == FieldStart(value: .string("typed"), reports: false, pending: nil))
}
