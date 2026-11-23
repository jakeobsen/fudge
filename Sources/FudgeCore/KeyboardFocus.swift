/// Which field gets the keyboard when it has to be put back: each time the launcher panel is shown, and after a
/// click on a row, which can leave AppKit's first responder outside every field.
public enum KeyboardFocus {
    /// What's on screen, as far as the keyboard is concerned.
    public enum Screen: Sendable, Equatable {
        /// Root search. `argument` is the argument field that has the keyboard, if any.
        case root(argument: Int?, argumentIsDropdown: Bool)
        /// A command with a search field: a List, or one that hasn't rendered yet or failed.
        case search
        /// A Form: the field that had the keyboard last, and the one it starts in. `lastInTimeBox`: the keyboard was
        /// last in that field's time box (a `DateTime` field's time).
        case form(lastField: Int?, firstField: Int?, lastInTimeBox: Bool = false)
        /// A view with no text field (Detail). Its keys go through the launcher's own key handling.
        case noField
        /// Root search's failure screen, which keeps the search field.
        case failure
    }

    public enum Target: Sendable, Equatable {
        case search
        case argument(Int)
        case actionPanel
        case dropdownPanel
        case formField(Int)
        /// A `DateTime` field's time box.
        case formTimeBox(Int)
        case none
    }

    /// The field for `screen`. An open action panel or dropdown panel has its own search field, which wins. A
    /// dropdown argument takes no typing, so root search's search field gets the keyboard instead.
    public static func target(for screen: Screen, actionPanelOpen: Bool = false, dropdownPanelOpen: Bool = false)
        -> Target
    {
        if actionPanelOpen { return .actionPanel }
        if dropdownPanelOpen { return .dropdownPanel }
        switch screen {
        case .root(let argument?, false): return .argument(argument)
        case .root, .search, .failure: return .search
        case .form(let last?, _, true): return .formTimeBox(last)
        case .form(let last, let first, _): return (last ?? first).map(Target.formField) ?? .none
        case .noField: return .none
        }
    }
}

// MARK: - A Form's own fields

extension KeyboardFocus {
    /// A Form's fields changed (`editable`, in order; `first` is the one it starts in). The field to give the
    /// keyboard to, or nil to leave it as it is: `first`, when no field of the form has it (`focused` is nil or gone).
    /// Never while an overlay holds the keyboard (`overlayOpen`: the action panel, an `Action.PickDate` picker in it,
    /// or a dropdown's panel): the overlay's closing hands it back (`formFieldAfterOverlay`).
    public static func formFieldAfterFieldsChange(focused: Int?, editable: [Int], first: Int?, overlayOpen: Bool)
        -> Int?
    {
        guard !overlayOpen else { return nil }
        if let focused, editable.contains(focused) { return nil }
        return first
    }

    /// An overlay that held the keyboard closed: the Form field that had it last, if it's still there, else the one
    /// the form starts in.
    public static func formFieldAfterOverlay(last: Int?, editable: [Int], first: Int?) -> Int? {
        if let last, editable.contains(last) { return last }
        return first
    }

    /// A Form appeared: the field it asks to give the keyboard to (through `FormScreen.refocus`, a turn later, since
    /// the launcher's search field going away in the same update would take it back). That's `first`, the first
    /// editable field with `autoFocus`, when it's one of `editable`, else the first of `editable`. Nil while an
    /// overlay holds the keyboard: the field takes it when the overlay closes (`formFieldAfterOverlay`).
    public static func formFieldOnAppear(editable: [Int], first: Int?, overlayOpen: Bool) -> Int? {
        guard !overlayOpen else { return nil }
        if let first, editable.contains(first) { return first }
        return editable.first
    }

    /// Where a Form's keyboard is: a field, or the time box of a `DateTime` DatePicker field (its time, beside its
    /// date).
    public enum FormStop: Sendable, Equatable {
        case field(Int)
        case timeBox(Int)

        /// The field it's in.
        public var field: Int {
            switch self {
            case .field(let field), .timeBox(let field): field
            }
        }
    }

    /// An editable field of a Form, in order, as Tab sees it: `hasTimeBox` while it's a `DateTime` field with a date,
    /// whose time box is a stop of its own after the date.
    public struct TabField: Sendable, Equatable {
        public var id: Int
        public var hasTimeBox: Bool

        public init(id: Int, hasTimeBox: Bool = false) {
            self.id = id
            self.hasTimeBox = hasTimeBox
        }
    }

    /// Tab in a Form, or ⇧Tab `backwards`: the place after `now` (where the keyboard is now, nil for nowhere), or
    /// before it, among the fields' places in order, each field and then its time box, if it has one. It wraps from
    /// the last place to the first and from the first to the last, as AppKit's key view loop does. From nowhere, or
    /// from a place that's gone, it's the first place (the last, backwards). Nil for a form with no editable field:
    /// the key is taken and does nothing.
    public static func formFieldAfterTab(now: FormStop?, fields: [TabField], backwards: Bool) -> FormStop? {
        let places = fields.flatMap { field in
            field.hasTimeBox ? [FormStop.field(field.id), .timeBox(field.id)] : [.field(field.id)]
        }
        guard !places.isEmpty else { return nil }
        guard let now, let index = places.firstIndex(of: now) else {
            return backwards ? places.last : places.first
        }
        return places[(index + (backwards ? -1 : 1) + places.count) % places.count]
    }
}

/// Where a Form's keyboard is now, and the field that had it last, which `onBlur` and `onFocus` follow. FormScreen
/// reports every move, nowhere included (`LauncherModel.formKeyboardMoved`). The two differ once the keyboard has
/// left every field, after a click on the form's background, say: Tab then starts from the first field, while the
/// last field still names the one `onBlur` goes to next and the one the panel's showing gives the keyboard back to.
public struct FormKeyboard: Sendable, Equatable {
    /// Where the keyboard is now; nil when it's in no field.
    public private(set) var now: KeyboardFocus.FormStop?
    /// The place the keyboard was last in, which a move to nowhere leaves as it is.
    public private(set) var last: KeyboardFocus.FormStop?
    /// The places the launcher asked for (Tab), oldest first, that the keyboard hasn't reached yet.
    public private(set) var asked: [KeyboardFocus.FormStop] = []

    public init() {}

    /// The field that had the keyboard last: a time box counts as its field.
    public var lastField: Int? { last?.field }

    /// Where Tab goes on from: the place asked for last while it's on its way, else where the keyboard is now. A Tab
    /// pressed before the last one has landed (two in a row, or a held key) moves on from there.
    public var tabFrom: KeyboardFocus.FormStop? { asked.last ?? now }

    /// The launcher asked for `place`: the view gives it the keyboard through nowhere, a turn later
    /// (`FormScreen.refocus`).
    public mutating func ask(for place: KeyboardFocus.FormStop) {
        asked.append(place)
    }

    /// The keyboard moved to `stop`, or to no field (nil). When it went into another field than the last one, the
    /// answer is the field it left (if any, for `onBlur`) and the one it entered (for `onFocus`); a move to nowhere,
    /// or between a field's date and its time box, answers nil. Nowhere on the way to a place asked for doesn't
    /// count, since that's the keyboard passing through. Reaching a place asked for settles it and those asked before
    /// it, while a later one is still on its way (several Tabs at once); reaching any other place (a click) settles
    /// them all.
    public mutating func moved(to stop: KeyboardFocus.FormStop?) -> (left: Int?, entered: Int)? {
        guard let stop else {
            if asked.isEmpty { now = nil }
            return nil
        }
        now = stop
        if let reached = asked.firstIndex(of: stop) { asked.removeFirst(reached + 1) } else { asked = [] }
        let left = lastField
        last = stop
        return left == stop.field ? nil : (left, stop.field)
    }
}

extension FormContent {
    /// The fields that take the keyboard, in order: not a Description, a Separator or a field Fudge can't draw.
    public var editableFields: [Field] { fields.filter(\.isEditable) }

    /// The ids of `editableFields`.
    public var editableIDs: [Int] { editableFields.map(\.id) }

    /// The editable fields as Tab sees them (`KeyboardFocus.formFieldAfterTab`), `value` giving each field's value now,
    /// which decides whether a `DateTime` field has a time box.
    public func tabFields(value: (Int) -> JSONValue?) -> [KeyboardFocus.TabField] {
        editableFields.map { field in
            KeyboardFocus.TabField(id: field.id, hasTimeBox: field.showsTimeBox(value: value(field.id)))
        }
    }

    /// The first editable field with `autoFocus`, if any.
    public var autoFocusID: Int? { fields.first { $0.isEditable && $0.autoFocus }?.id }
}

extension FormContent.Field {
    /// Whether it shows a time box beside its date: a `DateTime` DatePicker (the type it has unless it says otherwise)
    /// with a date, `value` being the field's value now.
    public func showsTimeBox(value: JSONValue?) -> Bool {
        kind == .datePicker && (dates ?? DatePickerOptions()).type == .dateTime && FormDates.date(value) != nil
    }
}
