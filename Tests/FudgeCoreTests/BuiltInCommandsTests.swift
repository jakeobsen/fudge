import Foundation
import Testing

@testable import FudgeCore

/// A group only these tests know, since `BuiltInCommandGroup.all` is Fudge's real list. Its key is the Tools group's,
/// since a group's key is one of a closed list (`BuiltInGroup`), and its commands are made up.
private let tools = BuiltInCommandGroup(
    name: .tools, title: "Test Tools",
    commands: [
        BuiltInCommand(name: "first", title: "First Tool", keywords: ["alpha"], symbol: "1.circle"),
        BuiltInCommand(name: "second", title: "Second Tool", symbol: "2.circle"),
    ])

private let optionL = HotKeySpec.parse("option+l")!
private let launcher = HotKeySpec.parse("option+space")!

@Test func aGroupsNameIsOneNoExtensionCanHave() {
    #expect(BuiltInCommandGroup.isValidName(":test-tools"))
    #expect(!ExtensionManifest.isValidName(":test-tools"))
    for name in ["test-tools", ":", ":Test", ":-tools", "::tools", ":a/b"] {
        #expect(!BuiltInCommandGroup.isValidName(name), "\(name)")
    }
    for group in BuiltInCommandGroup.all {
        #expect(BuiltInCommandGroup.isValidName(group.id), "\(group.name)")
        #expect(Set(group.commands.map(\.name)).count == group.commands.count, "command names are unique")
    }
    #expect(Set(BuiltInCommandGroup.all.map(\.name)).count == BuiltInCommandGroup.all.count)
}

@Test func aLookAlikeExtensionCantTakeAGroupsKeys() {
    let lookAlike = ExtensionID(stored: "tools")!
    #expect(tools.commandID(tools.commands[0]) == ":tools/first")
    #expect(FudgeSettings.commandID(owner: .extension(lookAlike), command: "first") == "tools/first")
    var settings = FudgeSettings()
    settings.commands["tools/first"] = .init(hotkey: "option+l", alias: "tf", enabled: false)
    settings.extensions[.extension(lookAlike)] = .init(enabled: false)
    #expect(settings.isEnabled(commandID: ":tools/first"), "the extension's Enabled isn't the group's")
    #expect(settings.isEnabled(owner: .group(.tools)))
    let items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.count == 2 && items.allSatisfy { $0.alias == nil })
    let available = settings.availableHotkeys(installed: Set(BuiltInCommandGroup.commandIDs(in: [tools])))
    #expect(available.isEmpty, "the extension's hotkey isn't the group command's")
}

@Test func aGroupsCommandsAreRootItems() {
    let items = RootItem.builtInCommands(of: tools)
    #expect(items.map(\.id) == ["command::tools/first", "command::tools/second"])
    #expect(items.map(\.title) == ["First Tool", "Second Tool"])
    #expect(items.allSatisfy { $0.subtitle == "Test Tools" && $0.extensionTitle == "Test Tools" })
    #expect(items[0].keywords == ["alpha"])
    #expect(items[0].kind == .builtInCommand(group: .tools, command: "first"))
    #expect(items[0].commandSettingsID == ":tools/first")
    #expect(items[0].recordsLaunch)
    #expect(RootItem.settings.commandSettingsID == nil)
    #expect(
        BuiltInCommandGroup.command(group: .tools, command: "second", in: [tools])?.command.symbol == "2.circle")
    #expect(BuiltInCommandGroup.command(group: .tools, command: "third", in: [tools]) == nil)
    #expect(RootActions.sections(for: items[0]).flatMap(\.entries).map(\.title) == ["Open Command"])
}

@Test func aliasesAndEnabledApplyToAGroupsCommands() {
    var settings = FudgeSettings()
    settings.commands[":tools/first"] = .init(alias: "ft")
    settings.commands[":tools/second"] = .init(enabled: false)
    var items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.map(\.title) == ["First Tool"])
    #expect(items[0].alias == "ft")
    #expect(RootSearch.exactAliasMatch(in: items, query: "FT")?.title == "First Tool")
    #expect(RootSearch.rank(items, query: "alpha", history: LaunchHistory()).map(\.title) == ["First Tool"])

    settings.setEnabled(false, owner: .group(.tools))
    items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.isEmpty, "turning the group off leaves out all its commands")
}

@Test func aGroupsHotkeysAreRegisteredAndConflictLikeAnExtensionCommands() {
    var settings = FudgeSettings()
    settings.commands[":tools/first"] = .init(hotkey: "option+l")
    let installed = Set(BuiltInCommandGroup.commandIDs(in: [tools]))
    #expect(settings.availableHotkeys(installed: installed) == [":tools/first": optionL])
    #expect(
        HotKeyConflict.check(
            optionL, for: "vscode/search", launcher: launcher, commands: settings.commandHotkeys, installed: installed)
            == .command(":tools/first"))
    settings.setEnabled(false, owner: .group(.tools))
    #expect(settings.availableHotkeys(installed: installed).isEmpty, "a turned-off group's hotkeys aren't registered")
}

@Test func messagesNameAGroupsCommandByItsTitle() throws {
    #expect(CommandNames.name(of: ":tools/first", in: [], groups: [tools]) == "First Tool")
    #expect(CommandNames.name(of: ":tools/third", in: [], groups: [tools]) == nil)
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manifest = """
        { "name": "other", "title": "Other", "commands": [{ "name": "first", "title": "First Tool", "mode": "view" }] }
        """
    try manifest.write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let other = InstalledExtension.topLevel(
        manifest: try ExtensionManifest.load(from: folder.appendingPathComponent("package.json")), directory: folder)
    #expect(CommandNames.name(of: ":tools/first", in: [other], groups: [tools]) == "First Tool (Test Tools)")
    #expect(CommandNames.name(of: "other/first", in: [other], groups: [tools]) == "First Tool (Other)")
}
