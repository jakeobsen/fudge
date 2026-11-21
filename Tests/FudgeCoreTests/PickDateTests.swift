import Foundation
import Testing

@testable import FudgeCore

// Form.LinkAccessory and Action.PickDate (FUD-82).

private func node(_ json: String) throws -> UINode {
    try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
}

private func formWithAccessory(_ accessory: String?, children: String = "") throws -> FormContent {
    let props = accessory.map { #"{"searchBarAccessory":"# + $0 + "}" } ?? "{}"
    return FormContent(try node(#"{"id":1,"type":"Form","props":"# + props + #","children":["# + children + "]}"))
}

private let copenhagen: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
    return calendar
}()

private func date(_ iso: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
}

private func key(_ name: String, _ modifiers: Set<String> = []) -> KeyShortcut {
    KeyShortcut(key: name, modifiers: modifiers)
}

// MARK: - Form.LinkAccessory

@Test func readsAFormsLinkAccessory() throws {
    let form = try formWithAccessory(
        #"""
        {"id":9,"type":"Form.LinkAccessory","props":{"text":"Open Documentation",
          "target":"https://developers.raycast.com/api-reference/user-interface/form"},"children":[]}
        """#)
    #expect(
        form.linkAccessory
            == LinkAccessory(
                text: "Open Documentation", target: "https://developers.raycast.com/api-reference/user-interface/form"))
    #expect(try formWithAccessory(nil).linkAccessory == nil, "a Form without one")
}

@Test func ignoresAnythingButALinkAccessoryWithTextAndTarget() throws {
    let wrong = #"{"id":9,"type":"List.Dropdown","props":{"text":"x","target":"https://example.com"},"children":[]}"#
    #expect(try formWithAccessory(wrong).linkAccessory == nil, "another element")
    let noText =
        #"{"id":9,"type":"Form.LinkAccessory","props":{"text":"","target":"https://example.com"},"children":[]}"#
    #expect(try formWithAccessory(noText).linkAccessory == nil, "empty text")
    let blankText =
        #"{"id":9,"type":"Form.LinkAccessory","props":{"text":"  ","target":"https://example.com"},"children":[]}"#
    #expect(try formWithAccessory(blankText).linkAccessory == nil, "blank text")
    let noTarget = #"{"id":9,"type":"Form.LinkAccessory","props":{"text":"Docs"},"children":[]}"#
    #expect(try formWithAccessory(noTarget).linkAccessory == nil, "no target")
    let emptyTarget = #"{"id":9,"type":"Form.LinkAccessory","props":{"text":"Docs","target":""},"children":[]}"#
    #expect(try formWithAccessory(emptyTarget).linkAccessory == nil, "empty target")
    #expect(try formWithAccessory(#""not a node""#).linkAccessory == nil, "not a node at all")
}

@Test func aLinkAccessoryAmongTheFieldsStaysSkipped() throws {
    let form = try formWithAccessory(
        nil,
        children: #"""
            {"id":2,"type":"Form.TextField","props":{"id":"name"},"children":[]},
            {"id":3,"type":"Form.LinkAccessory","props":{"text":"Docs","target":"https://example.com"},"children":[]}
            """#)
    #expect(form.fields.map(\.kind) == [.textField], "not a field, and not drawn as unsupported")
    #expect(form.linkAccessory == nil, "only the searchBarAccessory prop counts")
}

// MARK: - Reading Action.PickDate

private let pickDatePanel = #"""
    {"id":20,"type":"ActionPanel","props":{},"children":[
      {"id":21,"type":"Action","props":{"title":"Pick Due Date…","icon":"calendar-16",
        "shortcut":{"modifiers":["cmd"],"key":"d"},"pickDate":{"type":"date_time"},
        "onChange":{"$fn":["onChange"]}},"children":[]},
      {"id":22,"type":"ActionPanel.Submenu","props":{"title":"More"},"children":[
        {"id":23,"type":"Action","props":{"title":"Pick Day…","pickDate":{"type":"date",
          "min":{"$date":"2026-11-21T00:00:00.000Z"},"max":{"$date":"2026-12-21T00:00:00.000Z"}},
          "onChange":{"$fn":["onChange"]}},"children":[]}]},
      {"id":24,"type":"Action","props":{"title":"Copy","onAction":{"$fn":["onAction"]}},"children":[]},
      {"id":25,"type":"Action","props":{"title":"No Callback","pickDate":{"type":"date"}},"children":[]},
      {"id":26,"type":"Action","props":{"title":"Defaults","pickDate":{},"onChange":{"$fn":["onChange"]}},"children":[]}
    ]}
    """#

@Test func readsAPickDateEntry() throws {
    let sections = ActionPanelReader.sections(of: try node(pickDatePanel))
    let entries = ActionPanelReader.flat(sections)
    #expect(entries[0].pickDate == DatePickerOptions(type: .dateTime))
    #expect(entries[0].shortcut == key("d", ["cmd"]))
    #expect(entries[0].target == .node(21), "the pick goes to the node's onChange")
    let day = try #require(ActionPanelReader.entry(id: 23, in: sections), "found inside a submenu")
    #expect(
        day.pickDate
            == DatePickerOptions(
                type: .date, min: date("2026-11-21T00:00:00.000Z"), max: date("2026-12-21T00:00:00.000Z"))
    )
    #expect(entries[2].pickDate == nil, "an ordinary action")
    #expect(entries[3].pickDate == nil, "no onChange to call: an ordinary action")
    #expect(entries[4].pickDate == DatePickerOptions(), "DateTime by default, with no limits")
    #expect(ActionPanelReader.entry(titled: "Pick Day…", in: sections)?.id == 23)
    #expect(
        ActionPanelReader.entry(titled: "Copy", in: sections, where: { $0.pickDate != nil }) == nil,
        "only a PickDate, for --pick-date")
    #expect(ActionPanelReader.entry(titled: "More", in: sections) == nil, "a submenu isn't an action")
    #expect(ActionPanelReader.entry(id: 99, in: sections) == nil)
}

@Test func aPickDateWithMinAfterMaxHasNoLimits() throws {
    let panel = try node(
        #"""
        {"id":20,"type":"ActionPanel","props":{},"children":[
          {"id":21,"type":"Action","props":{"title":"Pick","pickDate":{"type":"date",
            "min":{"$date":"2026-12-21T00:00:00.000Z"},"max":{"$date":"2026-11-21T00:00:00.000Z"}},
            "onChange":{"$fn":["onChange"]}},"children":[]}]}
        """#)
    #expect(
        ActionPanelReader.flat(ActionPanelReader.sections(of: panel)).first?.pickDate == DatePickerOptions(type: .date))
}

// MARK: - The picker

/// Friday 20 November 2026, 10:15:42 in Copenhagen.
private let now = date("2026-11-20T09:15:42.500Z")

private func picker(_ options: DatePickerOptions = DatePickerOptions(), fromList: Bool = true) -> DatePick {
    DatePick(
        node: 21, title: "Pick Due Date…", options: options, openedFromList: fromList, now: now, calendar: copenhagen)
}

@Test func thePickerStartsOnTodayAndTheCurrentTimeInWholeMinutes() {
    let pick = picker()
    #expect(pick.month.day == date("2026-11-19T23:00:00.000Z"), "today, at local midnight")
    #expect(pick.time == date("2026-11-20T09:15:00.000Z"), "the current time, in whole minutes")
    #expect(pick.focus == .calendar)
    #expect(pick.title == "Pick Due Date…" && pick.node == 21)
    let later = picker(DatePickerOptions(min: date("2026-12-01T10:00:00.000Z")))
    #expect(later.month.day == date("2026-11-30T23:00:00.000Z"), "today isn't allowed: min's day")
}

@Test func returnSpaceAndAClickPickOnce() {
    var dateTime = picker()
    #expect(dateTime.handle(key("arrowRight"), calendar: copenhagen) == .handled)
    #expect(
        dateTime.handle(key("return"), calendar: copenhagen) == .pick(date("2026-11-21T09:15:00.000Z")),
        "tomorrow at the current time, in whole minutes")
    #expect(dateTime.handle(key("enter"), calendar: copenhagen) == .pick(date("2026-11-21T09:15:00.000Z")))

    var day = picker(DatePickerOptions(type: .date))
    #expect(day.handle(key("arrowDown"), calendar: copenhagen) == .handled)
    #expect(
        day.handle(key("space"), calendar: copenhagen) == .pick(date("2026-11-26T23:00:00.000Z")),
        "a week on, at local midnight")

    var clicked = picker(DatePickerOptions(type: .date))
    #expect(
        clicked.click(date("2026-12-24T12:00:00.000Z"), calendar: copenhagen) == .pick(date("2026-12-23T23:00:00.000Z"))
    )
}

@Test func escapeCallsNothingAndGoesBackOrCloses() {
    var fromList = picker(fromList: true)
    #expect(fromList.handle(key("escape"), calendar: copenhagen) == .backToList)
    var straight = picker(fromList: false)
    #expect(straight.handle(key("escape"), calendar: copenhagen) == .close)
    straight.focus(.time)
    #expect(straight.handle(key("escape"), calendar: copenhagen) == .close, "from the time too")
}

@Test func deleteClearsOnlyFromTheCalendar() {
    var pick = picker()
    #expect(pick.handle(key("delete"), calendar: copenhagen) == .clear)
    pick.focus(.time)
    #expect(pick.handle(key("delete"), calendar: copenhagen) == .ignored, "the time field's own ⌫")
}

@Test func theCalendarsKeysMoveWithinTheLimits() {
    let options = DatePickerOptions(
        type: .date, min: date("2026-11-18T00:00:00.000Z"), max: date("2026-12-05T00:00:00.000Z"))
    var pick = picker(options)
    for _ in 0..<5 { _ = pick.handle(key("arrowLeft"), calendar: copenhagen) }
    #expect(pick.month.day == date("2026-11-17T23:00:00.000Z"), "stops at min's day")
    _ = pick.handle(key("pageDown"), calendar: copenhagen)
    #expect(pick.month.day == date("2026-12-04T23:00:00.000Z"), "a month on, stopped at max's day")
    _ = pick.handle(key("arrowUp"), calendar: copenhagen)
    #expect(pick.month.day == date("2026-11-27T23:00:00.000Z"), "a week back")
    _ = pick.handle(key("pageUp"), calendar: copenhagen)
    #expect(pick.month.day == date("2026-11-17T23:00:00.000Z"), "a month back, stopped at min's day")
    #expect(
        pick.click(date("2026-12-24T12:00:00.000Z"), calendar: copenhagen) == .handled, "a day past max can't be picked"
    )
    #expect(pick.month.day == date("2026-11-17T23:00:00.000Z"), "and the highlight stays")
}

@Test func typingFiltersNothing() {
    var pick = picker()
    #expect(pick.handle(key("a"), calendar: copenhagen) == .handled)
    #expect(pick.handle(key("a", ["shift"]), calendar: copenhagen) == .handled)
    #expect(pick.handle(key("arrowLeft", ["shift"]), calendar: copenhagen) == .handled, "taken, but no move")
    #expect(pick.month.day == date("2026-11-19T23:00:00.000Z"))
    #expect(pick.handle(key("c", ["cmd"]), calendar: copenhagen) == .ignored, "⌘, ⌥ and ⌃ keys aren't the picker's")
}

@Test func tabMovesBetweenTheCalendarAndADateTimesTime() {
    var pick = picker()
    #expect(pick.handle(key("tab"), calendar: copenhagen) == .handled)
    #expect(pick.focus == .time)
    #expect(pick.handle(key("arrowUp"), calendar: copenhagen) == .ignored, "the time field's keys")
    #expect(pick.handle(key("5"), calendar: copenhagen) == .ignored)
    #expect(
        pick.handle(key("return"), calendar: copenhagen) == .pick(date("2026-11-20T09:15:00.000Z")),
        "↵ picks from there")
    #expect(pick.handle(key("tab", ["shift"]), calendar: copenhagen) == .handled)
    #expect(pick.focus == .calendar)

    var day = picker(DatePickerOptions(type: .date))
    #expect(day.handle(key("tab"), calendar: copenhagen) == .handled)
    #expect(day.focus == .calendar, "a Date picker has no time")
}

@Test func aDateTimePickIsTheDayAtTheTimeInWholeMinutesWithinTheLimits() {
    var pick = picker()
    pick.setTime(date("2026-11-20T16:45:59.900Z"), calendar: copenhagen)
    #expect(pick.time == date("2026-11-20T16:45:00.000Z"), "whole minutes")
    _ = pick.handle(key("arrowRight"), calendar: copenhagen)
    #expect(pick.value(calendar: copenhagen) == date("2026-11-21T16:45:00.000Z"), "the calendar's day, the time's time")

    // min and max with seconds: the first and last whole minutes within them.
    let limited = DatePickerOptions(min: date("2026-11-20T09:30:30.000Z"), max: date("2026-11-21T08:00:30.000Z"))
    var early = picker(limited)
    early.setTime(date("2026-11-20T06:00:00.000Z"), calendar: copenhagen)
    #expect(early.value(calendar: copenhagen) == date("2026-11-20T09:31:00.000Z"), "clamped up to min")
    var late = picker(limited)
    _ = late.handle(key("arrowRight"), calendar: copenhagen)
    late.setTime(date("2026-11-20T22:00:00.000Z"), calendar: copenhagen)
    #expect(late.value(calendar: copenhagen) == date("2026-11-21T08:00:00.000Z"), "clamped down to max")
}

@Test func aDatePickIsLocalMidnightWithinTheLimits() {
    let options = DatePickerOptions(type: .date, min: date("2026-11-25T15:00:00.000Z"))
    let pick = picker(options)
    #expect(pick.value(calendar: copenhagen) == date("2026-11-24T23:00:00.000Z"), "min's day, at local midnight")
    #expect(FormDates.isFullDay(pick.value(calendar: copenhagen), calendar: copenhagen))
}

@Test func aRenderRetitlesThePickerOrClosesItWhenItsActionIsGone() throws {
    func entry(_ props: String) throws -> ActionEntry? {
        let panel = try node(
            #"{"id":20,"type":"ActionPanel","props":{},"children":[{"id":21,"type":"Action","props":"# + props
                + #","children":[]}]}"#)
        return ActionPanelReader.entry(id: 21, in: ActionPanelReader.sections(of: panel))
    }
    var pick = DatePick(
        node: 21, title: "Set Due Date", options: DatePickerOptions(), openedFromList: true,
        now: date("2026-11-20T09:15:30.000Z"), calendar: copenhagen)
    _ = pick.handle(key("arrowRight"), calendar: copenhagen)

    let retitled = try #require(
        pick.following(
            try entry(#"{"title":"Change Due Date","pickDate":{},"onChange":{"$fn":["onChange"]}}"#),
            calendar: copenhagen))
    #expect(retitled.title == "Change Due Date", "the heading follows the action's title")
    #expect(retitled.month.day == pick.month.day, "the highlighted day stays")
    #expect(retitled.time == pick.time && retitled.node == 21 && retitled.openedFromList)

    let limited = try #require(
        pick.following(
            try entry(
                #"{"title":"Set Due Date","pickDate":{"type":"date","max":{"$date":"2026-11-20T12:00:00.000Z"}},"#
                    + #""onChange":{"$fn":["onChange"]}}"#), calendar: copenhagen))
    #expect(limited.title == "Set Due Date")
    #expect(limited.options.type == .date, "a new type: the picker follows it, and stays open")
    #expect(limited.month.day == date("2026-11-19T23:00:00.000Z"), "and keeps within the new limits")
    var timed = limited
    timed.focus(.time)
    #expect(timed.focus == .calendar, "a Date picker has no time")
    let back = try #require(
        limited.following(
            try entry(#"{"title":"Set Due Date","pickDate":{"type":"date_time"},"onChange":{"$fn":["onChange"]}}"#),
            calendar: copenhagen))
    #expect(back.options.type == .dateTime, "and back to DateTime")
    #expect(back.month.day == limited.month.day && back.time == pick.time, "the day and the time stay")

    #expect(pick.following(nil, calendar: copenhagen) == nil, "the action is gone")
    #expect(
        pick.following(try entry(#"{"title":"Set Due Date","onAction":{"$fn":["onAction"]}}"#), calendar: copenhagen)
            == nil, "no longer an Action.PickDate")
}

@Test func aRenderKeepsTheHighlightedDayWithinNewLimits() {
    var pick = picker()
    _ = pick.handle(key("pageDown"), calendar: copenhagen)
    #expect(pick.month.day == date("2026-12-19T23:00:00.000Z"))
    pick.update(options: DatePickerOptions(), calendar: copenhagen)
    #expect(pick.month.day == date("2026-12-19T23:00:00.000Z"), "the same options change nothing")
    pick.focus(.time)
    pick.update(options: DatePickerOptions(type: .date, max: date("2026-12-10T12:00:00.000Z")), calendar: copenhagen)
    #expect(pick.month.day == date("2026-12-09T23:00:00.000Z"), "kept within the new max")
    #expect(pick.options.type == .date)
    #expect(pick.focus == .calendar, "a Date picker has no time to keep the keyboard")
    #expect(pick.time == date("2026-11-20T09:15:00.000Z"), "the time stays")
}
