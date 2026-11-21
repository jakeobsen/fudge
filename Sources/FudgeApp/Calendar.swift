import AppKit
import EventKit
import FudgeCore

/// The Mac's calendars through EventKit, for My Schedule (SPEC-092). It only reads: nothing is created, changed or
/// kept, and nothing an event holds is logged.
final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()

    var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        default: .denied
        }
    }

    /// macOS's prompt, the first time; afterwards it answers at once. Only My Schedule's own run calls it.
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        // A store made before the grant can hold an empty list of calendars.
        if granted { store.reset() }
        return granted
    }

    func calendars() -> [CalendarInfo] {
        guard authorization.canRead else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Self.hex($0.cgColor))
        }
    }

    func events(from: Date, to: Date, calendars ids: Set<String>) -> [CalendarEvent] {
        guard authorization.canRead else { return [] }
        let chosen = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: chosen)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                identifier: event.calendarItemIdentifier, title: event.title ?? "", start: event.startDate,
                end: event.endDate, isAllDay: event.isAllDay, calendarID: event.calendar.calendarIdentifier,
                location: event.location, notes: event.notes, url: event.url, attendees: event.attendees?.count ?? 0)
        }
    }

    /// A calendar's color as `#RRGGBB`, in sRGB; gray when it has none.
    static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#8E8E93" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
