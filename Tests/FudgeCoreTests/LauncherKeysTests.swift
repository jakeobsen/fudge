import Foundation
import Testing

@testable import FudgeCore

// SPEC-127: in Fudge's window, an action's shortcut beats a command's hotkey with the same keys.

private func entry(_ id: Int, _ title: String, _ shortcut: KeyShortcut? = nil) -> ActionEntry {
    ActionEntry(
        id: id, title: title, icon: nil, shortcut: shortcut, destructive: false, submenu: nil, isLoading: false,
        target: .node(id))
}

private func sections(_ entries: ActionEntry...) -> [ActionSection] {
    [ActionSection(title: nil, entries: entries)]
}

private let cmdD = KeyShortcut(key: "d", modifiers: ["cmd"])
private let showDetails = entry(2, "Show Details", cmdD)
/// A List item's actions: ↵ Open, ⌘↵ Copy, and Show Details on ⌘D.
private let listActions = sections(entry(1, "Open"), entry(3, "Copy"), showDetails)
private let inList = LauncherKeys.State.Place.command(hasSearchField: true, isForm: false)

/// The US layout's characters for the keys these tests press.
private func usLayout(_ keyCode: UInt16) -> String? {
    [0: "a", 2: "d", 3: "f", 14: "e", 12: "q", 40: "k", 43: ",", 41: ";", 36: "\r"][keyCode]
}

private func hotkey(_ text: String) -> HotKeySpec {
    HotKeySpec.parse(text)!
}

/// What a command hotkey does in `state`, on the US layout: the key press it makes in the launcher, or nil when it
/// opens its command.
private func press(
    _ text: String, in state: LauncherKeys.State, holdsKeyboard: Bool = true,
    layout: @escaping (UInt16) -> String? = usLayout
) -> KeyShortcut? {
    LauncherKeys.hotkeyPress(hotkey(text), layout: layout, launcherHoldsKeyboard: holdsKeyboard, in: state)
}

@Test func aHotkeyRunsTheViewsActionWithItsKeys() {
    let state = LauncherKeys.State(place: inList, actions: listActions)
    #expect(press("cmd+d", in: state) == cmdD)
    #expect(LauncherKeys.outcome(of: cmdD, in: state) == .run(showDetails))
}

@Test func aHotkeyWithNoActionOnItsKeysOpensItsCommand() {
    let state = LauncherKeys.State(place: inList, actions: sections(entry(1, "Open"), entry(3, "Copy")))
    #expect(press("cmd+d", in: state) == nil)
    #expect(press("ctrl+option+d", in: LauncherKeys.State(place: inList, actions: listActions)) == nil)
}

@Test func outsideTheLauncherAHotkeyOpensItsCommand() {
    // Hidden, Settings key, or another app in front: whatever the last view had, the command opens, and the keyboard
    // layout isn't even read.
    var layoutRead = false
    let state = LauncherKeys.State(place: inList, actions: listActions)
    let pressed = press("cmd+d", in: state, holdsKeyboard: false) { code in
        layoutRead = true
        return usLayout(code)
    }
    #expect(pressed == nil)
    #expect(!layoutRead)
    let panelOpen = LauncherKeys.State(place: inList, overlay: .actionPanel, actions: listActions)
    #expect(press("cmd+d", in: panelOpen, holdsKeyboard: false) == nil)
}

@Test func modifiersStayDistinct() {
    let shifted = sections(
        entry(1, "Open"), entry(2, "Show Details", KeyShortcut(key: "d", modifiers: ["cmd", "shift"])))
    let state = LauncherKeys.State(place: inList, actions: shifted)
    #expect(press("cmd+d", in: state) == nil, "an action on ⌘⇧D doesn't take a ⌘D hotkey")
    #expect(press("option+d", in: state) == nil)
    #expect(press("cmd+shift+d", in: state) == KeyShortcut(key: "d", modifiers: ["cmd", "shift"]))
}

// §0: shortcuts work with the action panel open.

@Test func withTheActionPanelOpenAShortcutRunsTheViewsAction() {
    // The key monitor sees the key before "Search for actions…" does, so this holds with that field focused too.
    let state = LauncherKeys.State(place: inList, overlay: .actionPanel, actions: listActions)
    #expect(LauncherKeys.outcome(of: cmdD, in: state) == .run(showDetails))
    #expect(LauncherKeys.outcome(of: KeyShortcut(key: "d", modifiers: []), in: state) == nil, "plain letters filter")
    #expect(LauncherKeys.outcome(of: KeyShortcut(key: "d", modifiers: ["cmd", "shift"]), in: state) == nil)
}

@Test func withTheActionPanelOpenASubmenusActionRuns() {
    let openWith = KeyShortcut(key: "o", modifiers: ["cmd"])
    let inSubmenu = entry(7, "Preview", KeyShortcut(key: "p", modifiers: ["cmd", "shift"]))
    var submenu = entry(6, "Open With…", openWith)
    submenu.submenu = sections(inSubmenu)
    let state = LauncherKeys.State(
        place: inList, overlay: .actionPanel, actions: sections(entry(1, "Open"), submenu))
    #expect(LauncherKeys.outcome(of: openWith, in: state) == .run(submenu))
    #expect(LauncherKeys.outcome(of: KeyShortcut(key: "p", modifiers: ["cmd", "shift"]), in: state) == .run(inSubmenu))
}

@Test func otherOverlaysRunNoAction() {
    for overlay in [LauncherKeys.State.Overlay.dropdown, .datePick, .signIn] {
        let state = LauncherKeys.State(place: inList, overlay: overlay, actions: listActions)
        #expect(LauncherKeys.outcome(of: cmdD, in: state) == nil, "\(overlay)")
        #expect(press("cmd+d", in: state) == nil, "\(overlay): the hotkey opens its command")
    }
}

@Test func withTheActionPanelOpenAHotkeyRunsTheViewsAction() {
    let state = LauncherKeys.State(place: inList, overlay: .actionPanel, actions: listActions)
    #expect(press("cmd+d", in: state) == cmdD)
}

@Test func theArchitectsCase() throws {
    // The Extension Store's detail, ⌘K open, and DuckDuckGo Search's hotkey on ⌘D (board #5283): ⌘D is Show Details.
    let panel = try JSONDecoder().decode(
        UINode.self,
        from: Data(
            #"""
            {"id":40,"type":"ActionPanel","props":{},"children":[
              {"id":41,"type":"Action","props":{"title":"Install","onAction":{"$fn":["onAction"]}},"children":[]},
              {"id":42,"type":"Action","props":{"title":"Open in Browser","onAction":{"$fn":["onAction"]}},"children":[]},
              {"id":43,"type":"Action","props":{"title":"Show Details","shortcut":{"modifiers":["cmd"],"key":"d"},
                "onAction":{"$fn":["onAction"]}},"children":[]}
            ]}
            """#.utf8))
    let actions = ActionPanelReader.sections(of: panel)
    let state = LauncherKeys.State(place: inList, overlay: .actionPanel, actions: actions)
    let pressed = try #require(press("cmd+d", in: state))
    guard case .run(let action) = LauncherKeys.outcome(of: pressed, in: state) else {
        Issue.record("⌘D runs no action")
        return
    }
    #expect(action.title == "Show Details")
    #expect(action.target == .node(43))
}

// Which keys are actions' keys (§1).

@Test func fudgesOwnKeysArentActions() {
    let onK = sections(entry(1, "Open"), entry(2, "Odd", LauncherKeys.actionPanelKey))
    #expect(press("cmd+k", in: LauncherKeys.State(place: inList, actions: onK)) == nil, "⌘K is Fudge's own")
    #expect(press("cmd+,", in: LauncherKeys.State(place: inList, actions: listActions)) == nil, "⌘, opens Settings")
    #expect(press("cmd+shift+,", in: LauncherKeys.State(place: .root, actions: [])) == nil)
    // An extension's own action on ⌘, wins over Settings inside its command, so it wins over a hotkey too.
    let onComma = sections(entry(1, "Open"), entry(2, "Preferences", KeyShortcut(key: ",", modifiers: ["cmd"])))
    #expect(press("cmd+,", in: LauncherKeys.State(place: inList, actions: onComma)) != nil)
}

@Test func thePrimaryAndSecondaryKeysAreActionsKeys() {
    let state = LauncherKeys.State(place: inList, actions: listActions)
    #expect(press("cmd+return", in: state) == KeyShortcut(key: "return", modifiers: ["cmd"]))
    #expect(
        LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: ["cmd"]), in: state)
            == .run(listActions[0].entries[1]))
    // With no secondary action, ⌘↵ runs nothing, so the hotkey opens its command.
    #expect(press("cmd+return", in: LauncherKeys.State(place: inList, actions: sections(entry(1, "Open")))) == nil)
    // A Form: ⌘↵ submits (the primary action), ⌘⇧↵ is the secondary.
    let form = LauncherKeys.State(place: .command(hasSearchField: false, isForm: true), actions: listActions)
    #expect(
        LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: ["cmd"]), in: form)
            == .run(listActions[0].entries[0]))
    #expect(
        LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: ["cmd", "shift"]), in: form)
            == .run(listActions[0].entries[1]))
    // A Detail: ↵ is the primary action's.
    let detail = LauncherKeys.State(place: .command(hasSearchField: false, isForm: false), actions: listActions)
    #expect(
        LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: []), in: detail)
            == .run(listActions[0].entries[0]))
    #expect(LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: []), in: state) == nil, "the field's ↵")
}

@Test func aKeyWaitsForTheSelectedItemsActions() {
    // The item's actions haven't come, but the host named ⌘D among their shortcuts: ⌘D waits for them.
    let state = LauncherKeys.State(place: inList, actions: [], pendingShortcuts: [cmdD])
    #expect(LauncherKeys.outcome(of: cmdD, in: state) == .wait(.shortcut(cmdD)))
    #expect(LauncherKeys.outcome(of: KeyShortcut(key: "return", modifiers: ["cmd"]), in: state) == .wait(.secondary))
    #expect(press("cmd+d", in: state) == cmdD)
    #expect(press("cmd+e", in: state) == nil)
}

@Test func rootSearchAndNoticesHaveTheirActions() {
    let app = RootItem.application(at: URL(fileURLWithPath: "/Applications/Notes.app"), title: "Notes")
    let root = LauncherKeys.State(place: .root, actions: RootActions.sections(for: app))
    #expect(press("cmd+shift+f", in: root) == RootActions.showInFinderShortcut)
    #expect(press("cmd+d", in: root) == nil)
    let failed = LauncherKeys.State(place: .failedCommand, actions: listActions)
    #expect(press("cmd+d", in: failed) == nil)
}

// The MUST: a hotkey's key is named through the current keyboard layout, as a key press is.

@Test func aHotkeysKeyFollowsTheKeyboardLayout() {
    // AZERTY: key code 0, "a" on US keyboards, types "q"; the key at US's "," types ";".
    let azerty: (UInt16) -> String? = { [0: "q", 12: "a", 43: ";", 41: "m"][$0] }
    let actions = sections(
        entry(1, "Open"), entry(2, "Quit Thing", KeyShortcut(key: "q", modifiers: ["cmd"])),
        entry(3, "All Things", KeyShortcut(key: "a", modifiers: ["cmd"])),
        entry(4, "Semicolon", KeyShortcut(key: ";", modifiers: ["cmd"])),
        entry(5, "Comma", KeyShortcut(key: ",", modifiers: ["cmd"])))
    let state = LauncherKeys.State(place: inList, actions: actions)
    // `cmd+a` is saved as key code 0.
    #expect(press("cmd+a", in: state, layout: azerty) == KeyShortcut(key: "q", modifiers: ["cmd"]))
    #expect(press("cmd+a", in: state, layout: usLayout) == KeyShortcut(key: "a", modifiers: ["cmd"]))
    // `cmd+,` is saved as key code 43.
    #expect(press("cmd+,", in: state, layout: azerty) == KeyShortcut(key: ";", modifiers: ["cmd"]))
    #expect(press("cmd+,", in: state, layout: usLayout) == KeyShortcut(key: ",", modifiers: ["cmd"]))
}

@Test func aHotkeyIsNamedAsAKeyPressIs() {
    let layout: (UInt16) -> String? = { [0: "Q", 2: "d", 43: ";"][$0] }
    for (text, code) in [("cmd+shift+a", UInt16(0)), ("ctrl+option+d", 2), ("cmd+,", 43)] {
        let spec = hotkey(text)
        var modifiers: Set<String> = []
        if spec.command { modifiers.insert("cmd") }
        if spec.control { modifiers.insert("ctrl") }
        if spec.option { modifiers.insert("opt") }
        if spec.shift { modifiers.insert("shift") }
        #expect(
            KeyShortcut(hotkey: spec, layout: layout)
                == KeyShortcut(keyCode: code, characters: layout(code), modifiers: modifiers), "\(text)")
    }
    // Special keys go by their code, whatever the layout says.
    #expect(
        KeyShortcut(hotkey: hotkey("cmd+return"), layout: { _ in "x" })
            == KeyShortcut(key: "return", modifiers: ["cmd"]))
    #expect(
        KeyShortcut(hotkey: hotkey("option+space"), layout: { _ in nil })
            == KeyShortcut(key: "space", modifiers: ["opt"]))
    // A key the layout types nothing for is no key press, so no action takes it.
    #expect(KeyShortcut(hotkey: hotkey("cmd+d"), layout: { _ in nil }) == nil)
}

// Tab and ⇧Tab move between a Form's fields through the launcher; ⌥Tab goes to the field (FUD-185).

@Test func tabAndShiftTabAreAFormsMovesAndOptionTabIsTheFields() {
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: [])) == false)
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: ["shift"])) == true)
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: ["opt"])) == nil, "a text area types a tab")
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: ["opt", "shift"])) == nil)
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: ["ctrl"])) == nil)
    #expect(LauncherKeys.formTab(KeyShortcut(key: "tab", modifiers: ["cmd"])) == nil)
    #expect(LauncherKeys.formTab(KeyShortcut(key: "return", modifiers: [])) == nil)
    #expect(
        LauncherKeys.formTab(KeyShortcut(keyCode: 48, characters: "\t", modifiers: ["shift"])!) == true, "as pressed")
}

private let tab = KeyShortcut(key: "tab", modifiers: [])
private let shiftTab = KeyShortcut(key: "tab", modifiers: ["shift"])
private let inForm = LauncherKeys.State.Place.command(hasSearchField: false, isForm: true)

@Test func inAFormTabAndShiftTabMoveBetweenFieldsBeforeAnyActionsShortcut() {
    // An action on ⇧Tab: a bare key never runs an action (plain keys are typing), so ⇧Tab is the one to try.
    let actions = sections(entry(1, "Submit"), entry(2, "Previous Page", shiftTab), entry(3, "Bare Tab", tab))
    let form = LauncherKeys.State(place: inForm, actions: actions)
    #expect(LauncherKeys.outcome(of: tab, in: form) == .moveInForm(backwards: false))
    #expect(LauncherKeys.outcome(of: shiftTab, in: form) == .moveInForm(backwards: true), "not Previous Page")
    #expect(
        LauncherKeys.outcome(of: KeyShortcut(key: "tab", modifiers: ["opt"]), in: form) == nil,
        "⌥Tab goes to the field")
    let list = LauncherKeys.State(place: inList, actions: actions)
    #expect(
        LauncherKeys.outcome(of: shiftTab, in: list) == .run(entry(2, "Previous Page", shiftTab)),
        "outside a Form, the action's ⇧Tab still runs it")
    #expect(LauncherKeys.outcome(of: tab, in: list) == nil, "and a bare Tab is typing")
    let detail = LauncherKeys.State(place: .command(hasSearchField: false, isForm: false), actions: actions)
    #expect(LauncherKeys.outcome(of: tab, in: detail) == nil, "a Detail has no fields to move between")
}

@Test func anOpenOverlayKeepsItsOwnTabInAForm() {
    let actions = sections(entry(1, "Submit"), entry(2, "Previous Page", shiftTab))
    for overlay in [LauncherKeys.State.Overlay.actionPanel, .datePick, .dropdown, .signIn] {
        let state = LauncherKeys.State(place: inForm, overlay: overlay, actions: actions)
        #expect(LauncherKeys.outcome(of: tab, in: state) == nil, "\(overlay)")
        #expect(LauncherKeys.outcome(of: shiftTab, in: state) != .moveInForm(backwards: true), "\(overlay)")
    }
}
