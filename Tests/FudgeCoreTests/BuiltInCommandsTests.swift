import Foundation
import Testing

@testable import FudgeCore

/// A group only these tests know, since `BuiltInCommandGroup.all` is Fudge's real list.
private let tools = BuiltInCommandGroup(
    name: ":test-tools", title: "Test Tools",
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
        #expect(BuiltInCommandGroup.isValidName(group.name), "\(group.name)")
        #expect(Set(group.commands.map(\.name)).count == group.commands.count, "command names are unique")
    }
    #expect(Set(BuiltInCommandGroup.all.map(\.name)).count == BuiltInCommandGroup.all.count)
}

@Test func aLookAlikeExtensionCantTakeAGroupsKeys() {
    #expect(tools.commandID(tools.commands[0]) == ":test-tools/first")
    #expect(FudgeSettings.commandID(extension: "test-tools", command: "first") == "test-tools/first")
    var settings = FudgeSettings()
    settings.commands["test-tools/first"] = .init(hotkey: "option+l", alias: "tf", enabled: false)
    settings.extensions["test-tools"] = .init(enabled: false)
    #expect(settings.isEnabled(commandID: ":test-tools/first"), "the extension's Enabled isn't the group's")
    #expect(settings.isEnabled(extension: ":test-tools"))
    let items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.count == 2 && items.allSatisfy { $0.alias == nil })
    let available = settings.availableHotkeys(installed: Set(BuiltInCommandGroup.commandIDs(in: [tools])))
    #expect(available.isEmpty, "the extension's hotkey isn't the group command's")
}

@Test func aGroupsCommandsAreRootItems() {
    let items = RootItem.builtInCommands(of: tools)
    #expect(items.map(\.id) == ["command::test-tools/first", "command::test-tools/second"])
    #expect(items.map(\.title) == ["First Tool", "Second Tool"])
    #expect(items.allSatisfy { $0.subtitle == "Test Tools" && $0.extensionTitle == "Test Tools" })
    #expect(items[0].keywords == ["alpha"])
    #expect(items[0].kind == .builtInCommand(group: ":test-tools", command: "first"))
    #expect(items[0].commandSettingsID == ":test-tools/first")
    #expect(items[0].recordsLaunch)
    #expect(RootItem.settings.commandSettingsID == nil)
    #expect(
        BuiltInCommandGroup.command(group: ":test-tools", command: "second", in: [tools])?.command.symbol == "2.circle")
    #expect(BuiltInCommandGroup.command(group: ":test-tools", command: "third", in: [tools]) == nil)
    #expect(RootActions.sections(for: items[0]).flatMap(\.entries).map(\.title) == ["Open Command"])
}

@Test func aliasesAndEnabledApplyToAGroupsCommands() {
    var settings = FudgeSettings()
    settings.commands[":test-tools/first"] = .init(alias: "ft")
    settings.commands[":test-tools/second"] = .init(enabled: false)
    var items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.map(\.title) == ["First Tool"])
    #expect(items[0].alias == "ft")
    #expect(RootSearch.exactAliasMatch(in: items, query: "FT")?.title == "First Tool")
    #expect(RootSearch.rank(items, query: "alpha", history: LaunchHistory()).map(\.title) == ["First Tool"])

    settings.setEnabled(false, extension: ":test-tools")
    items = RootSearch.applying(settings, to: RootItem.builtInCommands(of: tools))
    #expect(items.isEmpty, "turning the group off leaves out all its commands")
}

@Test func aGroupsHotkeysAreRegisteredAndConflictLikeAnExtensionCommands() {
    var settings = FudgeSettings()
    settings.commands[":test-tools/first"] = .init(hotkey: "option+l")
    let installed = Set(BuiltInCommandGroup.commandIDs(in: [tools]))
    #expect(settings.availableHotkeys(installed: installed) == [":test-tools/first": optionL])
    #expect(
        HotKeyConflict.check(
            optionL, for: "vscode/search", launcher: launcher, commands: settings.commandHotkeys, installed: installed)
            == .command(":test-tools/first"))
    settings.setEnabled(false, extension: ":test-tools")
    #expect(settings.availableHotkeys(installed: installed).isEmpty, "a turned-off group's hotkeys aren't registered")
}

@Test func messagesNameAGroupsCommandByItsTitle() throws {
    #expect(CommandNames.name(of: ":test-tools/first", in: [], groups: [tools]) == "First Tool")
    #expect(CommandNames.name(of: ":test-tools/third", in: [], groups: [tools]) == nil)
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manifest = """
        { "name": "other", "title": "Other", "commands": [{ "name": "first", "title": "First Tool", "mode": "view" }] }
        """
    try manifest.write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let other = InstalledExtension(
        manifest: try ExtensionManifest.load(from: folder.appendingPathComponent("package.json")), directory: folder)
    #expect(CommandNames.name(of: ":test-tools/first", in: [other], groups: [tools]) == "First Tool (Test Tools)")
    #expect(CommandNames.name(of: "other/first", in: [other], groups: [tools]) == "First Tool (Other)")
}
