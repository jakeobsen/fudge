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
