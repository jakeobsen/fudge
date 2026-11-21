import Testing

@testable import FudgeCore

@Test func rootSearchWantsTheSearchFieldOrAFocusedTextArgument() {
    #expect(KeyboardFocus.target(for: .root(argument: nil, argumentIsDropdown: false)) == .search)
    #expect(KeyboardFocus.target(for: .root(argument: 1, argumentIsDropdown: false)) == .argument(1))
    #expect(
        KeyboardFocus.target(for: .root(argument: 0, argumentIsDropdown: true)) == .search,
        "a dropdown argument takes no typing")
    #expect(KeyboardFocus.target(for: .failure) == .search)
}

@Test func commandScreensWantTheirOwnField() {
    #expect(KeyboardFocus.target(for: .search) == .search, "a List's search field")
    #expect(KeyboardFocus.target(for: .form(lastField: 7, firstField: 3)) == .formField(7), "the last field")
    #expect(KeyboardFocus.target(for: .form(lastField: nil, firstField: 3)) == .formField(3), "else the first")
    #expect(KeyboardFocus.target(for: .form(lastField: nil, firstField: nil)) == .none, "a form with no fields")
    #expect(KeyboardFocus.target(for: .noField) == .none, "a Detail")
}

@Test func anOpenPanelKeepsTheKeyboardInItsSearchField() {
    #expect(KeyboardFocus.target(for: .search, actionPanelOpen: true) == .actionPanel)
    #expect(KeyboardFocus.target(for: .noField, actionPanelOpen: true) == .actionPanel, "⌘K in a Detail")
    #expect(KeyboardFocus.target(for: .form(lastField: 2, firstField: 1), actionPanelOpen: true) == .actionPanel)
    #expect(KeyboardFocus.target(for: .search, dropdownPanelOpen: true) == .dropdownPanel)
    #expect(
        KeyboardFocus.target(for: .root(argument: 1, argumentIsDropdown: false), actionPanelOpen: true)
            == .actionPanel)
}

@Test func aFormsNewFieldsTakeTheKeyboardOnlyWhenNoFieldAndNoOverlayHasIt() {
    func after(focused: Int?, editable: [Int] = [3, 5, 7], first: Int? = 3, overlayOpen: Bool = false) -> Int? {
        KeyboardFocus.formFieldAfterFieldsChange(
            focused: focused, editable: editable, first: first, overlayOpen: overlayOpen)
    }
    #expect(after(focused: nil) == 3, "no field had it: the first takes it")
    #expect(after(focused: 9) == 3, "the field that had it is gone")
    #expect(after(focused: 5) == nil, "a field still has it")
    #expect(after(focused: nil, editable: [], first: nil) == nil, "no fields left")
    #expect(
        after(focused: nil, overlayOpen: true) == nil,
        "an Action.PickDate picker or another overlay holds the keyboard: nothing takes it from there")
    #expect(after(focused: 9, overlayOpen: true) == nil)
}

@Test func closingAnOverlayGivesTheLastFieldTheKeyboardOrElseTheFirst() {
    #expect(KeyboardFocus.formFieldAfterOverlay(last: 5, editable: [3, 5, 7], first: 3) == 5)
    #expect(
        KeyboardFocus.formFieldAfterOverlay(last: 9, editable: [3, 7], first: 3) == 3,
        "the last field went while the overlay was open")
    #expect(KeyboardFocus.formFieldAfterOverlay(last: nil, editable: [3, 7], first: 7) == 7)
    #expect(KeyboardFocus.formFieldAfterOverlay(last: 5, editable: [], first: nil) == nil)
}

@Test func showingThePanelWithAPickerOpenLeavesTheKeyboardWithTheOverlay() {
    // An Action.PickDate picker lives in the action panel overlay, so a Form under it gets no field back.
    #expect(KeyboardFocus.target(for: .form(lastField: 2, firstField: 1), actionPanelOpen: true) == .actionPanel)
}
