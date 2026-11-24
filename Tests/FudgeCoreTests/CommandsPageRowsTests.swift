import Foundation
import Testing

@testable import FudgeCore

/// A made-up `github` extension with two commands and one that isn't listed, installed in the repository folder
/// `folder`.
private func github(in folder: String) throws -> InstalledExtension {
    let json = #"""
        { "name": "github", "title": "GitHub", "icon": "icon.png", "commands": [
            { "name": "search-repositories", "title": "Search Repositories", "mode": "view" },
            { "name": "my-pull-requests", "title": "My Pull Requests", "mode": "menu-bar" },
            { "name": "unknown-mode", "title": "Unknown Mode", "mode": "other" } ] }
        """#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/\(folder)/github"),
        id: try #require(ExtensionID(name: "github", repositoryFolder: folder)),
        repository: try #require(InstalledExtension.Repository(folder: folder)))
}

@Test func twoExtensionsOfOneNameBothListTheirCommands() throws {
    let installed = [try github(in: "raycast/extensions"), try github(in: "someone/tools")]
    let rows = CommandsPageRows.rows(groups: [], extensions: installed, titles: .forTests(installed), search: "")
    #expect(rows.map(\.owner) == installed.map { .extension($0.id) })
    #expect(rows.map(\.title) == ["GitHub (raycast)", "GitHub (someone/tools)"], "both labeled (SPEC-174)")
    #expect(rows.map(\.type) == ["Extension", "Extension"])
    #expect(
        rows.map { $0.commands.map(\.id) } == [
            ["github/search-repositories", "github/my-pull-requests"],
            ["someone+tools+github/search-repositories", "someone+tools+github/my-pull-requests"],
        ], "each command row by its whole id, so the second extension's rows aren't taken for the first's")
    #expect(rows.flatMap(\.commands).map(\.title) == ["Search Repositories", "My Pull Requests"].repeated(2))
    #expect(rows[1].commands.first?.icon == .asset("icon.png", installed[1]), "its own install's icon")
}

@Test func everyRowOnThePageHasAnIdOfItsOwn() throws {
    let installed = [
        try github(in: "raycast/extensions"), try github(in: "fudgeapp/development"), try github(in: "someone/tools"),
    ]
    let rows = CommandsPageRows.rows(
        groups: BuiltInCommandGroup.all, extensions: installed, titles: .forTests(installed), search: "")
    let owners = rows.map(\.owner)
    let ids = rows.flatMap(\.commands).map(\.id)
    #expect(Set(owners).count == owners.count)
    #expect(Set(ids).count == ids.count)
    #expect(ids.count == BuiltInCommandGroup.all.map(\.commands.count).reduce(0, +) + 3 * 2)
    let system = try #require(rows.first { $0.owner == .group(.system) })
    #expect(system.type == "Built-in" && system.icon == .app)
    #expect(system.commands.allSatisfy { $0.id.hasPrefix(":system/") && $0.type == "Command" })
}

@Test func aSearchKeepsAMatchingGroupWholeAndOtherwiseItsMatchingCommands() throws {
    let installed = [try github(in: "raycast/extensions"), try github(in: "someone/tools")]
    let byTitle = CommandsPageRows.rows(
        groups: [], extensions: installed, titles: .forTests(installed), search: " github ")
    #expect(byTitle.map { $0.commands.count } == [2, 2], "a group whose title matches keeps all its commands")
    let byCommand = CommandsPageRows.rows(
        groups: [], extensions: installed, titles: .forTests(installed), search: "SEARCH repo")
    #expect(
        byCommand.map { $0.commands.map(\.id) } == [
            ["github/search-repositories"], ["someone+tools+github/search-repositories"],
        ])
    #expect(
        CommandsPageRows.rows(
            groups: [], extensions: installed, titles: .forTests(installed), search: "nothing like it"
        ).isEmpty)
}

@Test func aGroupWithNoCommandsIsLeftOut() {
    let empty = BuiltInCommandGroup(name: .quicklinks, title: "Quicklinks", commands: [])
    #expect(CommandsPageRows.rows(groups: [empty], extensions: [], titles: .forTests([]), search: "").isEmpty)
}

extension Array {
    fileprivate func repeated(_ times: Int) -> [Element] { Array((0..<times).map { _ in self }.joined()) }
}
