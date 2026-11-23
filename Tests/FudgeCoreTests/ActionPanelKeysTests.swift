import Testing

@testable import FudgeCore

// SPEC-161 C: the action panel shows the primary and secondary keys on the first two actions, as Raycast does.

private func entry(_ id: Int, _ title: String, _ shortcut: KeyShortcut? = nil, submenu: [ActionSection]? = nil)
    -> ActionEntry
{
    ActionEntry(
        id: id, title: title, icon: nil, shortcut: shortcut, destructive: false, submenu: submenu, isLoading: false,
        target: .node(id))
}

private let enter = KeyShortcut(key: "return", modifiers: [])
private let commandEnter = KeyShortcut(key: "return", modifiers: ["cmd"])
private let commandShiftEnter = KeyShortcut(key: "return", modifiers: ["cmd", "shift"])
private let commandShiftX = KeyShortcut(key: "x", modifiers: ["cmd", "shift"])
private let commandD = KeyShortcut(key: "d", modifiers: ["cmd"])
private let commandE = KeyShortcut(key: "e", modifiers: ["cmd"])

/// The keys a panel shows, by entry id: in a List (↵ and ⌘↵) unless other keys are given.
private func keys(
    _ sections: [ActionSection], shown: [ActionEntry]? = nil, primary: KeyShortcut? = enter,
    secondary: KeyShortcut? = commandEnter, inSubmenu: Bool = false
) -> [Int: KeyShortcut?] {
    var keys: [Int: KeyShortcut?] = [:]
    for entry in shown ?? ActionPanelReader.flat(sections) {
        keys[entry.id] = ActionPanelReader.shownKey(
            of: entry, in: sections, primaryKey: primary, secondaryKey: secondary, inSubmenu: inSubmenu)
    }
    return keys
}

/// A task item's actions: Mark Done…, Can't Do It… on ⇧⌘X, and Open Details on ⌘D.
private let taskActions = [
    ActionSection(
        title: nil,
        entries: [entry(1, "Mark Done…"), entry(2, "Can't Do It…", commandShiftX), entry(3, "Open Details", commandD)])
]

@Test func aListsPanelShowsReturnAndCommandReturnOnItsFirstTwoActions() {
    #expect(keys(taskActions) == [1: enter, 2: commandEnter, 3: commandD], "⇧⌘X still runs Can't Do It…")
}

@Test func aFormsPanelShowsCommandReturnAndCommandShiftReturn() {
    #expect(
        keys(taskActions, primary: commandEnter, secondary: commandShiftEnter)
            == [1: commandEnter, 2: commandShiftEnter, 3: commandD])
}

@Test func theFirstTwoActionsOwnShortcutsArentShown() {
    let own = [ActionSection(title: nil, entries: [entry(1, "Open", commandE), entry(2, "Copy", commandD)])]
    #expect(keys(own) == [1: enter, 2: commandEnter])
}

@Test func theFirstTwoActionsAreCountedAcrossSections() {
    let two = [
        ActionSection(title: nil, entries: [entry(1, "Open")]),
        ActionSection(title: "More", entries: [entry(2, "Copy", commandE), entry(3, "Delete", commandD)]),
    ]
    #expect(keys(two) == [1: enter, 2: commandEnter, 3: commandD], "the second action is section two's first")
}

@Test func aSearchInThePanelKeepsTheKeysOnTheSameActions() {
    let filtered = ActionPanelReader.filter(taskActions, query: "do it")
    #expect(ActionPanelReader.flat(filtered).map(\.id) == [2])
    #expect(keys(taskActions, shown: ActionPanelReader.flat(filtered)) == [2: commandEnter])
    let details = ActionPanelReader.flat(ActionPanelReader.filter(taskActions, query: "details"))
    #expect(keys(taskActions, shown: details) == [3: commandD], "the only row left isn't the primary action")
}

@Test func aSubmenuShowsOnlyItsEntriesOwnShortcuts() {
    let inner = [ActionSection(title: nil, entries: [entry(11, "Safari"), entry(12, "Chrome", commandE)])]
    let panel = [
        ActionSection(title: nil, entries: [entry(10, "Open With…", commandD, submenu: inner), entry(1, "Copy")])
    ]
    #expect(keys(inner, inSubmenu: true) == [11: nil, 12: commandE])
    #expect(keys(panel) == [10: enter, 1: commandEnter], "at the top level, the submenu is the first action")
}

@Test func rootSearchsPanelShowsItsEntriesOwnKeys() {
    let root = RootActions.calculatorSections()
    let shown = keys(root, primary: nil, secondary: nil)
    #expect(shown == Dictionary(uniqueKeysWithValues: ActionPanelReader.flat(root).map { ($0.id, $0.shortcut) }))
    #expect(ActionPanelReader.flat(root).first?.shortcut == enter, "its first entry carries ↵ itself")
}
