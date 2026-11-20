import Foundation

/// A Form view as fudge draws it: its fields in order.
public struct FormContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case textField, passwordField, textArea, checkbox, dropdown, tagPicker, description, separator
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
        /// Set when the extension controls the value.
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

        /// Whether the user can change it.
        public var isEditable: Bool {
            switch kind {
            case .textField, .passwordField, .textArea, .checkbox, .dropdown, .tagPicker: true
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
            case .tagPicker: .array([])
            case .dropdown: .null
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

        /// The argument of `onFocus` and `onBlur`: Raycast's `FormEvent`.
        public func focusEvent(_ type: String, value: JSONValue) -> JSONValue {
            .object([
                "target": .object(["id": fieldId.map(JSONValue.string) ?? .null, "value": value]),
                "type": .string(type),
            ])
        }
    }

    public var fields: [Field]

    public init(_ view: UINode) {
        fields = view.children.compactMap(Self.field)
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
            value: node.props["value"].flatMap(ListContent.present),
            defaultValue: node.props["defaultValue"].flatMap(ListContent.present),
            text: kind == .checkbox ? node.string("label") : node.string("text"),
            autoFocus: node.bool("autoFocus") == true,
            storesValue: node.bool("storeValue") == true && kind != .passwordField,
            hasOnFocus: node.hasCallback("onFocus"),
            hasOnBlur: node.hasCallback("onBlur"),
            options: kind == .dropdown ? SearchBarDropdown(node) : nil,
            tags: kind == .tagPicker ? node.children.compactMap(Self.tag) : []
        )
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
/// `form-values/`, by command name and field `id`. Dates are kept as `{ "$date": iso }`, as they cross the bridge.
public struct FormValueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(extension name: String, command: String) -> [String: JSONValue] {
        loadAll(name)[command] ?? [:]
    }

    /// Saves `values` for the command, keeping the other fields' and commands' values.
    public func save(_ values: [String: JSONValue], extension name: String, command: String) throws {
        guard !values.isEmpty else { return }
        var all = loadAll(name)
        all[command, default: [:]].merge(values) { _, new in new }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file(name), options: .atomic)
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    private func loadAll(_ name: String) -> [String: [String: JSONValue]] {
        guard let data = try? Data(contentsOf: file(name)) else { return [:] }
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
