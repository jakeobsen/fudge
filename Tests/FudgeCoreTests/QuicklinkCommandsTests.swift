import Foundation
import Testing

@testable import FudgeCore

private let optionJ = HotKeySpec.parse("option+j")!
private let launcher = HotKeySpec.parse("option+space")!

/// A real quicklink id, as Fudge makes them: `UUID().uuidString`, upper case.
private let jiraID = UUID().uuidString
private let jira = Quicklink(
    id: jiraID, name: "Jira Issue", link: "https://jira.example.com/browse/{argument name=\"key\"}")
private let docs = Quicklink(id: UUID().uuidString, name: "Docs", link: "https://docs.example.com")
private let search = Quicklink(
    id: UUID().uuidString, name: "Search Wiki",
    link: "https://wiki.example.com/?q={argument name=\"q\" default=\"home\"}")

private func items(_ quicklinks: [Quicklink], _ settings: FudgeSettings) -> [RootItem] {
    RootSearch.applying(settings, to: quicklinks.map(RootItem.quicklink))
}

@Test func aQuicklinksKeyIsItsIDUnderAGroupNoExtensionCanHave() {
    #expect(jiraID != jiraID.lowercased(), "a real id is upper case")
    #expect(QuicklinkCommands.commandID(ofQuicklink: jiraID) == ":quicklinks/\(jiraID)")
    #expect(BuiltInCommandGroup.isValidName(QuicklinkCommands.groupName))
    #expect(!ExtensionManifest.isValidName(QuicklinkCommands.groupName))
    #expect(QuicklinkCommands.quicklinkID(inCommandID: ":quicklinks/\(jiraID)") == jiraID)
    #expect(RootItem.quicklink(jira).commandSettingsID == ":quicklinks/\(jiraID)")
    #expect(RootItem.id(forCommandSettingsID: ":quicklinks/\(jiraID)") == jira.rootItemID)
    #expect(RootItem.id(forCommandSettingsID: "scratch/create") == "command:scratch/create")
    #expect(RootItem.id(forCommandSettingsID: ":window-management/left-half") == "command::window-management/left-half")
    // An extension called "quicklinks" has keys of its own.
    #expect(QuicklinkCommands.quicklinkID(inCommandID: "quicklinks/\(jiraID)") == nil)
}

@Test func anIDThatCantBeAKeyGetsNoSettingsAndBreaksNothing() {
    for id in ["a/b", "", "with space", "é", String(repeating: "a", count: 65), "../x"] {
        #expect(!QuicklinkCommands.isValidID(id), "\(id)")
        #expect(QuicklinkCommands.commandID(ofQuicklink: id) == nil, "\(id)")
    }
    for id in ["a", "A-1_b", jiraID, jiraID.lowercased(), String(repeating: "a", count: 64)] {
        #expect(QuicklinkCommands.isValidID(id), "\(id)")
    }
    // A hand-edited quicklinks.json id with a "/" is still a quicklink, but has no key.
    let odd = Quicklink(id: "a/b", name: "Odd", link: "https://example.com")
    #expect(RootItem.quicklink(odd).commandSettingsID == nil)
    #expect(QuicklinkCommands.quicklinkID(inCommandID: ":quicklinks/a/b") == nil)
    #expect(RootItem.id(forCommandSettingsID: ":quicklinks/a/b") == "command::quicklinks/a/b", "no quicklink's item")
    var settings = FudgeSettings()
    settings.commands[":quicklinks/a/b"] = .init(hotkey: "option+j", alias: "odd", enabled: false)
    let shown = items([odd], settings)
    #expect(shown.map(\.title) == ["Odd"], "its settings neither hide it nor alias it")
    #expect(shown[0].alias == nil)
    #expect(QuicklinkCommands.commandIDs([odd, jira]) == [":quicklinks/\(jiraID)"])
    #expect(QuicklinkCommands.group([odd, jira]).commands.map(\.name) == [jiraID])
    #expect(settings.availableHotkeys(installed: Set(QuicklinkCommands.commandIDs([odd]))).isEmpty)
}

@Test func theGroupListsEveryQuicklinkByName() {
    let group = QuicklinkCommands.group([search, jira, docs])
    #expect(group.name == ":quicklinks")
    #expect(group.title == "Quicklinks")
    #expect(group.commands.map(\.title) == ["Docs", "Jira Issue", "Search Wiki"])
    #expect(group.commands.map(\.name) == [docs.id, jiraID, search.id])
    #expect(group.commands.allSatisfy { $0.symbol == "link" })
    #expect(group.commandID(group.commands[1]) == ":quicklinks/\(jiraID)")
    #expect(QuicklinkCommands.group([]).commands.isEmpty)
    #expect(
        Set(QuicklinkCommands.commandIDs([search, jira, docs]))
            == Set(BuiltInCommandGroup.commandIDs(in: [group])))
}

@Test func aRealIDsAliasAndHotkeySurviveSavingAndReading() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    var settings = FudgeSettings()
    let key = try #require(QuicklinkCommands.commandID(ofQuicklink: jiraID))
    settings.commands[key] = .init(hotkey: optionJ.text, alias: "jira")
    try settings.save(to: file)
    let read = FudgeSettings.load(from: file)
    #expect(read.commands[key]?.alias == "jira")
    #expect(read.commandHotkeys[key] == optionJ)
    #expect(read.availableHotkeys(installed: Set(QuicklinkCommands.commandIDs([jira]))) == [key: optionJ])
    try read.save(to: file)
    #expect(FudgeSettings.load(from: file) == read, "saving again changes nothing")
}

@Test func aRenameKeepsTheAliasAndHotkey() {
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(jiraID)"] = .init(hotkey: optionJ.text, alias: "jira")
    var renamed = jira
    renamed.name = "Jira Ticket"
    renamed.link = "https://jira.example.com/browse/{argument name=\"ticket\"}"
    let shown = items([renamed], settings)
    #expect(shown.map(\.title) == ["Jira Ticket"])
    #expect(shown[0].alias == "jira")
    #expect(settings.availableHotkeys(installed: Set(QuicklinkCommands.commandIDs([renamed]))).count == 1)
    #expect(QuicklinkCommands.group([renamed]).commands.map(\.title) == ["Jira Ticket"])
}

@Test func anAliasRanksFirstAndHandsTheRestToTheFirstField() {
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(jiraID)"] = .init(alias: "jira")
    settings.commands[":quicklinks/\(docs.id)"] = .init(alias: "d")
    let shown = items([docs, jira, search], settings)
    let ranked = RootSearch.rank(shown, query: "jira", history: LaunchHistory())
    #expect(ranked.first?.id == jira.rootItemID)
    #expect(RootSearch.rows(ranked, query: "JIRA", hasCalculator: true).first == .item(shown[1]))
    #expect(RootSearch.rank(shown, query: "ji", history: LaunchHistory()).first?.id == jira.rootItemID)
    let handOff = CommandAliases.handOff("jira FUD-129", in: shown)
    #expect(handOff?.item.id == jira.rootItemID)
    #expect(handOff?.rest == "FUD-129")
    #expect(handOff?.item.arguments.first?.name == "key", "the rest goes into the first field")
    #expect(CommandAliases.handOff("d text", in: shown) == nil, "a quicklink without fields takes no hand-off")
    // Aliases are unique across commands and quicklinks.
    settings.commands["scratch/create"] = .init(alias: "sc")
    #expect(
        CommandAliases.problem(with: "JIRA", for: "scratch/create", in: settings)
            == .duplicate(":quicklinks/\(jiraID)"))
    #expect(
        CommandAliases.problem(with: "sc", for: ":quicklinks/\(jiraID)", in: settings) == .duplicate("scratch/create"))
}

@Test func aHotkeyOpensAtOnceUnlessARequiredFieldIsEmpty() {
    #expect(QuicklinkCommands.hotkeyLaunch(docs) == .open, "no fields")
    #expect(QuicklinkCommands.hotkeyLaunch(search) == .open, "every field has a default")
    #expect(QuicklinkCommands.hotkeyLaunch(jira) == .askForArguments, "a field with no default")
    let pick = Quicklink(name: "Pick", link: "https://example.com/{argument name=\"env\" options=\"dev, prod\"}")
    #expect(QuicklinkCommands.hotkeyLaunch(pick) == .askForArguments, "a dropdown with no default")
    let pickWithDefault = Quicklink(
        name: "Pick", link: "https://example.com/{argument name=\"env\" options=\"dev, prod\" default=\"dev\"}")
    #expect(QuicklinkCommands.hotkeyLaunch(pickWithDefault) == .open)
    let broken = Quicklink(name: "Broken", link: "https://example.com/{selection}")
    #expect(QuicklinkCommands.hotkeyLaunch(broken) == .open, "opening shows the problem, as ↵ does")
}

@Test func aHotkeyFillsTheDynamicValuesFromThePress() throws {
    let link = Quicklink(
        name: "Look Up",
        link: "https://example.com/?q={clipboard}&id={uuid}&page={argument name=\"page\" default=\"1\"}")
    #expect(QuicklinkCommands.hotkeyLaunch(link) == .open)
    let pressed = QuicklinkTemplate.Context(clipboard: "copied at the press", makeUUID: { "fixed-uuid" })
    let target = try QuicklinkOpening.target(for: link, context: pressed).get()
    #expect(target == .url(URL(string: "https://example.com/?q=copied%20at%20the%20press&id=fixed-uuid&page=1")!))
    let empty = try QuicklinkOpening.target(for: link, context: .init(clipboard: nil, makeUUID: { "u" })).get()
    #expect(empty.openText == "https://example.com/?q=&id=u&page=1", "no clipboard text is an empty value")
    let typed = try QuicklinkOpening.target(for: search, arguments: ["q": "fudge"], context: .init(clipboard: nil))
        .get()
    #expect(typed.openText == "https://wiki.example.com/?q=fudge")
    let broken = Quicklink(name: "Broken", link: "https://example.com/{selection}")
    guard case .failure = QuicklinkOpening.target(for: broken, context: .init(clipboard: nil)) else {
        Issue.record("a quicklink with a problem doesn't open")
        return
    }
}

@Test func aQuicklinksHotkeyConflictsAndIsNamedByItsName() {
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(jiraID)"] = .init(hotkey: optionJ.text)
    let installed = Set(QuicklinkCommands.commandIDs([jira, docs]))
    #expect(
        HotKeyConflict.check(
            optionJ, for: ":quicklinks/\(docs.id)", launcher: launcher, commands: settings.commandHotkeys,
            installed: installed) == .command(":quicklinks/\(jiraID)"))
    #expect(
        HotKeyConflict.check(
            optionJ, for: "scratch/create", launcher: launcher, commands: settings.commandHotkeys,
            installed: installed.union(["scratch/create"])) == .command(":quicklinks/\(jiraID)"))
    #expect(
        HotKeyConflict.check(launcher: optionJ, commands: settings.commandHotkeys, installed: installed)
            == .command(":quicklinks/\(jiraID)"))
    #expect(
        HotKeyConflict.check(launcher, for: ":quicklinks/\(jiraID)", launcher: launcher, commands: [:]) == .launcher)
    let groups = [QuicklinkCommands.group([jira, docs])]
    #expect(CommandNames.name(of: ":quicklinks/\(jiraID)", in: [], groups: groups) == "Jira Issue")
    let twin = Quicklink(name: "First Tool", link: "https://example.com")
    let tools = BuiltInCommandGroup(
        name: ":test-tools", title: "Test Tools",
        commands: [BuiltInCommand(name: "first", title: "First Tool", symbol: "1.circle")])
    #expect(
        CommandNames.name(of: ":quicklinks/\(twin.id)", in: [], groups: [tools, QuicklinkCommands.group([twin])])
            == "First Tool (Quicklinks)")
    // A deleted quicklink's saved hotkey gives way, as an uninstalled command's does.
    #expect(
        HotKeyConflict.check(
            optionJ, for: "scratch/create", launcher: launcher, commands: settings.commandHotkeys,
            installed: Set(QuicklinkCommands.commandIDs([docs]))) == nil)
}

@Test func aDisabledQuicklinkLeavesRootSearchAndItsHotkeyGoes() {
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(jiraID)"] = .init(hotkey: optionJ.text, enabled: false)
    settings.commands[":quicklinks/\(docs.id)"] = .init(hotkey: "option+d")
    let installed = Set(QuicklinkCommands.commandIDs([jira, docs]))
    #expect(items([jira, docs], settings).map(\.title) == ["Docs"])
    #expect(Array(settings.availableHotkeys(installed: installed).keys) == [":quicklinks/\(docs.id)"])

    settings.setEnabled(false, extension: QuicklinkCommands.groupName)
    #expect(items([jira, docs], settings).isEmpty, "the group's Enabled turns every quicklink off")
    #expect(settings.availableHotkeys(installed: installed).isEmpty)
    settings.setEnabled(true, extension: QuicklinkCommands.groupName)
    #expect(settings.extensions[QuicklinkCommands.groupName]?.enabled == nil, "on is the default")
}

@Test func deletedQuicklinksSettingsArePruned() {
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(jiraID)"] = .init(alias: "jira")
    settings.commands[":quicklinks/\(docs.id)"] = .init(hotkey: "option+d")
    settings.commands[":quicklinks/a/b"] = .init(alias: "odd")
    settings.commands["scratch/create"] = .init(alias: "sc")
    settings.commands[":window-management/left-half"] = .init(alias: "lh")
    settings.extensions[QuicklinkCommands.groupName] = .init(enabled: false)
    #expect(QuicklinkCommands.prune(&settings, keeping: [docs]))
    #expect(
        Set(settings.commands.keys) == [":quicklinks/\(docs.id)", "scratch/create", ":window-management/left-half"])
    #expect(settings.extensions[QuicklinkCommands.groupName]?.enabled == false, "the group's Enabled stays")
    #expect(!QuicklinkCommands.prune(&settings, keeping: [docs]), "nothing left to take out")
}

@Test func aQuicklinkStillInTheFileKeepsItsSettingsEvenWhenItIsNotValid() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fudge-quicklinks-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    // A hand edit broke the second one (no link), and the third was removed by hand.
    let broken = UUID().uuidString
    let removed = UUID().uuidString
    try """
    {"quicklinks":[{"id":"\(docs.id)","name":"Docs","link":"https://docs.example.com"},{"id":"\(broken)","name":"Broken"}]}
    """.write(to: file, atomically: true, encoding: .utf8)
    let store = QuicklinkStore.load(from: file)
    #expect(store.quicklinks.map(\.id) == [docs.id])
    #expect(store.entryIDs == [docs.id, broken], "every entry's id, valid or not")
    var settings = FudgeSettings()
    settings.commands[":quicklinks/\(docs.id)"] = .init(alias: "docs")
    settings.commands[":quicklinks/\(broken)"] = .init(hotkey: "option+b")
    settings.commands[":quicklinks/\(removed)"] = .init(alias: "gone")
    #expect(QuicklinkCommands.prune(&settings, in: store))
    #expect(
        Set(settings.commands.keys) == [":quicklinks/\(docs.id)", ":quicklinks/\(broken)"],
        "only the removed one's settings go; fixing the broken one brings its hotkey back")
}

@Test func aGoneQuicklinkIsNamedAsDeleted() {
    #expect(QuicklinkCommands.nameWhenGone(":quicklinks/\(UUID().uuidString)") == "a deleted quicklink")
    #expect(QuicklinkCommands.nameWhenGone("scratch/create") == nil)
    #expect(QuicklinkCommands.nameWhenGone(":window-management/left-half") == nil)
}

@Test func theQuicklinksGroupIsTypedQuicklinksOnTheCommandsPage() {
    #expect(BuiltInCommandGroup.typeLabels(ofGroup: QuicklinkCommands.groupName) == ("Quicklinks", "Quicklink"))
    for group in BuiltInCommandGroup.all {
        #expect(BuiltInCommandGroup.typeLabels(ofGroup: group.name) == ("Built-in", "Command"))
    }
}

@Test func aQuicklinksAliasAndHotkeySurviveABackupRoundTrip() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fudge-backup-\(UUID().uuidString)", isDirectory: true)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fudge-backup-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: target)
    }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let paths = FudgePaths(supportDirectory: source)
    try QuicklinkStore([jira]).save(to: paths.quicklinksFile)
    var settings = FudgeSettings()
    let key = try #require(QuicklinkCommands.commandID(ofQuicklink: jiraID))
    settings.commands[key] = .init(hotkey: optionJ.text, alias: "jira")
    try settings.save(to: paths.settingsFile)

    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let file = source.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write(
        Backup.collect(from: paths, installed: [], fudgeVersion: "1.0", now: now).entries, to: file,
        password: "correct horse")
    let restored = FudgePaths(supportDirectory: target)
    _ = try Backup.apply(
        try Backup.open(file, password: "correct horse"), to: restored, installed: [], fudgeVersion: "1.0", now: now)

    let quicklinks = QuicklinkStore.load(from: restored.quicklinksFile).quicklinks
    #expect(quicklinks.map(\.id) == [jiraID])
    let read = FudgeSettings.load(from: restored.settingsFile)
    #expect(read.commands[key]?.alias == "jira")
    #expect(read.availableHotkeys(installed: Set(QuicklinkCommands.commandIDs(quicklinks))) == [key: optionJ])
    #expect(items(quicklinks, read).first?.alias == "jira")
}
