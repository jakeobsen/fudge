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

@Test func fuzzyKeepsPositionsWhenACharacterFoldsIntoSeveral() {
    // "ß" folds into "ss" and "ﬁ" into "fi"; each keeps its first, so positions stay the candidate's.
    #expect(Fuzzy.match("strae", in: "Straße")?.positions == [0, 1, 2, 3, 5])
    #expect(Fuzzy.match("fle", in: "ﬁle")?.positions == [0, 1, 2])
    #expect(Fuzzy.match("f", in: "ﬁle")?.positions == [0])
    #expect(Fuzzy.match("le", in: "Ünïcödé ﬁle")?.positions == [9, 10])
    // And all of what it folds into matches: "strasse" finds "Straße" again, highlighting each of its letters once.
    #expect(Fuzzy.match("strasse", in: "Straße")?.positions == [0, 1, 2, 3, 4, 5])
    #expect(Fuzzy.match("sß", in: "Straße")?.positions == [0, 4])
    #expect(Fuzzy.match("ess", in: "Eßlingen")?.positions == [0, 1])
    #expect(Fuzzy.match("file", in: "ﬁle")?.positions == [0, 1, 2])
    #expect(Fuzzy.match("strasse", in: "Straße")?.score == Fuzzy.match("strase", in: "Strase")?.score)
    #expect(Fuzzy.match("strassen", in: "Straße") == nil)
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

// MARK: - A fresh root search (SPEC-114 §4)

/// A bundled extension's commands, from its manifest in `runtime/`, as root search lists them.
private func bundledCommands(_ folder: String) throws -> [RootItem] {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/\(folder)")
    let manifest = try ExtensionManifest.load(from: directory.appendingPathComponent("package.json"))
    return RootItem.commands(of: InstalledExtension.topLevel(manifest: manifest, directory: directory))
}

private func byTitle(_ titles: [String]) -> [String] {
    titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

@Test func aFreshRootSearchListsSomeOfFudgesOwnItemsFirst() throws {
    let apps = [item("Calendar"), item("Arc"), item("Zed")]
    let items =
        try apps + RootSearch.builtInItems + bundledCommands("emoji-extension")
        + bundledCommands("clipboard-history-extension")
    let fresh = RootSearch.rank(items, query: "", history: LaunchHistory(), now: now)
    #expect(
        fresh.prefix(4).map(\.title) == [
            "Search Snippets", "Clipboard History", "Search Emoji & Symbols", "Fudge Settings",
        ])
    #expect(fresh.prefix(4).map(\.id) == RootSearch.firstRunItemIDs, "the manifests' own commands")
    // Then everything else by title, as before.
    let rest = fresh.dropFirst(4).map(\.title)
    #expect(rest == byTitle(rest) && rest.count == items.count - 4)

    // One item that isn't there (turned off) is left out, and the others keep their order.
    let withoutEmoji = items.filter { $0.title != "Search Emoji & Symbols" }
    #expect(
        RootSearch.rank(withoutEmoji, query: "", history: LaunchHistory(), now: now).prefix(3).map(\.title) == [
            "Search Snippets", "Clipboard History", "Fudge Settings",
        ])
    // A typed search is ranked by its match, as before.
    #expect(RootSearch.rank(items, query: "zed", history: LaunchHistory(), now: now).first?.title == "Zed")
}

@Test func anyHistoryPutsAnEmptyRootSearchBackAsItWas() throws {
    let apps = [item("Calendar"), item("Arc"), item("Zed")]
    let items = try apps + RootSearch.builtInItems + bundledCommands("emoji-extension")
    // One launch of anything: most-used first, then everything by title, Fudge's items in their places.
    var history = LaunchHistory()
    history.record(apps[2].id, at: now)
    let used = RootSearch.rank(items, query: "", history: history, now: now).map(\.title)
    #expect(used.first == "Zed")
    #expect(Array(used.dropFirst()) == byTitle(Array(used.dropFirst())))

    // Even a launch of an item that's gone since counts.
    var gone = LaunchHistory()
    gone.record("app:/Applications/Removed.app", at: now)
    #expect(RootSearch.rank(items, query: "", history: gone, now: now).map(\.title) == byTitle(items.map(\.title)))

    // Clear Search History empties it, so a new start shows them first again.
    history.clear()
    #expect(RootSearch.rank(items, query: "", history: history, now: now).first == .searchSnippets)
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
    #expect(RootItem.settings.title == "Fudge Settings")
    #expect(RootItem.settings.kind == .settings)
}

@Test func rootSearchHasCreateQuicklinkSnippetsReloadExtensionsAndQuitBesideSettings() {
    #expect(
        RootSearch.builtInItems == [
            .settings, .createQuicklink, .searchSnippets, .createSnippet, .reloadExtensions, .quit,
        ])
    #expect(Set(RootSearch.builtInItems.map(\.id)).count == 6)
    #expect(RootItem.searchSnippets.kind == .searchSnippets && RootItem.createSnippet.kind == .createSnippet)
    #expect(RootItem.createQuicklink.title == "Create Quicklink")
    #expect(RootItem.createQuicklink.kind == .createQuicklink && RootItem.createQuicklink.recordsLaunch)
    #expect(RootItem.reloadExtensions.title == "Reload Extensions")
    #expect(RootItem.reloadExtensions.kind == .reloadExtensions)
    #expect(RootItem.quit.title == "Quit Fudge")
    #expect(RootItem.quit.kind == .quit)
}

@Test func reloadExtensionsAndQuitAreFoundByTitleAndKeywords() {
    let items = [item("Terminal"), item("Safari"), item("Mail"), item("Notes")] + RootSearch.builtInItems
    func first(_ query: String) -> RootItem? {
        RootSearch.rank(items, query: query, history: LaunchHistory(), now: now).first
    }
    for query in ["reload", "Reload Ext", "refresh", "extensions"] {
        #expect(first(query) == .reloadExtensions, "found by \(query)")
    }
    for query in ["quit", "Quit Fudge", "exit"] {
        #expect(first(query) == .quit, "found by \(query)")
    }
    for query in ["create quicklink", "Create Quick", "quicklink", "bookmark"] {
        #expect(first(query) == .createQuicklink, "found by \(query)")
    }
    for query in ["search snippets", "snippets"] {
        #expect(first(query) == .searchSnippets, "found by \(query)")
    }
    #expect(first("create snippet") == .createSnippet)
    let fudge = RootSearch.rank(items, query: "fudge", history: LaunchHistory(), now: now)
    #expect(fudge.first == .settings)
    #expect(
        Set(fudge.prefix(RootSearch.builtInItems.count).map(\.id)) == Set(RootSearch.builtInItems.map(\.id)),
        "typing fudge finds all of fudge's own items")
    for query in ["terminal", "safari", "xyz"] {
        let ranked = RootSearch.rank(items, query: query, history: LaunchHistory(), now: now)
        #expect(!ranked.contains(.reloadExtensions) && !ranked.contains(.quit), "not shown for \(query)")
    }
}

@Test func quittingNeverCountsInLaunchHistory() {
    #expect(!RootItem.quit.recordsLaunch)
    #expect(RootItem.settings.recordsLaunch)
    #expect(RootItem.reloadExtensions.recordsLaunch)
    #expect(item("Terminal").recordsLaunch)

    // Opened often, as the launcher records it: Quit still never rises to the top of an empty search.
    let items = [item("Terminal")] + RootSearch.builtInItems
    var history = LaunchHistory()
    for _ in 0..<20 {
        for opened in [RootItem.quit, .reloadExtensions] where opened.recordsLaunch {
            history.record(opened.id, at: now)
        }
    }
    #expect(history.score(RootItem.quit.id, now: now) == 0)
    #expect(RootSearch.rank(items, query: "", history: history, now: now).first == .reloadExtensions)
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
    let installed = InstalledExtension.topLevel(manifest: manifest, directory: Fixtures.greeter)
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

// MARK: - No subtitle that only repeats the title (SPEC-120)

private func commandItems(_ json: String, metadata: CommandMetadata = CommandMetadata()) throws -> [RootItem] {
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    let installed = InstalledExtension.topLevel(
        manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent/\(manifest.name)"))
    return RootItem.commands(of: installed, metadata: metadata)
}

@Test func aCommandNamedLikeItsExtensionHasNoSubtitle() throws {
    let items = try commandItems(
        #"""
        {"name":"clipboard","title":"Clipboard History","commands":[
          {"name":"clipboard-history","title":"Clipboard History","mode":"view"},
          {"name":"clear","title":"Clear History","mode":"no-view"},
          {"name":"shouting","title":"CLIPBOARD history ","mode":"view"}]}
        """#)
    #expect(items.map(\.subtitle) == [nil, "Clipboard History", nil], "the same title, ignoring case and spaces")
    // Typing the extension's name still finds it, through `extensionTitle`.
    #expect(items[0].extensionTitle == "Clipboard History")
    let found = RootSearch.rank(
        items + [item("Clipboard Viewer")], query: "clipboard history", history: LaunchHistory())
    #expect(found.contains { $0.id == items[0].id })

    // A subtitle the author wrote in the manifest is shown as written, even one that repeats the title.
    let own = try commandItems(
        #"""
        {"name":"notes","title":"Notes","commands":[
          {"name":"notes","title":"Notes","subtitle":"notes","mode":"view"},
          {"name":"new","title":"New Note","subtitle":"Notes","mode":"view"}]}
        """#)
    #expect(own.map(\.subtitle) == ["notes", "Notes"])
}

@Test func aBuiltInCommandNamedLikeItsGroupHasNoSubtitle() {
    let group = BuiltInCommandGroup(
        name: ":clock", title: "Clock",
        commands: [
            BuiltInCommand(name: "clock", title: "Clock", symbol: "clock"),
            BuiltInCommand(name: "timer", title: "Start Timer", symbol: "timer"),
        ])
    let items = RootItem.builtInCommands(of: group)
    #expect(items.map(\.subtitle) == [nil, "Clock"])
    #expect(items.map(\.extensionTitle) == ["Clock", "Clock"], "search still matches the group's title")
    // Fudge's own groups don't have one today, so their rows keep the group's title.
    for group in BuiltInCommandGroup.all {
        for item in RootItem.builtInCommands(of: group) { #expect(item.subtitle == group.title, "\(item.title)") }
    }
}

@Test func aSubtitleTheCommandSetItselfIsShownAsSet() throws {
    var metadata = CommandMetadata()
    metadata.setSubtitle("Clipboard History", extension: "clipboard", command: "clipboard-history")
    let items = try commandItems(
        #"""
        {"name":"clipboard","title":"Clipboard History","commands":[
          {"name":"clipboard-history","title":"Clipboard History","mode":"view"}]}
        """#, metadata: metadata)
    #expect(items.map(\.subtitle) == ["Clipboard History"], "the extension chose it")
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
