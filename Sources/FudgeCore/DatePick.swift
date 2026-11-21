import Foundation

/// An `Action.PickDate`'s picker, shown in the action panel overlay in place of the action list: Form.DatePicker's
/// calendar (`DateCalendar`), and for `DateTime` the time beside it. Nothing is picked until ↵, Space or a click on
/// a day picks one; ⌫ clears; Esc goes back without calling anything.
public struct DatePick: Sendable, Equatable {
    /// Which part has the keyboard. Only a `DateTime` picker has a time, and Tab moves between the two.
    public enum Focus: Sendable, Equatable {
        case calendar, time
    }

    /// What a key or a click asks for.
    public enum Outcome: Sendable, Equatable {
        /// Taken by the picker: a move, Tab, or typing, which filters nothing.
        case handled
        /// Not the picker's: the time field, which has the keyboard, takes it.
        case ignored
        /// Call `onChange(date)` once, then close the overlay.
        case pick(Date)
        /// Call `onChange(null)`, then close the overlay.
        case clear
        /// Esc: back to the action list the picker was opened from, calling nothing.
        case backToList
        /// Esc: close the overlay, which opened straight to the picker, calling nothing.
        case close
    }

    /// The action's node: `onChange` goes there.
    public let node: Int
    /// The picker's heading: the action's title, which a render may change (`following`).
    public private(set) var title: String
    /// Opened from the action list, where Esc goes back to; or straight from ↵, ⌘↵ or a shortcut, when Esc closes
    /// the overlay.
    public let openedFromList: Bool
    /// The month on show and its highlighted day, which starts on today, within `min` and `max`.
    public private(set) var month: DateCalendar
    /// A `DateTime`'s time, in whole minutes: the current time when the picker opens.
    public private(set) var time: Date
    public private(set) var focus: Focus = .calendar

    public var options: DatePickerOptions { month.options }

    public init(
        node: Int, title: String, options: DatePickerOptions, openedFromList: Bool, now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.node = node
        self.title = title
        self.openedFromList = openedFromList
        month = DateCalendar(value: nil, options: options, now: now, calendar: calendar)
        time = calendar.dateInterval(of: .minute, for: now)?.start ?? now
    }

    /// What a pick gives now, as `FormDates` makes a DatePicker's value: with `Date`, the highlighted day's local
    /// midnight; with `DateTime`, that day at `time`, in whole minutes. Within `min` and `max` either way.
    public func value(calendar: Calendar = .current) -> Date {
        month.value(current: time, now: time, calendar: calendar)
    }

    /// The time field's edit: its hour and minute become the time; the day stays the calendar's.
    public mutating func setTime(_ date: Date, calendar: Calendar = .current) {
        time = calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    /// Gives the keyboard to the calendar or, for `DateTime`, the time.
    public mutating func focus(_ part: Focus) {
        focus = options.type == .dateTime ? part : .calendar
    }

    /// A render changed the action's `type`, `min` or `max`: the highlighted day stays, kept within the new limits,
    /// and so does the time.
    public mutating func update(options: DatePickerOptions, calendar: Calendar = .current) {
        guard options != self.options else { return }
        month = DateCalendar(value: month.day, options: options, now: month.day, calendar: calendar)
        if options.type == .date { focus = .calendar }
    }

    /// After a render, with `entry` the action now at the picker's node (`ActionPanelReader.entry(id:in:)`): the
    /// picker it becomes, with the action's title as its heading and its new limits (`update(options:)`). Nil when
    /// the action is gone or is no longer an `Action.PickDate`: the picker closes without calling anything.
    public func following(_ entry: ActionEntry?, calendar: Calendar = .current) -> DatePick? {
        guard let entry, let options = entry.pickDate else { return nil }
        var next = self
        next.title = entry.title
        next.update(options: options, calendar: calendar)
        return next
    }

    /// The month arrows and ⇞⇟.
    public mutating func move(months: Int, calendar: Calendar = .current) {
        month.move(months: months, calendar: calendar)
    }

    /// A click on a day picks it. A day outside `min` and `max` does nothing.
    public mutating func click(_ day: Date, calendar: Calendar = .current) -> Outcome {
        guard month.highlight(day, calendar: calendar) else { return .handled }
        return .pick(value(calendar: calendar))
    }

    /// The picker's keys. With the calendar: ←→ a day, ↑↓ a week, ⇞⇟ a month, ↵ or Space picks, ⌫ clears, Esc goes
    /// back, and other typing does nothing. With the time: ↵ picks and Esc goes back; the time field takes the rest.
    /// Tab and ⇧Tab move between the two. Keys with ⌘, ⌥ or ⌃ aren't the picker's.
    public mutating func handle(_ pressed: KeyShortcut, calendar: Calendar = .current) -> Outcome {
        guard pressed.modifiers.isSubset(of: ["shift"]) else { return .ignored }
        switch pressed.key {
        case "tab":
            focus(focus == .calendar ? .time : .calendar)
            return .handled
        case "escape":
            return openedFromList ? .backToList : .close
        case "return", "enter":
            return .pick(value(calendar: calendar))
        default:
            break
        }
        guard focus == .calendar else { return .ignored }
        let plain = pressed.modifiers.isEmpty
        switch pressed.key {
        case "arrowLeft" where plain: month.move(days: -1, calendar: calendar)
        case "arrowRight" where plain: month.move(days: 1, calendar: calendar)
        case "arrowUp" where plain: month.move(days: -7, calendar: calendar)
        case "arrowDown" where plain: month.move(days: 7, calendar: calendar)
        case "pageUp" where plain: month.move(months: -1, calendar: calendar)
        case "pageDown" where plain: month.move(months: 1, calendar: calendar)
        case "space" where plain: return .pick(value(calendar: calendar))
        case "delete" where plain, "deleteForward" where plain: return .clear
        default: break
        }
        return .handled
    }
}
