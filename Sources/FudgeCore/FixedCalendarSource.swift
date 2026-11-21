import Foundation

/// A `CalendarSource` with fixed calendars and events, for tests and snapshot runs, so neither reads the Mac's
/// calendars or asks for access. `requestAccess` never shows anything: it answers with what `access` says.
public final class FixedCalendarSource: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var access: CalendarAuthorization
    private let fixedCalendars: [CalendarInfo]
    private let fixedEvents: [CalendarEvent]
    /// How many times `requestAccess` was called, for tests.
    public var requests: Int { lock.withLock { requestCount } }
    private var requestCount = 0
    /// What `requestAccess` turns `access` into.
    private let answer: CalendarAuthorization

    public init(
        access: CalendarAuthorization, calendars: [CalendarInfo] = [], events: [CalendarEvent] = [],
        answer: CalendarAuthorization? = nil
    ) {
        self.access = access
        fixedCalendars = calendars
        fixedEvents = events
        self.answer = answer ?? access
    }

    public var authorization: CalendarAuthorization { lock.withLock { access } }

    public func requestAccess() async -> Bool {
        lock.withLock {
            requestCount += 1
            if access == .notDetermined { access = answer }
            return access.canRead
        }
    }

    public func calendars() -> [CalendarInfo] {
        authorization.canRead ? fixedCalendars : []
    }

    public func events(from: Date, to: Date, calendars ids: Set<String>) -> [CalendarEvent] {
        guard authorization.canRead else { return [] }
        return fixedEvents.filter { ids.contains($0.calendarID) && $0.start < to && max($0.start, $0.end) > from }
    }

    /// A snapshot run's `--calendar-events <file>`: made-up calendars and events, with times relative to `now`.
    ///
    ///     { "access": "fullAccess",
    ///       "calendars": [ { "id": "work", "title": "Work", "color": "#0A84FF" } ],
    ///       "events": [ { "title": "Standup", "calendar": "work", "startsIn": 10, "minutes": 15,
    ///                     "location": "…", "notes": "…", "url": "https://…", "attendees": 4 },
    ///                   { "title": "Offsite", "calendar": "work", "allDay": true, "day": 1 } ] }
    ///
    /// `startsIn` is minutes from now; an all-day event is on `day`, days from today. A file that can't be read gives
    /// no access.
    public static func load(_ file: URL, now: Date, calendar: Calendar = .current) -> FixedCalendarSource {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return FixedCalendarSource(access: .denied) }
        let access = (object["access"] as? String).flatMap(CalendarAuthorization.init(rawValue:)) ?? .fullAccess
        let calendars = (object["calendars"] as? [[String: Any]] ?? []).compactMap { entry -> CalendarInfo? in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            return CalendarInfo(id: id, title: title, color: entry["color"] as? String ?? "#8E8E93")
        }
        let today = calendar.startOfDay(for: now)
        let events = (object["events"] as? [[String: Any]] ?? []).enumerated().compactMap {
            index, entry -> CalendarEvent? in
            guard let title = entry["title"] as? String, let calendarID = entry["calendar"] as? String else {
                return nil
            }
            let allDay = entry["allDay"] as? Bool ?? false
            let start: Date
            let end: Date
            if allDay {
                let days = entry["day"] as? Int ?? 0
                start = calendar.date(byAdding: .day, value: days, to: today) ?? today
                end = calendar.date(byAdding: .day, value: entry["days"] as? Int ?? 1, to: start) ?? start
            } else {
                start = now.addingTimeInterval(Double(entry["startsIn"] as? Int ?? 0) * 60)
                end = start.addingTimeInterval(Double(entry["minutes"] as? Int ?? 30) * 60)
            }
            return CalendarEvent(
                identifier: "snapshot-\(index)", title: title, start: start, end: end, isAllDay: allDay,
                calendarID: calendarID, location: entry["location"] as? String, notes: entry["notes"] as? String,
                url: (entry["url"] as? String).flatMap(URL.init(string:)), attendees: entry["attendees"] as? Int ?? 0)
        }
        return FixedCalendarSource(access: access, calendars: calendars, events: events)
    }
}
