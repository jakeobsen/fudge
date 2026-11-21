/// Which field gets the keyboard when it has to be put back: each time the launcher panel is shown, and after a
/// click on a row, which can leave AppKit's first responder outside every field.
public enum KeyboardFocus {
    /// What's on screen, as far as the keyboard is concerned.
    public enum Screen: Sendable, Equatable {
        /// Root search. `argument` is the argument field that has the keyboard, if any.
        case root(argument: Int?, argumentIsDropdown: Bool)
        /// A command with a search field: a List, or one that hasn't rendered yet or failed.
        case search
        /// A Form: the field that had the keyboard last, and the one it starts in.
        case form(lastField: Int?, firstField: Int?)
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
        case .form(let last, let first): return (last ?? first).map(Target.formField) ?? .none
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
}
