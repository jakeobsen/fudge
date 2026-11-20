import Foundation
import Testing

@testable import FudgeCore

@Test func fuzzyMatchesCharactersInOrderIgnoringCaseAndAccents() {
    #expect(Fuzzy.match("vsc", in: "Visual Studio Code")?.positions == [0, 7, 14])
    #expect(Fuzzy.match("CAFE", in: "Café Finder") != nil)
    #expect(Fuzzy.match("xyz", in: "Visual Studio Code") == nil)
    #expect(Fuzzy.match("codes", in: "Code") == nil)
    #expect(Fuzzy.match("", in: "anything") == FuzzyMatch(score: 0, positions: []))
}

@Test func fuzzyPrefersWordStartsAndPrefixes() throws {
    let wordStarts = try #require(Fuzzy.match("sp", in: "Search Projects"))
    let inside = try #require(Fuzzy.match("sp", in: "Raspberry"))
    #expect(wordStarts.score > inside.score)

    let prefix = try #require(Fuzzy.match("term", in: "Terminal"))
    let later = try #require(Fuzzy.match("term", in: "Open in Terminal"))
    #expect(prefix.score > later.score)

    #expect(Fuzzy.match("cs", in: "createScratch")?.positions == [0, 6], "camelCase humps count as word starts")
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ title: String, subtitle: String? = nil, keywords: [String] = []) -> RootItem {
    RootItem(
        id: "app:/Applications/\(title).app",
        title: title,
        subtitle: subtitle,
        keywords: keywords,
        kind: .application(URL(fileURLWithPath: "/Applications/\(title).app"))
    )
}

@Test func ranksByMatchQualityThenHistory() {
    let items = [item("Terminal"), item("Text Edit"), item("Scratch Folders"), item("Open in Terminal")]
    #expect(
        RootSearch.rank(items, query: "term", history: LaunchHistory(), now: now).map(\.title) == [
            "Terminal", "Open in Terminal",
        ])

    var history = LaunchHistory()
    for _ in 0..<20 { history.record(items[3].id, at: now) }
    #expect(
        RootSearch.rank(items, query: "term", history: history, now: now).first?.title == "Open in Terminal",
        "heavy use lifts a weaker match"
    )
}

@Test func anEmptyQueryListsMostUsedFirstThenByTitle() {
    let items = [item("Zed"), item("Notes"), item("Mail")]
    var history = LaunchHistory()
    history.record(items[0].id, at: now)
    #expect(RootSearch.rank(items, query: "  ", history: history, now: now).map(\.title) == ["Zed", "Mail", "Notes"])
}

@Test func keywordsAndSubtitlesMatchButWeighLess() {
    let byKeyword = item("Say Hello", keywords: ["greeting"])
    let bySubtitle = item("Create Scratch", subtitle: "Greeting Tools")
    let byTitle = item("Greeting Cards")
    let ranked = RootSearch.rank(
        [bySubtitle, byKeyword, byTitle], query: "greeting", history: LaunchHistory(), now: now)
    #expect(ranked.map(\.title) == ["Greeting Cards", "Say Hello", "Create Scratch"])
}

@Test func theSettingsItemIsFoundByItsKeywordsOnly() {
    let items = [item("Terminal"), item("Safari"), item("Mail"), item("Notes")] + RootSearch.builtInItems
    for query in ["settings", "preferences", "config", "fudge", "Pref"] {
        #expect(
            RootSearch.rank(items, query: query, history: LaunchHistory(), now: now).first == .settings,
            "found by \(query)")
    }
    for query in ["terminal", "safari", "mail", "notes", "xyz"] {
        #expect(
            !RootSearch.rank(items, query: query, history: LaunchHistory(), now: now).contains(.settings),
            "not shown for \(query)")
    }
    #expect(RootItem.settings.title == "fudge Settings")
    #expect(RootItem.settings.kind == .settings)
}

@Test func theSettingsItemRanksByHistoryLikeAnyOther() {
    let items = [item("Fudge Factory")] + RootSearch.builtInItems
    #expect(RootSearch.rank(items, query: "fudge", history: LaunchHistory(), now: now).first?.title == "Fudge Factory")
    var history = LaunchHistory()
    for _ in 0..<20 { history.record(RootItem.settings.id, at: now) }
    #expect(RootSearch.rank(items, query: "fudge", history: history, now: now).first == .settings)
}

@Test func historyDecaysWithAge() {
    var history = LaunchHistory()
    history.record("a", at: now)
    history.record("b", at: now.addingTimeInterval(-7 * 86_400))
    #expect(history.score("a", now: now) == 1)
    #expect(history.score("b", now: now) == 0.5)
    #expect(history.score("never", now: now) == 0)
}

@Test func historyRoundTripsThroughAFile() throws {
    var history = LaunchHistory()
    history.record("command:scratch/create-scratch", at: now)
    history.record("command:scratch/create-scratch", at: now)
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/history.json")
    try history.save(to: file)
    #expect(LaunchHistory.load(from: file) == history)
    #expect(LaunchHistory.load(from: file.appendingPathExtension("missing")) == LaunchHistory())
}

@Test func commandsBecomeRootItemsWithTheirExtensionAndIcon() throws {
    let manifest = try ExtensionManifest.load(from: Fixtures.greeter.appendingPathComponent("package.json"))
    let installed = InstalledExtension(manifest: manifest, directory: Fixtures.greeter)
    let items = RootItem.commands(of: installed)
    #expect(items.map(\.id) == ["command:greeter/greet", "command:greeter/quiet"])
    #expect(items.map(\.subtitle) == ["Greeter", "Greeter"])
    #expect(items[0].keywords == ["hello"])
    #expect(items[0].iconFile?.lastPathComponent == "icon.png")
    #expect(items[0].arguments.isEmpty)
    #expect(items[1].arguments.map(\.name) == ["who"])
    #expect(
        items[1].kind
            == .command(extension: "greeter", command: "quiet", mode: "no-view", entry: installed.entry(for: "quiet"))
    )
}

@Test func scansFoldersForApplications() throws {
    let folder = try Fixtures.temporaryDirectory()
    for name in ["Zeta.app", "Alpha.app", "notes.txt"] {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let items = ApplicationIndex.scan([folder, folder])
    #expect(items.map(\.title) == ["Alpha", "Zeta"], "sorted, without duplicates or non-apps")
    #expect(items.first?.id == "app:\(folder.appendingPathComponent("Alpha.app").resolvingSymlinksInPath().path)")
}
