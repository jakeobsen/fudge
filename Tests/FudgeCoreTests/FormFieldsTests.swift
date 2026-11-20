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

private let copenhagen: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
    return calendar
}()

private func date(_ iso: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
}

@Test func readsADatePickerAndItsDates() throws {
    let fields = try form(
        #"""
        {"id":2,"type":"Form.DatePicker","props":{"id":"due","type":"date",
          "min":{"$date":"2026-11-01T00:00:00.000Z"},"max":{"$date":"2026-12-31T00:00:00.000Z"}},"children":[]},
        {"id":3,"type":"Form.DatePicker","props":{"id":"at","defaultValue":{"$date":"2026-11-20T12:30:00.000Z"}},"children":[]}
        """#
    ).fields
    #expect(fields[0].kind == .datePicker && fields[0].isEditable)
    #expect(
        fields[0].dates
            == DatePickerOptions(
                type: .date, min: date("2026-11-01T00:00:00.000Z"), max: date("2026-12-31T00:00:00.000Z")))
    #expect(fields[1].dates?.type == .dateTime, "DateTime is the default")
    #expect(fields[0].initialValue() == .null && fields[0].registeredValue == .null, "no date until one is picked")
    #expect(fields[1].initialValue() == .object(["$date": .string("2026-11-20T12:30:00.000Z")]))
    #expect(FormDates.date(fields[1].initialValue()) == date("2026-11-20T12:30:00.000Z"))
    #expect(FormDates.date(.string("2026-11-20")) == nil && FormDates.date(.null) == nil)
    #expect(FormDates.json(nil) == .null, "clearing is null")
    #expect(FormDates.json(date("2026-11-20T12:30:00.000Z")) == .object(["$date": .string("2026-11-20T12:30:00.000Z")]))
}

@Test func aDatePickerGivesMidnightOrWholeMinutesWithinItsLimits() {
    let picked = date("2026-11-20T14:37:42.500Z")  // 15:37:42 in Copenhagen
    let day = DatePickerOptions(type: .date)
    #expect(FormDates.value(for: picked, options: day, calendar: copenhagen) == date("2026-11-19T23:00:00.000Z"))
    #expect(
        FormDates.value(for: picked, options: DatePickerOptions(), calendar: copenhagen)
            == date("2026-11-20T14:37:00.000Z"))

    // With Date, the limits count by the day: a min later on the same day doesn't move the pick.
    let sameDay = DatePickerOptions(type: .date, min: date("2026-11-20T10:00:00.000Z"))
    #expect(FormDates.value(for: picked, options: sameDay, calendar: copenhagen) == date("2026-11-19T23:00:00.000Z"))
    let later = DatePickerOptions(type: .date, min: date("2026-11-25T10:00:00.000Z"))
    #expect(FormDates.value(for: picked, options: later, calendar: copenhagen) == date("2026-11-24T23:00:00.000Z"))
    let earlier = DatePickerOptions(type: .date, max: date("2026-11-10T10:00:00.000Z"))
    #expect(FormDates.value(for: picked, options: earlier, calendar: copenhagen) == date("2026-11-09T23:00:00.000Z"))
    // With DateTime, exactly.
    let bounded = DatePickerOptions(min: date("2026-11-20T15:00:00.000Z"), max: date("2026-11-20T16:00:00.000Z"))
    #expect(FormDates.value(for: picked, options: bounded, calendar: copenhagen) == date("2026-11-20T15:00:00.000Z"))
    #expect(
        FormDates.value(for: date("2026-11-20T17:00:00.000Z"), options: bounded, calendar: copenhagen)
            == date("2026-11-20T16:00:00.000Z"))
}

@Test func isFullDayMeansLocalMidnight() {
    #expect(FormDates.isFullDay(date("2026-11-19T23:00:00.000Z"), calendar: copenhagen))
    #expect(!FormDates.isFullDay(date("2026-11-20T00:00:00.000Z"), calendar: copenhagen), "UTC midnight isn't local")
    #expect(!FormDates.isFullDay(date("2026-11-19T23:00:00.001Z"), calendar: copenhagen))
    #expect(!FormDates.isFullDay(nil, calendar: copenhagen))
}

@Test func readsAFilePickersOptionsAndKeepsItsPaths() throws {
    let fields = try form(
        #"""
        {"id":2,"type":"Form.FilePicker","props":{"id":"files"},"children":[]},
        {"id":3,"type":"Form.FilePicker","props":{"id":"folder","canChooseFiles":false,"canChooseDirectories":true,
          "allowMultipleSelection":false,"showHiddenFiles":true},"children":[]}
        """#
    ).fields
    #expect(fields[0].kind == .filePicker && fields[0].isEditable)
    #expect(fields[0].files == FilePickerOptions(), "Raycast's defaults")
    let defaults = try #require(fields[0].files)
    #expect(defaults.canChooseFiles && !defaults.canChooseDirectories && defaults.allowsMultipleSelection)
    #expect(!defaults.showsHiddenFiles)
    let folder = try #require(fields[1].files)
    #expect(!folder.canChooseFiles && folder.canChooseDirectories && !folder.allowsMultipleSelection)
    #expect(folder.showsHiddenFiles)
    #expect(fields[0].initialValue() == .array([]) && fields[0].registeredValue == .array([]))

    // Multiple: added after what's there, each once, in the order chosen. Single: in place of it.
    let current = ["/a", "/b"]
    #expect(FilePicking.choosing(["/c", "/a", "/d"], to: current, options: defaults) == ["/a", "/b", "/c", "/d"])
    #expect(FilePicking.choosing(["/c"], to: current, options: folder) == ["/c"])
    #expect(FilePicking.removing("/a", from: current) == ["/b"])
}

@Test func storedDatesAndPathsStartTheirFields() throws {
    let fields = try form(
        #"""
        {"id":2,"type":"Form.DatePicker","props":{"id":"due","storeValue":true},"children":[]},
        {"id":3,"type":"Form.FilePicker","props":{"id":"files","storeValue":true},"children":[]}
        """#
    ).fields
    let stored: JSONValue = .object(["$date": .string("2026-11-20T12:00:00.000Z")])
    #expect(fields[0].initialValue(stored: stored) == stored)
    #expect(fields[0].initialValue(stored: .string("tomorrow")) == .null, "not a date")
    #expect(fields[1].initialValue(stored: .array([.string("/a")])) == .array([.string("/a")]))
    #expect(fields[1].initialValue(stored: .array([.number(1)])) == .array([]))
}
