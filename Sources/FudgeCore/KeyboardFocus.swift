/// Which field gets the keyboard when it has to be put back: each time the launcher panel is shown, and after a
/// click on a row, which can leave AppKit's first responder outside every field.
public enum KeyboardFocus {
    /// What's on screen, as far as the keyboard is concerned.
    public enum Screen: Sendable, Equatable {
        /// Root search. `argument` is the argument field that has the keyboard, if any.
        case root(argument: Int?, argumentIsDropdown: Bool)
        /// A command with a search field: a List, or one that hasn't rendered yet or failed.
        case search
        /// A Form: the place the keyboard was last in (`FormKeyboard.last`), a field or its time box (a `DateTime`
        /// field's time), the editable fields as Tab sees them now, and the field it starts in.
        case form(last: FormStop?, fields: [TabField], firstField: Int?)
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
    /// dropdown argument takes no typing, so root search's search field gets the keyboard instead. A Form's is the
    /// place an overlay's closing gives back (`formPlaceAfterOverlay`), so a time box whose date was cleared meanwhile
    /// gives its field.
    public static func target(for screen: Screen, actionPanelOpen: Bool = false, dropdownPanelOpen: Bool = false)
        -> Target
    {
        if actionPanelOpen { return .actionPanel }
        if dropdownPanelOpen { return .dropdownPanel }
        switch screen {
        case .root(let argument?, false): return .argument(argument)
        case .root, .search, .failure: return .search
        case .form(let last, let fields, let first):
            switch formPlaceAfterOverlay(last: last, fields: fields, first: first) {
            case .timeBox(let field)?: return .formTimeBox(field)
            case .field(let field)?: return .formField(field)
            case nil: return .none
            }
        case .noField: return .none
        }
    }
}

// MARK: - A Form's own fields

extension KeyboardFocus {
    /// A Form's fields changed (`editable`, in order; `first` is the one it starts in). The field to give the
    /// keyboard to, or nil to leave it as it is: `first`, when no field of the form has it (`focused` is nil or gone).
    /// Never while an overlay holds the keyboard (`overlayOpen`: the action panel, an `Action.PickDate` picker in it,
    /// or a dropdown's panel): the overlay's closing hands it back (`formPlaceAfterOverlay`).
    public static func formFieldAfterFieldsChange(focused: Int?, editable: [Int], first: Int?, overlayOpen: Bool)
        -> Int?
    {
        guard !overlayOpen else { return nil }
        if let focused, editable.contains(focused) { return nil }
        return first
    }

    /// An overlay that held the keyboard closed (the action panel, an `Action.PickDate` picker in it, or a dropdown's
    /// panel), or the panel was shown: the place to give a Form's keyboard back to, from `last`, the place it was last
    /// in (`FormKeyboard.last`), with `fields` the editable fields as Tab sees them now. That's the time box while its
    /// field still shows one; the field when that's where it was, or when its time box went meanwhile (its date was
    /// cleared); else `first`, the field the form starts in, when the last place is gone or there's none.
    public static func formPlaceAfterOverlay(last: FormStop?, fields: [TabField], first: Int?) -> FormStop? {
        if let last, let field = fields.first(where: { $0.id == last.field }) {
            if case .timeBox = last, field.hasTimeBox { return last }
            return .field(field.id)
        }
        return first.map(FormStop.field)
    }

    /// A Form appeared: the place to give the keyboard to (through `FormScreen.give`, a turn later). Nil while an
    /// overlay holds the keyboard; else `formPlaceAfterOverlay`'s place, with `formFieldOnAppear`'s field as the one it
    /// starts in. A Form that shows for the first time, or after a view was pushed or popped, has a new
    /// `FormKeyboard` with no last place, so it starts in that field; one that comes back from the sign-in prompt,
    /// which took its place on screen, gets the place it was last in.
    public static func formPlaceOnAppear(last: FormStop?, fields: [TabField], autoFocus: Int?, overlayOpen: Bool)
        -> FormStop?
    {
        guard !overlayOpen else { return nil }
        let first = formFieldOnAppear(editable: fields.map(\.id), first: autoFocus, overlayOpen: false)
        return formPlaceAfterOverlay(last: last, fields: fields, first: first)
    }

    /// Which of a Form's fields show a time box changed: when the keyboard was in a time box that went (its date was
    /// cleared, by ⌫ in an `Action.PickDate` picker, an action or the extension), its field, to give the keyboard to;
    /// else nil, nothing to do. The place is the keyboard's `now`, or its last place while it's nowhere, since the
    /// time box can take the keyboard with it before the fields say it went. Nil while an overlay holds the keyboard
    /// (its closing gives the field, `formPlaceAfterOverlay`), for a field, for a time box still shown, and for a field
    /// that's gone (`formFieldAfterFieldsChange` sees to that).
    public static func formFieldAfterTimeBoxGone(keyboard: FormKeyboard, fields: [TabField], overlayOpen: Bool)
        -> Int?
    {
        guard !overlayOpen, case .timeBox(let id)? = keyboard.now ?? keyboard.last else { return nil }
        guard let field = fields.first(where: { $0.id == id }), !field.hasTimeBox else { return nil }
        return id
    }

    /// A Form appeared: the field it asks to give the keyboard to (through `FormScreen.refocus`, a turn later, since
    /// the launcher's search field going away in the same update would take it back). That's `first`, the first
    /// editable field with `autoFocus`, when it's one of `editable`, else the first of `editable`. Nil while an
    /// overlay holds the keyboard: the field takes it when the overlay closes (`formPlaceAfterOverlay`).
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
/// last field still names the one `onBlur` goes to next, and the last place the one an overlay's closing and the
/// panel's showing give the keyboard back to (`KeyboardFocus.formPlaceAfterOverlay`). A push or a pop starts a new one.
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
