import Foundation
import Testing

@testable import FudgeCore

/// A fixed calendar, zone and locale: Monday 23 November 2026, 08:30 UTC, written as in en_GB.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let british = Locale(identifier: "en_GB")
private let now = ISO8601DateFormatter().date(from: "2026-11-23T08:30:00Z")!

private func at(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-11-\(time):00Z")! }

private func event(
    _ title: String, _ start: String, _ end: String, allDay: Bool = false, calendar: String = "work",
    location: String? = nil, notes: String? = nil, url: String? = nil, attendees: Int = 0
) -> CalendarEvent {
    CalendarEvent(
        identifier: "EK-\(title)", title: title, start: at(start), end: at(end), isAllDay: allDay,
        calendarID: calendar, location: location, notes: notes, url: url.flatMap(URL.init(string:)),
        attendees: attendees)
}

private let calendars = [
    CalendarInfo(id: "work", title: "Work", color: "#0A84FF"),
    CalendarInfo(id: "home", title: "Home", color: "#30D158"),
]

// MARK: - Meeting links (MUST 1)

@Test func eachKnownServiceIsFoundOverHTTPS() {
    let links = [
        ("https://zoom.us/j/123456789", "Zoom"), ("https://us02web.zoom.us/j/123?pwd=abc", "Zoom"),
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting", "Microsoft Teams"),
        ("https://teams.live.com/meet/123", "Microsoft Teams"), ("https://acme.webex.com/meet/someone", "Webex"),
        ("https://facetime.apple.com/join#v=1&p=abc", "FaceTime"), ("https://whereby.com/team-room", "Whereby"),
        ("https://around.co/r/standup", "Around"), ("https://meet.jit.si/SomeRoom", "Jitsi"),
        ("zoommtg://zoom.us/join?confno=123", "Zoom"), ("zoommtg://us02web.zoom.us/join?confno=1", "Zoom"),
        ("msteams://teams.microsoft.com/l/meetup-join/19%3ameeting", "Microsoft Teams"),
        ("HTTPS://ZOOM.US/j/1", "Zoom"),
    ]
    for (text, service) in links {
        #expect(MeetingLinks.first(in: text)?.service == service, "\(text)")
    }
    #expect(MeetingLinks.first(in: "https://zoom.us./j/1")?.service == "Zoom", "a trailing dot is the same host")
}

@Test func onlyTheParsedSchemeAndHostCount() {
    let refused = [
        "https://zoom.us.evil.example/j/1", "https://evil.example/zoom.us", "https://evil.example/?u=https://zoom.us",
        "https://notzoom.us/j/1", "https://zoom.us@evil.example/j/1", "https://evil.example@zoom.us/j/1",
        "http://zoom.us/j/1", "file:///Users/someone/zoom.us", "javascript:alert('zoom.us')",
        "x-apple.systempreferences:com.apple.preference.security", "ftp://zoom.us/j/1", "data:text/html,zoom.us",
        "https://example.com/docs", "zoom.us", "https://zoom.us", "https://meet.google.com/", "Meet me at the zoo.",
        // An app's own scheme only on that service's hosts, and FaceTime's not at all: it calls whoever it names.
        "facetime://attacker@evil.example", "facetime:someone@example.com", "zoommtg://evil.example/join?action=start",
        "msteams://evil.example/x", "msteams:/l/meetup-join/x", "zoommtg://user@zoom.us/join",
        "zoommtg://teams.microsoft.com/join", "msteams://zoom.us/x",
        // A host written plainly only.
        "https://evil.example%2F.zoom.us/j/1", "https://zo%6Fm.us/j/1",
    ]
    for text in refused {
        #expect(MeetingLinks.first(in: text) == nil, "\(text)")
    }
}

@Test func aLinkIsFoundInTheURLThenTheLocationThenTheNotes() throws {
    var standup = event(
        "Standup", "23T09:00", "23T09:15", location: "Room 4 or https://meet.google.com/aaa-bbbb-ccc",
        notes: "Agenda.\nJoin: https://zoom.us/j/111.", url: "https://teams.microsoft.com/l/meetup-join/x")
    #expect(MeetingLinks.find(in: standup)?.service == "Microsoft Teams")
    standup.url = URL(string: "https://example.com/agenda")
    #expect(MeetingLinks.find(in: standup)?.service == "Google Meet", "a URL that isn't a meeting is skipped")
    standup.location = "Room 4"
    let fromNotes = try #require(MeetingLinks.find(in: standup))
    #expect(fromNotes.url.absoluteString == "https://zoom.us/j/111", "the sentence's full stop isn't the link's")
    let html = #"<p>Join <a href="https://acme.webex.com/meet/x">here</a></p>"#
    #expect(MeetingLinks.first(in: html)?.url.absoluteString == "https://acme.webex.com/meet/x")
    let markdown = "[Join](https://meet.jit.si/Room), or (https://whereby.com/room)."
    #expect(MeetingLinks.first(in: markdown)?.url.absoluteString == "https://meet.jit.si/Room")
    #expect(
        MeetingLinks.first(in: "Dial in: meet.google.com/abc-defg-hij")?.url.absoluteString
            == "https://meet.google.com/abc-defg-hij", "no scheme reads as https")
    #expect(MeetingLinks.find(in: event("Lunch", "23T12:00", "23T13:00", notes: "No link here")) == nil)
}

@Test func onlyTheStartOfLongNotesIsLookedThrough() throws {
    let padding = String(repeating: "lorem ipsum ", count: 90_000)  // about 1 MB
    let late = event("Late", "23T10:00", "23T11:00", notes: padding + " https://zoom.us/j/1")
    #expect(MeetingLinks.find(in: late) == nil, "a link past the first \(MeetingLinks.searchedLength) characters")
    let early = event("Early", "23T10:00", "23T11:00", notes: "https://meet.google.com/abc-defg-hij " + padding)
    #expect(MeetingLinks.find(in: early)?.service == "Google Meet")
    let lateLocation = event("Where", "23T10:00", "23T11:00", location: padding + " https://zoom.us/j/1")
    #expect(MeetingLinks.find(in: lateLocation) == nil)

    // Twenty invites of a megabyte each draw in well under a second in a release build; the bound is loose for CI.
    let invites = (0..<20).map { event("Invite \($0)", "23T10:00", "23T11:00", location: padding, notes: padding) }
    let started = ContinuousClock.now
    let view = ScheduleList.view(content(invites), showingDetail: true, now: now, calendar: utc, locale: british)
    let list = ListContent(view, searchText: "")
    #expect(list.items.count == 20)
    #expect(ContinuousClock.now - started < .seconds(20))
    let markdown = try #require(list.items.first?.detail?.string("markdown"))
    #expect(markdown.count < ScheduleList.notesLimit + 20, "the detail holds only the start")
}

// MARK: - Days

@Test func daysAreTodayTomorrowThenTheirDatesWithAllDayFirst() {
    let events = [
        event("Review", "23T14:00", "23T15:00"), event("Offsite", "23T00:00", "24T00:00", allDay: true),
        event("Standup", "23T09:00", "23T09:15"), event("Planning", "24T10:00", "24T11:00"),
        event("Retro", "25T16:00", "25T17:00"), event("Breakfast", "23T07:00", "23T08:00"),
    ]
    let days = Schedule.days(events, now: now, daysAhead: 7, calendar: utc, locale: british)
    #expect(days.map(\.title) == ["Today", "Tomorrow", "Wednesday 25 November"])
    #expect(days[0].events.map(\.title) == ["Offsite", "Standup", "Review"], "what's over is gone")
    #expect(days[1].events.map(\.title) == ["Planning"])
    #expect(days.allSatisfy { !$0.events.isEmpty }, "days without events aren't shown")
}

@Test func anEventSpanningDaysIsOnEachAndSaysSo() throws {
    let trip = event("Trip", "23T18:00", "25T10:00")
    let days = Schedule.days([trip], now: now, daysAhead: 7, calendar: utc, locale: british)
    #expect(days.map(\.title) == ["Today", "Tomorrow", "Wednesday 25 November"])
    let times = days.map { Schedule.time(of: trip, on: $0.interval, calendar: utc, locale: british) }
    #expect(times == ["From 18:00", "All day", "Until 10:00"])
    let holiday = event("Holiday", "24T00:00", "26T00:00", allDay: true)
    let holidays = Schedule.days([holiday], now: now, daysAhead: 7, calendar: utc, locale: british)
    #expect(holidays.map(\.title) == ["Tomorrow", "Wednesday 25 November"], "midnight ends the last day")
    #expect(Schedule.time(of: holiday, on: holidays[0].interval, calendar: utc, locale: british) == "All day")
    let standup = event("Standup", "23T09:00", "23T09:15")
    let today = try #require(Schedule.days([standup], now: now, daysAhead: 1, calendar: utc, locale: british).first)
    #expect(Schedule.time(of: standup, on: today.interval, calendar: utc, locale: british) == "09:00 – 09:15")
}

@Test func daysAheadSetsTheWindow() {
    let events = [
        event("Today", "23T10:00", "23T11:00"), event("Tomorrow", "24T10:00", "24T11:00"),
        event("In three days", "26T10:00", "26T11:00"), event("In a week", "30T10:00", "30T11:00"),
    ]
    func titles(_ ahead: Int) -> [String] {
        Schedule.days(events, now: now, daysAhead: ahead, calendar: utc, locale: british).flatMap {
            $0.events.map(\.title)
        }
    }
    #expect(titles(1) == ["Today", "Tomorrow"])
    #expect(titles(3) == ["Today", "Tomorrow", "In three days"])
    #expect(titles(7) == ["Today", "Tomorrow", "In three days", "In a week"])
    let window = Schedule.window(now: now, daysAhead: 7, calendar: utc)
    #expect(window.start == at("23T00:00") && window.end == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    #expect(Schedule.daysAheadChoices == [1, 3, 7, 14] && Schedule.defaultDaysAhead == 7)
}

@Test func nowAndInMinutesMarkWhatsHappening() {
    #expect(Schedule.accessory(of: event("A", "23T08:00", "23T09:00"), now: now) == "Now")
    #expect(Schedule.accessory(of: event("B", "23T08:42", "23T09:00"), now: now) == "in 12 min")
    let soon = CalendarEvent(
        identifier: "c", title: "C", start: now.addingTimeInterval(30), end: now.addingTimeInterval(600),
        calendarID: "work")
    #expect(Schedule.accessory(of: soon, now: now) == "in 1 min", "rounded up, never \"in 0 min\"")
    #expect(Schedule.accessory(of: event("D", "23T09:30", "23T10:00"), now: now) == "in 60 min")
    #expect(Schedule.accessory(of: event("E", "23T09:31", "23T10:00"), now: now) == nil, "more than an hour")
    #expect(Schedule.accessory(of: event("F", "23T00:00", "24T00:00", allDay: true), now: now) == nil)
}

@Test func untickedCalendarsAreLeftOutAndNewOnesShow() async {
    let source = FixedCalendarSource(
        access: .fullAccess, calendars: calendars + [CalendarInfo(id: "new", title: "New", color: "#FF9F0A")],
        events: [
            event("Work", "23T10:00", "23T11:00", calendar: "work"),
            event("Home", "23T10:00", "23T11:00", calendar: "home"),
            event("New", "23T10:00", "23T11:00", calendar: "new"),
        ])
    let shown = Schedule.shownCalendars(source.calendars(), hidden: ["home"])
    #expect(shown == ["work", "new"])
    let window = Schedule.window(now: now, daysAhead: 7, calendar: utc)
    #expect(source.events(from: window.start, to: window.end, calendars: shown).map(\.title) == ["Work", "New"])
}

@Test func theFixedSourceAsksNothingAndReadsNothingWithoutAccess() async {
    let source = FixedCalendarSource(
        access: .notDetermined, calendars: calendars, events: [event("A", "23T10:00", "23T11:00")],
        answer: .denied)
    #expect(source.calendars().isEmpty)
    #expect(await source.requestAccess() == false)
    #expect(source.authorization == .denied && source.requests == 1)
    #expect(source.events(from: .distantPast, to: .distantFuture, calendars: ["work"]).isEmpty)
}

@Test func calendarSettingsAreSavedAndReadBack() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    var settings = FudgeSettings()
    #expect(settings.calendarHidden.isEmpty && settings.calendarDaysAhead == 7)
    try settings.save(to: file)
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "{\n\n}", "defaults aren't written")
    settings.calendarHidden = ["home"]
    settings.calendarDaysAhead = 14
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file) == settings)
    try Data(#"{"calendarDaysAhead": 5, "calendarHidden": ["a", 3]}"#.utf8).write(to: file)
    let odd = FudgeSettings.load(from: file)
    #expect(odd.calendarDaysAhead == 7, "not a choice: the default")
    #expect(odd.calendarHidden == ["a"])
}

// MARK: - The view (MUSTs 2 and 3)

private func content(_ events: [CalendarEvent], daysAhead: Int = 7) -> ScheduleList.Content {
    .days(
        Schedule.days(events, now: now, daysAhead: daysAhead, calendar: utc, locale: british), calendars: calendars,
        daysAhead: daysAhead)
}

@Test func theListHasASectionPerDayAndARowPerEvent() throws {
    let events = [
        event(
            "Standup", "23T08:20", "23T08:45", location: "Room 4", url: "https://zoom.us/j/1", attendees: 6),
        event("Dentist", "23T09:00", "23T09:30", calendar: "home"),
        event("Planning", "24T10:00", "24T11:00"),
    ]
    let view = ScheduleList.view(content(events), now: now, calendar: utc, locale: british)
    let list = ListContent(view, searchText: "")
    #expect(!list.isShowingDetail, "the rows' times and Now show until Show Details")
    #expect(
        ListContent(
            ScheduleList.view(content(events), showingDetail: true, now: now, calendar: utc, locale: british),
            searchText: ""
        ).isShowingDetail)
    #expect(list.sections.map(\.title) == ["Today", "Tomorrow"])
    #expect(list.items.map(\.title) == ["Standup", "Dentist", "Planning"])
    #expect(list.items.map(\.subtitle) == ["08:20 – 08:45", "09:00 – 09:30", "10:00 – 11:00"])
    #expect(list.items.map { $0.accessories.first?.text } == ["Now", "in 30 min", nil])
    // An event spanning days is on now only on today's row.
    let trip = event("Trip", "22T18:00", "24T10:00")
    let tripList = ListContent(
        ScheduleList.view(content([trip]), now: now, calendar: utc, locale: british), searchText: "")
    #expect(tripList.items.map { $0.accessories.first?.text } == ["Now", nil])
    let standup = try #require(list.items.first)
    #expect(
        MetadataEntry.entries(of: standup.detail?.node("metadata")).map { entry -> String in
            guard case .label(let title, let text, _, _) = entry else { return "" }
            return "\(title): \(text ?? "")"
        } == [
            "Time: Today, 08:20 – 08:45", "Location: Room 4", "Calendar: Work", "Invited: 6", "Meeting: Zoom",
        ])
    // Raycast's filtering finds an event by its calendar and location too.
    var searched = list
    searched.search("home")
    #expect(searched.items.map(\.title) == ["Dentist"])
}

@Test func rowIdsArePositionsNeverTheEvent() {
    let events = [event("Secret board meeting", "23T10:00", "23T11:00"), event("Lunch", "23T12:00", "23T13:00")]
    let list = ListContent(ScheduleList.view(content(events), now: now, calendar: utc, locale: british), searchText: "")
    #expect(list.items.map(\.itemId) == ["event-0", "event-1"])
    for item in list.items {
        #expect(!(item.itemId ?? "").contains("EK-") && !(item.itemId ?? "").contains("Secret"))
    }
}

@Test func notesAreLiteralTextSoNothingInThemLoads() throws {
    let notes = """
        ![](https://tracker.example/open.png)
        <img src="https://tracker.example/pixel.gif">
        # Not a heading
        ```
        Closing fence
        """
    let invite = event("Invite", "23T10:00", "23T11:00", notes: "  \(notes)\n\n")
    let list = ListContent(
        ScheduleList.view(content([invite]), now: now, calendar: utc, locale: british), searchText: "")
    let markdown = try #require(list.items.first?.detail?.string("markdown"))
    #expect(Markdown.blocks(markdown) == [.code(language: nil, text: notes)], "one code block, nothing else")
    #expect(!Markdown.blocks(markdown).contains { if case .image = $0 { true } else { false } })
    let long = event("Long", "23T10:00", "23T11:00", notes: String(repeating: "a", count: 6_000))
    let longList = ListContent(
        ScheduleList.view(content([long]), now: now, calendar: utc, locale: british), searchText: "")
    let cut = try #require(longList.items.first?.detail?.string("markdown"))
    #expect(Markdown.blocks(cut) == [.code(language: nil, text: String(repeating: "a", count: 5_000) + "…")])
    let none = event("None", "23T10:00", "23T11:00")
    let noneList = ListContent(
        ScheduleList.view(content([none]), now: now, calendar: utc, locale: british), searchText: "")
    #expect(noneList.items.first?.detail?.string("markdown") == "")
}

@Test func itsActionsJoinOpenAndCopy() throws {
    let events = [
        event("Standup", "23T10:00", "23T10:15", location: "Room 4", notes: "https://meet.google.com/abc-defg-hij"),
        event("Lunch", "23T12:00", "23T13:00"),
    ]
    let shown = content(events)
    let list = ListContent(ScheduleList.view(shown, now: now, calendar: utc, locale: british), searchText: "")
    func targets(_ item: ListContent.Item) -> [(String, KeyShortcut?, ScheduleList.Target?)] {
        ActionPanelReader.sections(of: item.actions).flatMap(\.entries).map { entry in
            guard case .node(let node) = entry.target else { return (entry.title, entry.shortcut, nil) }
            return (
                entry.title, entry.shortcut, ScheduleList.target(of: node, in: shown, calendar: utc, locale: british)
            )
        }
    }
    let standup = targets(list.items[0])
    #expect(
        standup.map(\.0) == ["Join Meeting", "Open in Calendar", "Copy Meeting Link", "Copy Details", "Show Details"])
    #expect(
        standup.map(\.1) == [
            nil, ScheduleList.openShortcut, ScheduleList.copyLinkShortcut, nil, ScheduleList.detailShortcut,
        ])
    #expect(standup[4].2 == .toggleDetail)
    let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
    #expect(standup[0].2 == .join(meet))
    #expect(standup[1].2 == .openInCalendar(URL(string: "ical://ekevent/EK-Standup?method=show&options=more")!))
    #expect(standup[2].2 == .copyLink(meet))
    #expect(standup[3].2 == .copyDetails("Standup\nToday, 10:00 – 10:15\nRoom 4\nhttps://meet.google.com/abc-defg-hij"))
    let lunch = targets(list.items[1])
    #expect(
        lunch.map(\.0) == ["Open in Calendar", "Copy Details", "Show Details"],
        "↵ opens it in Calendar when there's no link")
    let shownDetail = ListContent(
        ScheduleList.view(shown, showingDetail: true, now: now, calendar: utc, locale: british), searchText: "")
    #expect(targets(shownDetail.items[1]).map(\.0).last == "Hide Details")
    #expect(ScheduleList.target(of: list.items[0].id, in: shown, calendar: utc, locale: british) == nil)
    #expect(ScheduleList.target(of: 100 + 20 * 2 + 9, in: shown, calendar: utc, locale: british) == nil, "past the end")
}

@Test func anIdentifierIsPercentEncodedInTheCalendarLink() {
    var odd = event("Odd", "23T10:00", "23T11:00")
    odd.identifier = "a/b?c#d e"
    #expect(
        Schedule.calendarURL(of: odd)?.absoluteString == "ical://ekevent/a%2Fb%3Fc%23d%20e?method=show&options=more")
    odd.identifier = ""
    #expect(Schedule.calendarURL(of: odd) == nil)
}

@Test func askingRefusedAndEmptyEachHaveTheirView() throws {
    let asking = ListContent(ScheduleList.view(.asking, now: now, calendar: utc, locale: british), searchText: "")
    #expect(asking.isLoading && asking.items.isEmpty)

    let refusedView = ScheduleList.view(.refused, now: now, calendar: utc, locale: british)
    let refused = ListContent(refusedView, searchText: "")
    #expect(refused.emptyView?.title == "Calendar access is off")
    let refusedEntries = ActionPanelReader.sections(of: refused.emptyView?.actions).flatMap(\.entries)
    let privacy = try #require(refusedEntries.first)
    #expect(privacy.title == "Open Privacy Settings")
    guard case .node(let node) = privacy.target else {
        Issue.record("Open Privacy Settings runs a node")
        return
    }
    #expect(ScheduleList.target(of: node, in: .refused, calendar: utc, locale: british) == .openPrivacySettings)
    #expect(ScheduleList.privacySettingsURL.scheme == "x-apple.systempreferences")

    let none = content([])
    let empty = ListContent(ScheduleList.view(none, now: now, calendar: utc, locale: british), searchText: "")
    #expect(empty.emptyView?.title == "No upcoming events")
    #expect(empty.emptyView?.description == "Nothing on your calendars for the next 7 days.")
    let emptyEntries = ActionPanelReader.sections(of: empty.emptyView?.actions).flatMap(\.entries)
    let settings = try #require(emptyEntries.first)
    guard case .node(let settingsNode) = settings.target else {
        Issue.record("Open Calendar Settings runs a node")
        return
    }
    #expect(ScheduleList.target(of: settingsNode, in: none, calendar: utc, locale: british) == .openSettings)
}

// MARK: - Reloads and searches (SPEC-110 §3, §4)

/// What My Schedule draws from `source`, read as the app reads it.
private func read(_ source: FixedCalendarSource) -> ScheduleList.Content {
    let window = Schedule.window(now: now, daysAhead: 7, calendar: utc)
    let events = source.events(from: window.start, to: window.end, calendars: Set(calendars.map(\.id)))
    return content(events)
}

private func fixed(_ events: [CalendarEvent]) -> FixedCalendarSource {
    FixedCalendarSource(access: .fullAccess, calendars: calendars, events: events)
}

@Test func aReloadKeepsTheSelectionOnTheSameEvent() throws {
    let standup = event("Standup", "23T10:00", "23T10:30")
    let review = event("Review", "23T11:00", "23T12:00")
    let before = read(fixed([standup, review]))
    // The selection is on Review, the second row; a reload brings an event above it.
    let after = read(fixed([event("Early call", "23T09:00", "23T09:30"), standup, review]))
    let row = try #require(ScheduleList.row(after: before, selected: "event-1", in: after))
    #expect(row == "event-2")
    let list = ListContent(ScheduleList.view(after, now: now, calendar: utc, locale: british), searchText: "")
    #expect(list.items.first { $0.itemId == row }?.title == "Review")

    // An event that's gone gives no row, so the list keeps the same place.
    #expect(ScheduleList.row(after: before, selected: "event-1", in: read(fixed([standup]))) == nil)
    // Nothing selected, a row that isn't there, or no list to read: nothing to follow.
    #expect(ScheduleList.row(after: before, selected: nil, in: after) == nil)
    #expect(ScheduleList.row(after: before, selected: "event-9", in: after) == nil)
    #expect(ScheduleList.row(after: .asking, selected: "event-0", in: after) == nil)

    // An event on several days keeps the selection on the same day's row.
    let trip = event("Trip", "22T18:00", "24T10:00")
    let twoDays = read(fixed([trip]))
    let withLunch = read(fixed([trip, event("Lunch", "23T12:00", "23T13:00")]))
    #expect(ScheduleList.row(after: twoDays, selected: "event-1", in: withLunch) == "event-2", "tomorrow's row")
    #expect(ScheduleList.row(after: twoDays, selected: "event-0", in: withLunch) == "event-0", "today's row")

    // Two events with the same title are told apart by their start.
    let first = event("Sync", "23T10:00", "23T10:30")
    let second = event("Sync", "23T15:00", "23T15:30")
    let syncs = read(fixed([first, second]))
    let moved = read(fixed([event("Early call", "23T09:00", "23T09:30"), first, second]))
    #expect(ScheduleList.row(after: syncs, selected: "event-1", in: moved) == "event-2")
}

@Test func aSearchWithNoMatchSaysSoNotThatThereAreNoEvents() throws {
    let events = content([event("Standup", "23T10:00", "23T10:30")])
    var list = ListContent(ScheduleList.view(events, now: now, calendar: utc, locale: british), searchText: "")
    #expect(list.emptyView == nil)
    list.search("zzyzx")
    #expect(list.items.isEmpty)
    #expect(list.emptyView?.title == "No events match")
    #expect(list.emptyView?.description == "No event in the list matches your search.")
    let matchEntries = ActionPanelReader.sections(of: list.emptyView?.actions).flatMap(\.entries)
    #expect(matchEntries.isEmpty, "nothing to do")

    // With no events, it's still "No upcoming events", searched or not, with Open Calendar Settings.
    var none = ListContent(ScheduleList.view(content([]), now: now, calendar: utc, locale: british), searchText: "")
    #expect(none.emptyView?.title == "No upcoming events")
    none.search("zzyzx")
    #expect(none.emptyView?.title == "No upcoming events")
    let noneEntries = ActionPanelReader.sections(of: none.emptyView?.actions).flatMap(\.entries)
    let settings = try #require(noneEntries.first)
    guard case .node(let settingsNode) = settings.target else {
        Issue.record("Open Calendar Settings runs a node")
        return
    }
    // That node opens nothing while events are listed, since their empty view has no action.
    #expect(ScheduleList.target(of: settingsNode, in: events, calendar: utc, locale: british) == nil)
}

@Test func theCalendarGroupHasMySchedule() {
    let group = BuiltInCommandGroup.calendar
    #expect(group.id == ":calendar" && BuiltInCommandGroup.isValidName(group.id))
    #expect(group.commands.map(\.title) == ["My Schedule"])
    #expect(group.commandID(group.commands[0]) == ":calendar/my-schedule")
    #expect(ExtensionManifest.isValidName(ScheduleList.commandName))
}
