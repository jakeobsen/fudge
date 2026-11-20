import Foundation
import Testing

@testable import FudgeCore

@Test func readsShortcutsInBothShapes() {
    let plain = KeyShortcut(
        json: .object(["modifiers": .array([.string("cmd"), .string("shift")]), "key": .string("C")]))
    #expect(plain == KeyShortcut(key: "c", modifiers: ["cmd", "shift"]))
    let paired = KeyShortcut(
        json: .object([
            "macOS": .object(["modifiers": .array([.string("ctrl")]), "key": .string("x")]),
            "Windows": .object(["modifiers": .array([.string("ctrl")]), "key": .string("d")]),
        ])
    )
    #expect(paired == KeyShortcut(key: "x", modifiers: ["ctrl"]), "the macOS half wins")
    #expect(KeyShortcut(key: "c", modifiers: ["alt"]) == KeyShortcut(key: "c", modifiers: ["opt"]))
    #expect(KeyShortcut(json: .string("cmd+c")) == nil)
    #expect(KeyShortcut(json: nil) == nil)
}

@Test func showsShortcutsTheWayMenusDo() {
    #expect(KeyShortcut(key: "c", modifiers: ["shift", "cmd"]).description == "⇧⌘C")
    #expect(KeyShortcut(key: "arrowUp", modifiers: ["cmd", "opt"]).description == "⌥⌘↑")
    #expect(KeyShortcut(key: "return", modifiers: ["cmd"]).description == "⌘↵")
    #expect(KeyShortcut(key: "x", modifiers: ["ctrl"]).description == "⌃X")
}

@Test func namesKeyPresses() {
    #expect(KeyShortcut.key(forKeyCode: 36, characters: "\r") == "return")
    #expect(KeyShortcut.key(forKeyCode: 126, characters: nil) == "arrowUp")
    #expect(KeyShortcut.key(forKeyCode: 8, characters: "C") == "c")
    #expect(KeyShortcut.key(forKeyCode: 47, characters: ".") == ".")
    #expect(KeyShortcut.key(forKeyCode: 0, characters: "") == nil)
}

@Test func resolvesShiftedPunctuationByTheUnshiftedKey() {
    // ⌘⇧, on key code 43: the key without modifiers types ",", whatever ⇧ would make of it ("<" US, ";" Danish).
    #expect(
        KeyShortcut(keyCode: 43, characters: ",", modifiers: ["cmd", "shift"])
            == KeyShortcut(key: ",", modifiers: ["cmd", "shift"]))
    #expect(
        KeyShortcut(keyCode: 3, characters: "f", modifiers: ["cmd", "shift"])
            == KeyShortcut(key: "f", modifiers: ["cmd", "shift"]))
    #expect(
        KeyShortcut(keyCode: 36, characters: "\r", modifiers: ["cmd"]) == KeyShortcut(key: "return", modifiers: ["cmd"])
    )
    #expect(KeyShortcut(keyCode: 0, characters: nil, modifiers: ["cmd"]) == nil)
}

private func node(_ json: String) throws -> UINode {
    try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
}

private let panel = #"""
    {"id":20,"type":"ActionPanel","props":{},"children":[
      {"id":1,"type":"Action","props":{"title":"Open","onAction":{"$fn":["onAction"]}},"children":[]},
      {"id":2,"type":"Action","props":{"title":"Copy Path","shortcut":{"macOS":{"modifiers":["cmd","ctrl"],"key":"c"},"Windows":{"modifiers":["alt"],"key":"c"}}},"children":[]},
      {"id":10,"type":"ActionPanel.Section","props":{"title":"Danger"},"children":[
        {"id":3,"type":"Action","props":{"title":"Move to Trash","style":"destructive","shortcut":{"modifiers":["ctrl"],"key":"x"}},"children":[]}
      ]},
      {"id":11,"type":"ActionPanel.Submenu","props":{"title":"Open With","isLoading":false},"children":[
        {"id":4,"type":"Action","props":{"title":"TextEdit","shortcut":{"modifiers":["cmd"],"key":"t"}},"children":[]}
      ]}
    ]}
    """#

@Test func readsAnActionPanelIntoSections() throws {
    let sections = ActionPanelReader.sections(of: try node(panel))
    #expect(sections.map(\.title) == [nil, "Danger", nil])
    #expect(sections.map { $0.entries.map(\.title) } == [["Open", "Copy Path"], ["Move to Trash"], ["Open With"]])
    #expect(sections[1].entries[0].destructive)
    #expect(sections[2].entries[0].isSubmenu)
    #expect(sections[2].entries[0].submenu?.first?.entries.map(\.title) == ["TextEdit"])
    #expect(ActionPanelReader.primary(sections)?.title == "Open")
    #expect(ActionPanelReader.secondary(sections)?.title == "Copy Path")
    #expect(ActionPanelReader.sections(of: nil).isEmpty)
    #expect(ActionPanelReader.flat(sections).map(\.target) == [.node(1), .node(2), .node(3), .node(11)])
}

private func rootEntries(_ item: RootItem?) -> [String] {
    ActionPanelReader.flat(RootActions.sections(for: item)).map { "\($0.title) \($0.shortcut?.description ?? "-")" }
}

private let commandItem = RootItem(
    id: "command:scratch/create-scratch",
    title: "Create Scratch",
    kind: .command(
        extension: "scratch", command: "create-scratch", mode: "no-view",
        entry: URL(fileURLWithPath: "/tmp/create-scratch.cjs"))
)
private let applicationItem = RootItem.application(
    at: URL(fileURLWithPath: "/Applications/Notes.app"), title: "Notes")

@Test func rootSearchItemsHaveTheirOwnActions() {
    #expect(rootEntries(commandItem) == ["Open Command ↵", "Configure Extension ⇧⌘,"])
    #expect(rootEntries(applicationItem) == ["Open Application ↵", "Show in Finder ⇧⌘F"])
    #expect(rootEntries(.settings) == ["Open Settings ↵"])
    #expect(rootEntries(.reloadExtensions) == ["Reload Extensions ↵"])
    #expect(rootEntries(.quit) == ["Quit Fudge ↵"])
    for item in [RootItem.reloadExtensions, .quit] {
        #expect(ActionPanelReader.flat(RootActions.sections(for: item)).map(\.target) == [.root(.open)])
    }
    #expect(RootActions.sections(for: nil).isEmpty)

    let command = ActionPanelReader.flat(RootActions.sections(for: commandItem))
    #expect(command.map(\.target) == [.root(.open), .root(.configureExtension("scratch"))])
    let application = ActionPanelReader.flat(RootActions.sections(for: applicationItem))
    #expect(
        application.map(\.target) == [
            .root(.open), .root(.showInFinder(URL(fileURLWithPath: "/Applications/Notes.app"))),
        ])
    #expect(Set(command.map(\.id)).count == command.count, "entries are told apart by id in the panel")
}

@Test func rootActionShortcutsWorkWithoutThePanel() {
    let commandActions = RootActions.sections(for: commandItem)
    #expect(
        ActionPanelReader.action(for: RootActions.configureExtensionShortcut, in: commandActions)?.target
            == .root(.configureExtension("scratch")))
    #expect(
        ActionPanelReader.action(for: RootActions.showInFinderShortcut, in: RootActions.sections(for: applicationItem))?
            .title == "Show in Finder")
    #expect(ActionPanelReader.action(for: RootActions.showInFinderShortcut, in: commandActions) == nil)
    #expect(RootActions.settingsShortcut == KeyShortcut(key: ",", modifiers: ["cmd"]))
    #expect(RootActions.configureExtensionShortcut == KeyShortcut(key: ",", modifiers: ["cmd", "shift"]))
}

@Test func findsActionsByShortcutIncludingInSubmenus() throws {
    let sections = ActionPanelReader.sections(of: try node(panel))
    #expect(ActionPanelReader.action(for: KeyShortcut(key: "x", modifiers: ["ctrl"]), in: sections)?.id == 3)
    #expect(ActionPanelReader.action(for: KeyShortcut(key: "c", modifiers: ["cmd", "ctrl"]), in: sections)?.id == 2)
    #expect(ActionPanelReader.action(for: KeyShortcut(key: "t", modifiers: ["cmd"]), in: sections)?.id == 4)
    #expect(ActionPanelReader.action(for: KeyShortcut(key: "z", modifiers: ["cmd"]), in: sections) == nil)
}

@Test func filtersActionsByTitle() throws {
    let sections = ActionPanelReader.sections(of: try node(panel))
    let filtered = ActionPanelReader.filter(sections, query: "trash")
    #expect(filtered.map(\.title) == ["Danger"])
    #expect(filtered.first?.entries.map(\.title) == ["Move to Trash"])
    #expect(ActionPanelReader.filter(sections, query: " ") == sections)
}

@Test func theCalculatorCardCopiesItsAnswer() {
    let entries = ActionPanelReader.flat(RootActions.calculatorSections())
    #expect(entries.map(\.title) == ["Copy Answer", "Copy Question and Answer"])
    #expect(entries.map(\.shortcut?.description) == ["↵", "⇧⌘C"])
    #expect(entries.map(\.target) == [.root(.copyAnswer), .root(.copyQuestionAndAnswer)])
    #expect(ActionPanelReader.primary(RootActions.calculatorSections())?.title == "Copy Answer", "↵ copies")
}
