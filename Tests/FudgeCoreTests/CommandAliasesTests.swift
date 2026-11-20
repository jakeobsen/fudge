import Foundation
import Testing

@testable import FudgeCore

private func command(
    _ extensionName: String, _ name: String, title: String, mode: String = "view", alias: String? = nil,
    arguments: [ExtensionManifest.Argument] = []
) -> RootItem {
    var item = RootItem(
        id: RootItem.commandID(extension: extensionName, command: name), title: title, subtitle: extensionName,
        kind: .command(
            extension: extensionName, command: name, mode: mode,
            entry: URL(fileURLWithPath: "/x/\(extensionName)/\(name).cjs")),
        arguments: arguments)
    item.alias = alias
    return item
}

private let label = ExtensionManifest.Argument(name: "label", type: "text", placeholder: "label", required: false)

@Test func aliasRules() {
    var settings = FudgeSettings()
    settings.commands["scratch/scratch-folders"] = .init(alias: "sf")
    #expect(CommandAliases.problem(with: "", for: "a/b", in: settings) == .length)
    #expect(CommandAliases.problem(with: String(repeating: "x", count: 33), for: "a/b", in: settings) == .length)
    #expect(CommandAliases.problem(with: String(repeating: "x", count: 32), for: "a/b", in: settings) == nil)
    #expect(CommandAliases.problem(with: "s f", for: "a/b", in: settings) == .spaces)
    #expect(CommandAliases.problem(with: "SF", for: "a/b", in: settings) == .duplicate("scratch/scratch-folders"))
    #expect(CommandAliases.problem(with: "sf", for: "scratch/scratch-folders", in: settings) == nil, "its own")
}

@Test func anExactAliasRanksFirstThenAPrefixThenFuzzyMatches() {
    let items = [
        command("finder", "search", title: "Search Files"),
        command("scratch", "scratch-folders", title: "Scratch Folders", alias: "sf"),
        command("vscode", "projects", title: "Search Project Manager", alias: "sfx"),
    ]
    #expect(RootSearch.rank(items, query: "SF", history: LaunchHistory()).map(\.title).first == "Scratch Folders")
    let prefix = RootSearch.rank(items, query: "sfx", history: LaunchHistory()).map(\.title)
    #expect(prefix.first == "Search Project Manager", "exact")
    let typed = RootSearch.rank(items, query: "s", history: LaunchHistory()).map(\.title)
    #expect(Array(typed.prefix(2)) == ["Scratch Folders", "Search Project Manager"], "alias prefixes before fuzzy")
}

@Test func settingsDropDisabledCommandsAndGiveAliases() {
    var settings = FudgeSettings()
    settings.commands["scratch/create-scratch"] = .init(alias: "cs")
    settings.commands["scratch/scratch-folders"] = .init(enabled: false)
    settings.extensions["next-task"] = .init(enabled: false)
    let items = RootSearch.applying(
        settings,
        to: [
            command("scratch", "create-scratch", title: "Create Scratch"),
            command("scratch", "scratch-folders", title: "Scratch Folders"),
            command("next-task", "next", title: "Next Task"),
        ] + RootSearch.builtInItems)
    #expect(items.map(\.title).contains("Create Scratch"))
    #expect(!items.map(\.title).contains("Scratch Folders"), "a disabled command")
    #expect(!items.map(\.title).contains("Next Task"), "a command of a disabled extension")
    #expect(items.first { $0.title == "Create Scratch" }?.alias == "cs")
    #expect(items.count == 1 + RootSearch.builtInItems.count, "built-in items aren't commands and stay")
}

@Test func aliasThenSpaceHandsTheRestToTheFirstArgument() throws {
    let items = [
        command("scratch", "create-scratch", title: "Create Scratch", mode: "no-view", alias: "cs", arguments: [label]),
        command("scratch", "scratch-folders", title: "Scratch Folders", alias: "sf"),
    ]
    let handed = try #require(CommandAliases.handOff("CS my notes", in: items))
    #expect(handed.item.title == "Create Scratch")
    #expect(handed.rest == "my notes")
    #expect(CommandAliases.handOff("cs ", in: items)?.rest == "", "just the space moves to the field")
    #expect(CommandAliases.handOff("sf notes", in: items) == nil, "no arguments: the space stays in the query")
    #expect(CommandAliases.handOff("cs", in: items) == nil)
    #expect(CommandAliases.handOff("create scratch", in: items) == nil)
}

@Test func hotkeysOfUninstalledOrDisabledCommandsArentAvailable() {
    var settings = FudgeSettings()
    settings.commands["scratch/scratch-folders"] = .init(hotkey: "option+s")
    settings.commands["scratch/create-scratch"] = .init(hotkey: "option+c", enabled: false)
    settings.commands["gone/old"] = .init(hotkey: "option+g")
    settings.extensions["vscode"] = .init(enabled: false)
    settings.commands["vscode/projects"] = .init(hotkey: "option+v")
    let available = settings.availableHotkeys(
        installed: ["scratch/scratch-folders", "scratch/create-scratch", "vscode/projects"])
    #expect(Array(available.keys) == ["scratch/scratch-folders"])
    #expect(settings.commands["gone/old"]?.hotkey == "option+g", "kept for when it's reinstalled")
}
