import Foundation

/// My Schedule's view (SPEC-092): a List built here, as `SnippetList` is, under a session of Fudge's own, so it never
/// reaches the extension host and the launcher answers its actions itself.
///
/// Events come from other people's invites, so the view keeps them inert: titles, times, locations and attendees go
/// into plain-text fields, the notes into a code block (nothing in them is read as markdown, so no image loads), and
/// row ids are positions (`event-<n>`), never anything from the event.
public enum ScheduleList {
    public static let session = "fudge:schedule"
    public static let title = "My Schedule"
    /// The command's name in `BuiltInCommandGroup.calendar`.
    public static let commandName = "my-schedule"

    /// What the view shows.
    public enum Content: Sendable, Equatable {
        /// Calendar access is being asked for.
        case asking
        /// Fudge may not read the calendars.
        case refused
        /// The days with events, and the calendars they're from.
        case days([ScheduleDay], calendars: [CalendarInfo], daysAhead: Int)
    }

    /// What one of its actions does.
    public enum Target: Sendable, Equatable {
        /// Join Meeting: opens the meeting link.
        case join(URL)
        /// Open in Calendar: shows the event in Calendar.
        case openInCalendar(URL)
        /// Copy Meeting Link.
        case copyLink(URL)
        /// Copy Details: the text to copy.
        case copyDetails(String)
        /// The refused view's Open Privacy Settings.
        case openPrivacySettings
        /// The empty view's Open Calendar Settings.
        case openSettings
        /// Show Details or Hide Details: the detail pane, which hides the rows' times when it's showing.
        case toggleDetail
    }

    /// System Settings' Calendars list, under Privacy & Security.
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    public static let openShortcut = KeyShortcut(key: "o", modifiers: ["cmd"])
    public static let copyLinkShortcut = KeyShortcut(key: "c", modifiers: ["cmd", "shift"])
    public static let detailShortcut = KeyShortcut(key: "d", modifiers: ["cmd"])

    /// The longest notes the detail shows; the rest is cut.
    static let notesLimit = 5_000

    /// Its nodes' ids. Each row's nodes are a block of `stride` from `firstItem`, in the order shown.
    enum Node {
        static let list = 1
        static let empty = 2
        static let emptyActions = 3
        static let emptyAction = 4
        static let firstSection = 10
        static let firstItem = 100
        static let stride = 20
        // Offsets inside a row's block.
        static let item = 0
        static let detail = 1
        static let metadata = 2
        static let time = 3
        static let location = 4
        static let calendar = 5
        static let attendees = 6
        static let meeting = 7
        static let actions = 8
        static let join = 9
        static let open = 10
        static let copyLink = 11
        static let copyDetails = 12
        static let toggleDetail = 13
    }

    /// Every row, as the view lists them: each day's events in order, an event spanning days once per day.
    static func rows(_ days: [ScheduleDay]) -> [(day: ScheduleDay, event: CalendarEvent)] {
        days.flatMap { day in day.events.map { (day, $0) } }
    }

    /// The List: a section per day, a row per event with its detail, or the view for asking, refused, or no events.
    /// The rows show each event's time and whether it's on now; the detail pane, which hides those as every List's
    /// does, shows with `showingDetail` (Show Details, ⌘D).
    public static func view(
        _ content: Content, showingDetail: Bool = false, now: Date, calendar: Calendar, locale: Locale
    ) -> UINode {
        var props: [String: JSONValue] = [
            "navigationTitle": .string(title), "searchBarPlaceholder": .string("Search events"),
        ]
        switch content {
        case .asking:
            props["isLoading"] = .bool(true)
            return UINode(id: Node.list, type: "List", props: props)
        case .refused:
            props["isShowingDetail"] = .bool(false)
            let empty = emptyView(
                title: "Calendar access is off",
                description: "Allow Fudge under Calendars in System Settings, Privacy & Security.",
                action: "Open Privacy Settings", icon: "lock-16")
            return UINode(id: Node.list, type: "List", props: props, children: [empty])
        case .days(let days, let calendars, let daysAhead):
            props["isShowingDetail"] = .bool(showingDetail && !days.isEmpty)
            let titles = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var index = 0
            var sections: [UINode] = []
            for (number, day) in days.enumerated() {
                var items: [UINode] = []
                for event in day.events {
                    items.append(
                        item(
                            event, on: day, base: Node.firstItem + index * Node.stride, index: index,
                            calendar: titles[event.calendarID], showingDetail: showingDetail, now: now,
                            calendars: calendar, locale: locale))
                    index += 1
                }
                sections.append(
                    UINode(
                        id: Node.firstSection + number, type: "List.Section", props: ["title": .string(day.title)],
                        children: items))
            }
            let days = daysAhead == 1 ? "today and tomorrow" : "the next \(daysAhead) days"
            sections.append(
                emptyView(
                    title: "No upcoming events", description: "Nothing on your calendars for \(days).",
                    action: "Open Calendar Settings", icon: "calendar-16"))
            return UINode(id: Node.list, type: "List", props: props, children: sections)
        }
    }

    /// What the action `node` does in the view built from `content`; nil for any other node.
    public static func target(of node: Int, in content: Content, calendar: Calendar, locale: Locale) -> Target? {
        switch content {
        case .asking:
            return nil
        case .refused:
            return node == Node.emptyAction ? .openPrivacySettings : nil
        case .days(let days, _, _):
            if node == Node.emptyAction { return .openSettings }
            guard node >= Node.firstItem else { return nil }
            let all = rows(days)
            let index = (node - Node.firstItem) / Node.stride
            guard index < all.count else { return nil }
            let (day, event) = all[index]
            let link = MeetingLinks.find(in: event)
            switch (node - Node.firstItem) % Node.stride {
            case Node.join: return link.map { .join($0.url) }
            case Node.open: return Schedule.calendarURL(of: event).map(Target.openInCalendar)
            case Node.copyLink: return link.map { .copyLink($0.url) }
            case Node.copyDetails:
                return .copyDetails(Schedule.details(of: event, on: day, calendar: calendar, locale: locale))
            case Node.toggleDetail: return .toggleDetail
            default: return nil
            }
        }
    }

    private static func item(
        _ event: CalendarEvent, on day: ScheduleDay, base: Int, index: Int, calendar info: CalendarInfo?,
        showingDetail: Bool, now: Date, calendars calendar: Calendar, locale: Locale
    ) -> UINode {
        let time = Schedule.time(of: event, on: day.interval, calendar: calendar, locale: locale)
        let link = MeetingLinks.find(in: event)
        let color = info?.color ?? "#8E8E93"
        let dot: JSONValue = .object(["source": .string("circle-filled-16"), "tintColor": .string(color)])

        var labels = [label(base + Node.time, "Time", "\(day.title), \(time)")]
        if let location = trimmed(event.location) { labels.append(label(base + Node.location, "Location", location)) }
        if let info {
            var calendarLabel = label(base + Node.calendar, "Calendar", info.title)
            calendarLabel.props["icon"] = dot
            labels.append(calendarLabel)
        }
        if event.attendees > 0 { labels.append(label(base + Node.attendees, "Invited", "\(event.attendees)")) }
        if let link { labels.append(label(base + Node.meeting, "Meeting", link.service)) }
        let detail = UINode(
            id: base + Node.detail, type: "List.Item.Detail",
            props: [
                "markdown": .string(notesMarkdown(event.notes)),
                "metadata": UINode(id: base + Node.metadata, type: "Metadata", children: labels).json,
            ])

        var actions: [UINode] = []
        if link != nil { actions.append(action(base + Node.join, "Join Meeting", icon: "video-16", shortcut: nil)) }
        if Schedule.calendarURL(of: event) != nil {
            actions.append(action(base + Node.open, "Open in Calendar", icon: "calendar-16", shortcut: openShortcut))
        }
        if link != nil {
            actions.append(
                action(base + Node.copyLink, "Copy Meeting Link", icon: "link-16", shortcut: copyLinkShortcut))
        }
        actions.append(action(base + Node.copyDetails, "Copy Details", icon: "copy-clipboard-16", shortcut: nil))
        actions.append(
            action(
                base + Node.toggleDetail, showingDetail ? "Hide Details" : "Show Details",
                icon: "app-window-sidebar-right-16",
                shortcut: detailShortcut))

        var props: [String: JSONValue] = [
            "id": .string("event-\(index)"),
            "title": .string(trimmed(event.title) ?? "No Title"),
            "subtitle": .string(time),
            "icon": dot,
            "keywords": .array([info?.title, trimmed(event.location)].compactMap(\.self).map(JSONValue.string)),
            "actions": UINode(id: base + Node.actions, type: "ActionPanel", children: actions).json,
            "detail": detail.json,
        ]
        if let accessory = Schedule.accessory(of: event, now: now) {
            props["accessories"] = .array([.object(["text": .string(accessory)])])
        }
        return UINode(id: base + Node.item, type: "List.Item", props: props)
    }

    /// The notes as the detail shows them: trimmed, cut at `notesLimit`, in a code block, so they're literal text.
    static func notesMarkdown(_ notes: String?) -> String {
        guard var text = trimmed(notes) else { return "" }
        if text.count > notesLimit { text = String(text.prefix(notesLimit)) + "…" }
        return SnippetList.codeBlock(text)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func label(_ id: Int, _ title: String, _ text: String) -> UINode {
        UINode(id: id, type: "Metadata.Label", props: ["title": .string(title), "text": .string(text)])
    }

    private static func emptyView(title: String, description: String, action: String, icon: String) -> UINode {
        let button = Self.action(Node.emptyAction, action, icon: "cog-16", shortcut: nil)
        return UINode(
            id: Node.empty, type: "List.EmptyView",
            props: [
                "title": .string(title), "description": .string(description), "icon": .string(icon),
                "actions": UINode(id: Node.emptyActions, type: "ActionPanel", children: [button]).json,
            ])
    }

    private static func action(_ id: Int, _ title: String, icon: String, shortcut: KeyShortcut?) -> UINode {
        var props: [String: JSONValue] = ["title": .string(title), "icon": .string(icon)]
        if let shortcut {
            props["shortcut"] = .object([
                "key": .string(shortcut.key), "modifiers": .array(shortcut.modifiers.sorted().map(JSONValue.string)),
            ])
        }
        return UINode(id: id, type: "Action", props: props)
    }
}
