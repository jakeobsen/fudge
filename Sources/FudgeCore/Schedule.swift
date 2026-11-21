import Foundation

/// Whether Fudge may read the Mac's calendars, as EventKit says for events.
public enum CalendarAuthorization: String, Sendable, Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted

    /// Whether events can be read: only with full access.
    public var canRead: Bool { self == .fullAccess }

    /// What the Permissions and Calendar pages say about it.
    public var status: String {
        switch self {
        case .notDetermined: "Not asked yet. My Schedule asks the first time you open it."
        case .fullAccess: "Allowed"
        case .writeOnly, .denied: "Not allowed"
        case .restricted: "Not allowed on this Mac"
        }
    }
}

/// One of the Mac's calendars.
public struct CalendarInfo: Sendable, Equatable, Identifiable {
    /// EventKit's `calendarIdentifier`.
    public var id: String
    public var title: String
    /// Its color, `#RRGGBB`.
    public var color: String

    public init(id: String, title: String, color: String) {
        self.id = id
        self.title = title
        self.color = color
    }
}

/// One event, as My Schedule shows it. Invites are written by other people, so everything here is untrusted text:
/// it's shown as plain text, never logged, and never written anywhere (SPEC-092).
public struct CalendarEvent: Sendable, Equatable {
    /// EventKit's `calendarItemIdentifier`, to open it in Calendar. Never shown, logged or stored, and never a row id.
    public var identifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var location: String?
    public var notes: String?
    public var url: URL?
    /// How many people are invited.
    public var attendees: Int

    public init(
        identifier: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendarID: String,
        location: String? = nil, notes: String? = nil, url: URL? = nil, attendees: Int = 0
    ) {
        self.identifier = identifier
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
    }
}

/// The Mac's calendars. The app's is EventKit; tests and snapshot runs use `FixedCalendarSource`, so nothing reads
/// the real calendar there.
public protocol CalendarSource: Sendable {
    /// Read without asking.
    var authorization: CalendarAuthorization { get }
    /// Asks for full access, showing macOS's prompt if it hasn't been answered; true when granted.
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    /// The events of the calendars `ids` that overlap `from`..<`to`.
    func events(from: Date, to: Date, calendars ids: Set<String>) -> [CalendarEvent]
}

/// A meeting link in an event: where it goes, and which service it is.
public struct MeetingLink: Sendable, Equatable {
    public var url: URL
    /// "Zoom", "Google Meet", …
    public var service: String
}

/// Finds the first video-meeting link in an event (SPEC-092). An invite is written by someone else, so a link counts
/// only when its parsed scheme is `https` and its parsed host is a known meeting host or a subdomain of one, or when
/// its scheme is one of a few meeting apps', and an https link has a path (a meeting's page, not the host's front
/// page). Nothing is matched as a substring: `zoom.us.evil.example` and `evil.example/zoom.us` aren't Zoom, and
/// `file:`, `javascript:` or any other scheme never counts.
public enum MeetingLinks {
    /// Known hosts, by the service they belong to. A link's host must be one of these, or end in `.` and one.
    public static let hosts: [(host: String, service: String)] = [
        ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"), ("meet.google.com", "Google Meet"),
        ("teams.microsoft.com", "Microsoft Teams"), ("teams.live.com", "Microsoft Teams"), ("webex.com", "Webex"),
        ("facetime.apple.com", "FaceTime"), ("whereby.com", "Whereby"), ("around.co", "Around"),
        ("meet.jit.si", "Jitsi"),
    ]

    /// The meeting apps' own schemes, which open the app straight away.
    public static let appSchemes: [String: String] = [
        "zoommtg": "Zoom", "msteams": "Microsoft Teams", "facetime": "FaceTime",
    ]

    /// The first meeting link in the event's URL, then its location, then its notes.
    public static func find(in event: CalendarEvent) -> MeetingLink? {
        if let url = event.url, let link = link(url.absoluteString) { return link }
        for text in [event.location, event.notes].compactMap(\.self) {
            if let link = first(in: text) { return link }
        }
        return nil
    }

    /// The first meeting link in `text`.
    public static func first(in text: String) -> MeetingLink? {
        for candidate in candidates(in: text) {
            if let link = link(candidate) { return link }
        }
        return nil
    }

    /// What `text` holds that might be a link: its runs between spaces and the characters that end a link in text,
    /// HTML (an `href="…"`) or markdown, without the punctuation a sentence puts after one.
    static func candidates(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'()[]{}|\\^`"))
        return text.components(separatedBy: separators).compactMap { piece in
            var candidate = Substring(piece)
            while let last = candidate.last, ".,;:!?".contains(last) { candidate = candidate.dropLast() }
            return candidate.isEmpty ? nil : String(candidate)
        }
    }

    /// `candidate` as a meeting link, or nil. One with no scheme (`meet.google.com/abc-defg-hij`) is read as https.
    static func link(_ candidate: String) -> MeetingLink? {
        guard var components = URLComponents(string: candidate) else { return nil }
        if components.scheme == nil {
            guard let https = URLComponents(string: "https://" + candidate), https.host != nil else { return nil }
            components = https
        }
        guard let scheme = components.scheme?.lowercased() else { return nil }
        if let service = appSchemes[scheme] {
            return components.url.map { MeetingLink(url: $0, service: service) }
        }
        // A meeting is a page on the host, never the host's front page (`zoom.us` alone in a sentence).
        guard scheme == "https", components.user == nil, components.password == nil,
            var host = components.host?.lowercased(), !host.isEmpty, components.path.count > 1
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard let known = hosts.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }),
            let url = components.url
        else { return nil }
        return MeetingLink(url: url, service: known.service)
    }
}

/// One day of My Schedule: its title and its events, in the order shown.
public struct ScheduleDay: Sendable, Equatable {
    public var title: String
    public var interval: DateInterval
    public var events: [CalendarEvent]
}

/// My Schedule's logic (SPEC-092): which days, which events on each, and how each one's time reads.
public enum Schedule {
    /// Days Ahead's choices (`calendarDaysAhead`), and the default.
    public static let daysAheadChoices = [1, 3, 7, 14]
    public static let defaultDaysAhead = 7

    /// How far an event's start counts as soon: "in 12 min" up to an hour ahead.
    static let soon: TimeInterval = 3600

    /// From the start of today to the end of the day `daysAhead` days on.
    public static func window(now: Date, daysAhead: Int, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: max(0, daysAhead) + 1, to: today) ?? today
        return DateInterval(start: today, end: end)
    }

    /// The calendars to read: every calendar but the ones the user unticked (`calendarHidden`), so a new calendar
    /// shows.
    public static func shownCalendars(_ calendars: [CalendarInfo], hidden: [String]) -> Set<String> {
        Set(calendars.map(\.id)).subtracting(hidden)
    }

    /// The days from today to `daysAhead` days on that have an event not over yet, each with the events overlapping
    /// it (an event spanning days is on each), all-day ones first, then by start, then by title.
    public static func days(
        _ events: [CalendarEvent], now: Date, daysAhead: Int, calendar: Calendar, locale: Locale
    ) -> [ScheduleDay] {
        let window = window(now: now, daysAhead: daysAhead, calendar: calendar)
        // An event with no length (or an end before its start) counts as one moment, at its start.
        func ends(_ event: CalendarEvent) -> Date { max(event.start, event.end) }
        let upcoming = events.filter { ends($0) > now || ($0.start >= now) }
        var days: [ScheduleDay] = []
        var start = window.start
        while start < window.end {
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { break }
            let day = DateInterval(start: start, end: end)
            let onDay = upcoming.filter { $0.start < day.end && (ends($0) > day.start || $0.start >= day.start) }
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay }
                    if a.start != b.start { return a.start < b.start }
                    return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            if !onDay.isEmpty {
                days.append(
                    ScheduleDay(
                        title: title(of: start, now: now, calendar: calendar, locale: locale), interval: day,
                        events: onDay))
            }
            start = end
        }
        return days
    }

    /// "Today", "Tomorrow", else the weekday and date in the Mac's format ("Monday, 24 November").
    public static func title(of day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
            calendar.isDate(day, inSameDayAs: tomorrow)
        {
            return "Tomorrow"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: day)
    }

    /// The event's time on `day`: "All day", "09:00 – 09:30", or, for one that began before the day or ends after
    /// it, "Until 11:00" or "From 22:00" (all day when it does both).
    public static func time(of event: CalendarEvent, on day: DateInterval, calendar: Calendar, locale: Locale)
        -> String
    {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let before = event.start < day.start
        let after = event.end > day.end
        switch (before, after) {
        case (true, true): return "All day"
        case (true, false): return "Until \(formatter.string(from: event.end))"
        case (false, true): return "From \(formatter.string(from: event.start))"
        case (false, false):
            if event.end <= event.start { return formatter.string(from: event.start) }
            return "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
        }
    }

    /// "Now" for an event in progress, "in 12 min" for one that starts within the hour, else nil. All-day events
    /// get neither.
    public static func accessory(of event: CalendarEvent, now: Date) -> String? {
        guard !event.isAllDay else { return nil }
        if event.start <= now, now < event.end { return "Now" }
        let wait = event.start.timeIntervalSince(now)
        guard wait > 0, wait <= soon else { return nil }
        return "in \(Int((wait / 60).rounded(.up))) min"
    }

    /// Copy Details: the title, the day and time, the location and the meeting link, one per line.
    public static func details(
        of event: CalendarEvent, on day: ScheduleDay, calendar: Calendar, locale: Locale
    ) -> String {
        var lines = [
            event.title, "\(day.title), \(time(of: event, on: day.interval, calendar: calendar, locale: locale))",
        ]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            lines.append(location)
        }
        if let link = MeetingLinks.find(in: event) { lines.append(link.url.absoluteString) }
        return lines.joined(separator: "\n")
    }

    /// The `ical:` URL that shows the event in Calendar, by its identifier, percent-encoded.
    public static func calendarURL(of event: CalendarEvent) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let id = event.identifier.addingPercentEncoding(withAllowedCharacters: allowed), !id.isEmpty else {
            return nil
        }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
    }
}

extension BuiltInCommandGroup {
    /// The Calendar group (SPEC-092): My Schedule.
    public static let calendar = BuiltInCommandGroup(
        name: ":calendar", title: "Calendar",
        commands: [
            BuiltInCommand(
                name: ScheduleList.commandName, title: ScheduleList.title,
                keywords: ["calendar", "schedule", "events", "meetings", "agenda", "today"], symbol: "calendar")
        ])
}
