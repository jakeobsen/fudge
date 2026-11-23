import Foundation

/// A Form view as fudge draws it: its fields in order.
public struct FormContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case textField, passwordField, textArea, checkbox, dropdown, tagPicker, datePicker, filePicker, description
        case separator
        /// A field fudge can't draw yet, by its type ("Form.DatePicker", …).
        case unsupported(String)
    }

    public struct Field: Sendable, Equatable, Identifiable {
        /// The node id, which `onChange` events go to.
        public var id: Int
        /// The field's own `id` prop, which names its value when the form is submitted.
        public var fieldId: String?
        public var kind: Kind
        public var title: String?
        public var placeholder: String?
        public var info: String?
        public var error: String?
        /// Set when the extension controls the value. A DatePicker's can be `.null`, which shows no date
        /// (`FormContent.controlledValue`).
        public var value: JSONValue?
        public var defaultValue: JSONValue?
        /// A checkbox's label, or a description's text.
        public var text: String?
        public var autoFocus: Bool
        /// `storeValue`: the value is saved when the form is submitted and starts the field next time.
        public var storesValue: Bool = false
        public var hasOnFocus: Bool = false
        public var hasOnBlur: Bool = false
        /// A Dropdown's items, sections and search settings (`Form.Dropdown` reads like a search bar dropdown).
        public var options: SearchBarDropdown?
        /// A TagPicker's items, in order.
        public var tags: [SearchBarDropdown.Item] = []
        /// A DatePicker's type and limits.
        public var dates: DatePickerOptions?
        /// What a FilePicker lets the user choose.
        public var files: FilePickerOptions?

        /// Whether the user can change it.
        public var isEditable: Bool {
            switch kind {
            case .textField, .passwordField, .textArea, .checkbox, .dropdown, .tagPicker, .datePicker, .filePicker: true
            default: false
            }
        }

        /// What it holds before anything is typed or set: the controlled value, else a stored one that fits (see
        /// `accepts`), else `defaultValue`, else the field's empty value; a dropdown's is its first item.
        public func initialValue(stored: JSONValue? = nil) -> JSONValue {
            if let value { return value }
            if let stored, accepts(stored) { return stored }
            if let defaultValue { return defaultValue }
            if kind == .dropdown, let first = options?.items.first { return .string(first.value) }
            return emptyValue
        }

        /// What the extension's Form registered for the field (`form-state.ts`): `value`, else `defaultValue`, else
        /// the runtime's empty value. When the app starts the field on something else (a stored value, a
        /// dropdown's first item), it reports that with `onChange`.
        public var registeredValue: JSONValue {
            value ?? defaultValue ?? emptyValue
        }

        /// The value of a field nothing has been put in. A dropdown has none until it has items.
        public var emptyValue: JSONValue {
            switch kind {
            case .checkbox: .bool(false)
            case .tagPicker, .filePicker: .array([])
            case .dropdown, .datePicker: .null
            default: .string("")
            }
        }

        /// Whether `stored` can start this field: only with `storeValue`, never for a PasswordField, and only a
        /// value of the field's type (a dropdown's must still be one of its items, a TagPicker's all of its).
        public func accepts(_ stored: JSONValue) -> Bool {
            guard storesValue else { return false }
            switch (kind, stored) {
            case (.textField, .string), (.textArea, .string), (.checkbox, .bool): return true
            case (.dropdown, .string(let value)):
                return options?.items.contains { $0.value == value } == true
            case (.tagPicker, .array(let values)):
                let known = Set(tags.map(\.value))
                return values.allSatisfy { if case .string(let value) = $0 { known.contains(value) } else { false } }
            case (.datePicker, .null): return true
            case (.datePicker, let value): return FormDates.date(value) != nil
            case (.filePicker, .array(let values)):
                return values.allSatisfy { if case .string = $0 { true } else { false } }
            default:
                return false
            }
        }

        /// The value a dropdown takes once its items arrive, when it had none and the extension doesn't control it:
        /// the first item, as in Raycast.
        public func firstItemValue(replacing current: JSONValue) -> JSONValue? {
            guard kind == .dropdown, value == nil, current == .null, let first = options?.items.first else {
                return nil
            }
            return .string(first.value)
        }

        /// Whether a stored value that doesn't fit yet could fit once more items arrive: a Dropdown's or TagPicker's
        /// value of the right type whose items aren't (all) there. Extensions often load their items after the
        /// first render (`useFetch`, `useCachedPromise`).
        public func mayAcceptLater(_ stored: JSONValue) -> Bool {
            guard storesValue, value == nil else { return false }
            switch (kind, stored) {
            case (.dropdown, .string): return true
            case (.tagPicker, .array(let values)):
                return values.allSatisfy { if case .string = $0 { true } else { false } }
            default: return false
            }
        }

        /// What the field shows after a render. `current` is what it showed before (nil the first time), and
        /// `stored` the value stored for it (the first time) or one still waiting for its items (after that). A
        /// stored value that fits starts the field, ahead of `defaultValue` and a dropdown's first item; one that
        /// may fit once the items arrive stays pending, and is taken as soon as they include it, unless the field
        /// has been changed meanwhile (the app drops the pending value then). `reports` says the extension should
        /// hear the value (`onChange`), because it isn't what the extension's Form holds.
        public func start(current: JSONValue?, stored: JSONValue?) -> FieldStart {
            guard let current else {
                if let stored, accepts(stored) {
                    return FieldStart(value: stored, reports: stored != registeredValue, pending: nil)
                }
                let initial = initialValue()
                let pending = stored.flatMap { mayAcceptLater($0) ? $0 : nil }
                return FieldStart(value: initial, reports: initial != registeredValue, pending: pending)
            }
            if let stored, value == nil {
                if accepts(stored) { return FieldStart(value: stored, reports: stored != current, pending: nil) }
                if mayAcceptLater(stored) {
                    let first = firstItemValue(replacing: current)
                    return FieldStart(value: first ?? current, reports: first != nil, pending: stored)
                }
            }
            if let first = firstItemValue(replacing: current) {
                return FieldStart(value: first, reports: true, pending: nil)
            }
            return FieldStart(value: current, reports: false, pending: nil)
        }

        /// The argument of `onFocus` and `onBlur`: Raycast's `FormEvent`.
        public func focusEvent(_ type: String, value: JSONValue) -> JSONValue {
            .object([
                "target": .object(["id": fieldId.map(JSONValue.string) ?? .null, "value": value]),
                "type": .string(type),
            ])
        }
    }

    public var fields: [Field]
    /// The link at the right of the Form's top bar: its `searchBarAccessory`, when that's a `Form.LinkAccessory`.
    public var linkAccessory: LinkAccessory?

    public init(_ view: UINode) {
        fields = view.children.compactMap(Self.field)
        linkAccessory = view.node("searchBarAccessory").flatMap(LinkAccessory.init)
    }

    static func field(_ node: UINode) -> Field? {
        let kind: Kind
        switch node.type {
        case "Form.TextField": kind = .textField
        case "Form.PasswordField": kind = .passwordField
        case "Form.TextArea": kind = .textArea
        case "Form.Checkbox": kind = .checkbox
        case "Form.Dropdown": kind = .dropdown
        case "Form.TagPicker": kind = .tagPicker
        case "Form.DatePicker": kind = .datePicker
        case "Form.FilePicker": kind = .filePicker
        case "Form.Description": kind = .description
        case "Form.Separator": kind = .separator
        case let type where type.hasPrefix("Form.") && !type.hasPrefix("Form.LinkAccessory"): kind = .unsupported(type)
        default: return nil
        }
        return Field(
            id: node.id,
            fieldId: node.string("id"),
            kind: kind,
            title: node.string("title"),
            placeholder: node.string("placeholder"),
            info: node.string("info"),
            error: node.string("error"),
            value: controlledValue(node.props["value"], kind: kind),
            defaultValue: node.props["defaultValue"].flatMap(ListContent.present),
            text: kind == .checkbox ? node.string("label") : node.string("text"),
            autoFocus: node.bool("autoFocus") == true,
            storesValue: node.bool("storeValue") == true && kind != .passwordField,
            hasOnFocus: node.hasCallback("onFocus"),
            hasOnBlur: node.hasCallback("onBlur"),
            options: kind == .dropdown ? SearchBarDropdown(node) : nil,
            tags: kind == .tagPicker ? node.children.compactMap(Self.tag) : [],
            dates: kind == .datePicker ? DatePickerOptions(node) : nil,
            files: kind == .filePicker ? FilePickerOptions(node) : nil
        )
    }

    /// A field's `value` prop as the extension controls it: nil when it sets none. JSON null is none too, except on a
    /// DatePicker, whose value is `Date | null` in Raycast's types: there `null` is a controlled value that shows no
    /// date. Raycast's types allow no `null` on the other fields.
    static func controlledValue(_ json: JSONValue?, kind: Kind) -> JSONValue? {
        guard let json else { return nil }
        return kind == .datePicker ? json : ListContent.present(json)
    }

    static func tag(_ node: UINode) -> SearchBarDropdown.Item? {
        guard node.type == "Form.TagPicker.Item", let value = node.string("value") else { return nil }
        return SearchBarDropdown.Item(
            title: node.string("title") ?? value, value: value, icon: node.props["icon"].flatMap(ListContent.present),
            keywords: [])
    }

    /// The submitted values to keep for next time (`storeValue`): those of fields that store theirs, by field
    /// `id`. A PasswordField's never is.
    public func valuesToStore(_ submitted: [String: JSONValue]) -> [String: JSONValue] {
        var kept: [String: JSONValue] = [:]
        for field in fields where field.storesValue && field.kind != .passwordField {
            if let id = field.fieldId, let value = submitted[id] { kept[id] = value }
        }
        return kept
    }
}

/// A Form's `searchBarAccessory`: a `Form.LinkAccessory`, drawn at the right of the Form's top bar. A click opens
/// `target` as `Action.OpenInBrowser` does.
public struct LinkAccessory: Sendable, Equatable {
    public var text: String
    public var target: String

    public init(text: String, target: String) {
        self.text = text
        self.target = target
    }

    /// Only a `Form.LinkAccessory` with both a `text` and a `target`; anything else in the prop is ignored.
    public init?(_ node: UINode) {
        guard node.type == "Form.LinkAccessory",
            let text = node.string("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let target = node.string("target"), !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(text: text, target: target)
    }
}

/// A Form.DatePicker's settings, and an Action.PickDate's.
public struct DatePickerOptions: Sendable, Equatable {
    /// Raycast's `Form.DatePicker.Type`.
    public enum Kind: String, Sendable, Equatable {
        case date
        case dateTime = "date_time"
    }

    public var type: Kind
    public var min: Date?
    public var max: Date?

    public init(type: Kind = .dateTime, min: Date? = nil, max: Date? = nil) {
        self.type = type
        self.min = min
        self.max = max
    }

    /// A Form.DatePicker's, from its node's props.
    init(_ node: UINode) {
        self.init(props: node.props)
    }

    /// Reads `type`, `min` and `max`. An extension's `min` after its `max` allows no date at all; fudge then ignores
    /// both, rather than refuse every pick.
    init(props: [String: JSONValue]) {
        var min = FormDates.date(props["min"])
        var max = FormDates.date(props["max"])
        if let low = min, let high = max, low > high {
            min = nil
            max = nil
        }
        var type = Kind.dateTime
        if case .string(let name) = props["type"], let kind = Kind(rawValue: name) { type = kind }
        self.init(type: type, min: min, max: max)
    }

    /// The dates the picker offers: from `min` to `max`, open where either is missing. Never an inverted range,
    /// which would trap.
    public var range: ClosedRange<Date> {
        let low = min ?? .distantPast
        let high = max ?? .distantFuture
        return low <= high ? low...high : Date.distantPast...Date.distantFuture
    }
}

/// Dates in Form values: they cross the bridge as `{ "$date": iso }`.
public enum FormDates {
    public static func date(_ json: JSONValue?) -> Date? {
        guard case .object(let object) = json, object.count == 1, case .string(let iso) = object["$date"] else {
            return nil
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso))
    }

    public static func json(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        return .object(["$date": .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))])
    }

    /// The value for a date the user picked: with `Date`, local midnight of that day; with `DateTime`, whole minutes.
    /// Kept within `min` and `max`, which with `Date` count by the day only.
    public static func value(for picked: Date, options: DatePickerOptions, calendar: Calendar = .current) -> Date {
        switch options.type {
        case .date:
            var day = calendar.startOfDay(for: picked)
            if let min = options.min.map(calendar.startOfDay(for:)), day < min { day = min }
            if let max = options.max.map(calendar.startOfDay(for:)), day > max { day = max }
            return day
        case .dateTime:
            func wholeMinute(_ date: Date) -> Date { calendar.dateInterval(of: .minute, for: date)?.start ?? date }
            var minute = wholeMinute(picked)
            // Limits with seconds clamp to the first and last whole minutes within them.
            if let min = options.min, minute < min {
                let start = wholeMinute(min)
                minute = start < min ? start.addingTimeInterval(60) : start
            }
            if let max = options.max, minute > max { minute = wholeMinute(max) }
            return minute
        }
    }

    /// `Form.DatePicker.isFullDay`: a date at local midnight exactly, as a `Date` picker gives.
    public static func isFullDay(_ date: Date?, calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return calendar.startOfDay(for: date) == date
    }
}

/// What a Form.FilePicker lets the user choose, with Raycast's defaults.
public struct FilePickerOptions: Sendable, Equatable {
    public var canChooseFiles = true
    public var canChooseDirectories = false
    public var allowsMultipleSelection = true
    public var showsHiddenFiles = false

    public init() {}

    init(_ node: UINode) {
        canChooseFiles = node.bool("canChooseFiles") ?? true
        canChooseDirectories = node.bool("canChooseDirectories") ?? false
        allowsMultipleSelection = node.bool("allowMultipleSelection") ?? true
        showsHiddenFiles = node.bool("showHiddenFiles") ?? false
    }
}

/// What a Form.FilePicker holds: absolute paths, in the order chosen.
public enum FilePicking {
    /// The paths after choosing `chosen` in the open panel: added after the ones there (each once), or, without
    /// multiple selection, in their place.
    public static func choosing(_ chosen: [String], to current: [String], options: FilePickerOptions) -> [String] {
        guard options.allowsMultipleSelection else { return Array(chosen.prefix(1)) }
        var paths = current
        for path in chosen where !paths.contains(path) { paths.append(path) }
        return paths
    }

    public static func removing(_ path: String, from current: [String]) -> [String] {
        current.filter { $0 != path }
    }
}

/// What a Form field shows after a render (`FormContent.Field.start`).
public struct FieldStart: Sendable, Equatable {
    public var value: JSONValue
    /// The extension should hear `value` through `onChange`.
    public var reports: Bool
    /// A stored value still waiting for the field's items.
    public var pending: JSONValue?

    public init(value: JSONValue, reports: Bool, pending: JSONValue?) {
        self.value = value
        self.reports = reports
        self.pending = pending
    }
}

/// What a Form.TagPicker holds: values of its own items, each once, in the order they were picked.
public enum TagPicking {
    /// The values in a field's value (`string[]`).
    public static func values(_ json: JSONValue?) -> [String] {
        guard case .array(let items) = json else { return [] }
        return items.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    /// Adds `value` at the end, if it's one of `items` and not already there.
    public static func adding(_ value: String, to current: [String], items: [SearchBarDropdown.Item]) -> [String] {
        guard items.contains(where: { $0.value == value }), !current.contains(value) else { return current }
        return current + [value]
    }

    public static func removing(_ value: String, from current: [String]) -> [String] {
        current.filter { $0 != value }
    }

    /// The items still to pick from, matching what's typed (title, by fuzzy match), in their own order.
    public static func suggestions(_ items: [SearchBarDropdown.Item], chosen: [String], query: String)
        -> [SearchBarDropdown.Item]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            !chosen.contains(item.value) && (trimmed.isEmpty || Fuzzy.match(trimmed, in: item.title) != nil)
        }
    }
}

/// The values of Form fields with `storeValue`, saved when their form is submitted: one JSON file per extension in
/// `form-values/`, by the extension's id, then command name and field `id`. Dates are kept as `{ "$date": iso }`, as
/// they cross the bridge.
public struct FormValueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(extension id: ExtensionID, command: String) -> [String: JSONValue] {
        loadAll(id)[command] ?? [:]
    }

    /// Saves `values` for the command, keeping the other fields' and commands' values.
    public func save(_ values: [String: JSONValue], extension id: ExtensionID, command: String) throws {
        guard !values.isEmpty else { return }
        var all = loadAll(id)
        all[command, default: [:]].merge(values) { _, new in new }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file(id), options: .atomic)
    }

    private func file(_ id: ExtensionID) -> URL {
        directory.appendingPathComponent("\(id.key).json")
    }

    private func loadAll(_ id: ExtensionID) -> [String: [String: JSONValue]] {
        guard let data = try? Data(contentsOf: file(id)) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data)) ?? [:]
    }
}

/// A field's value in the app while the user edits it.
///
/// The app shows what the user typed straight away and tells the extension (`onChange`). When the extension
/// controls the value, it renders it back, but a render may still carry a value from a few keystrokes ago.
/// Adopting that would undo typing, so values the app sent and hasn't seen settle yet are recognised as echoes.
public struct FieldValue: Sendable, Equatable {
    public private(set) var value: JSONValue
    private var pending: [JSONValue] = []

    public init(_ value: JSONValue) {
        self.value = value
    }

    /// The user changed the value.
    public mutating func edit(_ new: JSONValue) {
        value = new
        pending.append(new)
    }

    /// The extension rendered the field again; `controlled` is its `value` prop, if it sets one.
    public mutating func render(controlled: JSONValue?) {
        guard let controlled else { return }
        if controlled == value {
            pending = []
        } else if let echo = pending.firstIndex(of: controlled) {
            pending.removeFirst(echo + 1)
        } else {
            // The extension set a value of its own.
            value = controlled
            pending = []
        }
    }
}
