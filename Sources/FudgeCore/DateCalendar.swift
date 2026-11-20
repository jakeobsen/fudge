import Foundation

/// A Form.DatePicker's open calendar: the highlighted day, which the arrow keys move, and the month around it.
/// Opening it picks nothing; the field's value changes only when a day is picked (`value(current:now:)`).
public struct DateCalendar: Sendable, Equatable {
    public let options: DatePickerOptions
    /// The highlighted day, at local midnight, always one that can be picked.
    public private(set) var day: Date

    /// Highlights the field's day, or today when it has none, kept within `min` and `max`.
    public init(value: Date?, options: DatePickerOptions, now: Date = Date(), calendar: Calendar = .current) {
        self.options = options
        day = calendar.startOfDay(for: value ?? now)
        day = clamped(day, calendar: calendar)
    }

    /// A day in the month grid.
    public struct Day: Sendable, Equatable, Identifiable {
        public let date: Date
        /// The day of the month.
        public let number: Int
        /// Whether it's in the highlighted day's month, rather than filling the first or last week.
        public let inMonth: Bool
        /// Whether it's within `min` and `max`, which count by the day.
        public let isPickable: Bool

        public var id: Date { date }
    }

    /// The highlighted day's month as six weeks of seven days, starting on the calendar's first weekday.
    public func weeks(calendar: Calendar = .current) -> [[Day]] {
        guard let month = calendar.dateInterval(of: .month, for: day) else { return [] }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -leading, to: month.start) else { return [] }
        let monthNumber = calendar.component(.month, from: day)
        return (0..<6).map { week in
            (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: first) else { return nil }
                return Day(
                    date: date, number: calendar.component(.day, from: date),
                    inMonth: calendar.component(.month, from: date) == monthNumber,
                    isPickable: isPickable(date, calendar: calendar))
            }
        }
    }

    /// The weekdays' one-letter names, in the order `weeks` lays them out.
    public static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whether `date`'s day is within `min` and `max`, by the day.
    public func isPickable(_ date: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: date)
        if let min = options.min, start < calendar.startOfDay(for: min) { return false }
        if let max = options.max, start > calendar.startOfDay(for: max) { return false }
        return true
    }

    /// ←→ move by a day, ↑↓ by a week; a move past `min` or `max` stops there.
    public mutating func move(days: Int, calendar: Calendar = .current) {
        guard let moved = calendar.date(byAdding: .day, value: days, to: day) else { return }
        day = clamped(calendar.startOfDay(for: moved), calendar: calendar)
    }

    /// The month arrows and ⇞⇟: the same day of the next or previous month (or its last day), within the limits.
    public mutating func move(months: Int, calendar: Calendar = .current) {
        guard let moved = calendar.date(byAdding: .month, value: months, to: day) else { return }
        day = clamped(calendar.startOfDay(for: moved), calendar: calendar)
    }

    /// Highlights a clicked day. False, changing nothing, when it can't be picked.
    public mutating func highlight(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isPickable(date, calendar: calendar) else { return false }
        day = calendar.startOfDay(for: date)
        return true
    }

    /// The field's value when the highlighted day is picked: with `Date`, that day; with `DateTime`, that day at the
    /// field's time, or the current time when it has none. In whole minutes, within `min` and `max`.
    public func value(current: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: current ?? now)
        let picked = calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day)
        return FormDates.value(for: picked ?? day, options: options, calendar: calendar)
    }

    private func clamped(_ start: Date, calendar: Calendar) -> Date {
        if let min = options.min.map(calendar.startOfDay(for:)), start < min { return min }
        if let max = options.max.map(calendar.startOfDay(for:)), start > max { return max }
        return start
    }
}
