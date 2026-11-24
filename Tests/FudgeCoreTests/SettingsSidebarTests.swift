import Foundation
import Testing

@testable import FudgeCore

/// A made-up installed extension with a Settings page, titled `title`.
private func page(_ name: String, _ title: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "preferences": [], "commands": [] }"#
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension.topLevel(manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent/\(name)"))
}

/// A made-up extension `name` with a Settings page, installed in the repository folder `folder`.
private func page(_ name: String, _ title: String, in folder: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "preferences": [], "commands": [] }"#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/\(folder)/\(name)"),
        id: try #require(ExtensionID(name: name, repositoryFolder: folder)),
        repository: try #require(InstalledExtension.Repository(folder: folder)))
}

/// `installed`'s row title when it's the only install (SPEC-174: no other install shares its title).
private func alone(_ installed: InstalledExtension) -> String {
    SettingsSidebar.title(of: installed, titles: .forTests([installed]))
}

@Test func theTopListIsFudgesCorePagesInOrder() {
    #expect(
        SettingsSidebar.top.map(\.title) == [
            "General", "Permissions", "Notifications", "Commands", "Sign-in", "Development",
        ])
    #expect(
        SettingsSidebar.top.map(\.tag) == [
            ":general", ":permissions", ":notifications", ":commands", ":sign-in", ":development",
        ])
    #expect(
        SettingsSidebar.top.map(\.symbol) == [
            "gearshape", "hand.raised", "bell", "command", "person.badge.key", "hammer",
        ])
}

@Test func fudgesOwnPagesSortInAmongTheExtensions() throws {
    let pages = [try page("zoom", "Zoom"), try page("bear", "Bear"), try page("coffee", "Coffee")]
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.title) == [
            "Bear", "Calculator", "Calendar", "Coffee", "Color Picker", "Quicklinks", "Snippets",
            "Window Management", "Zoom",
        ])
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).allSatisfy { $0.symbol == nil },
        "the title only, as the extensions'")
}

@Test func theExtensionsListSortsAsFinderDoes() throws {
    // Plain `<` would put "bear notes" after "Zoom" and "Item 10" before "Item 9".
    let pages = [
        try page("zoom", "Zoom"), try page("item-10", "Item 10"), try page("bear-notes", "bear notes"),
        try page("coffee", "Coffee"), try page("item-9", "Item 9"), try page("bear", "Bear"),
    ]
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.title) == [
            "Bear", "bear notes", "Calculator", "Calendar", "Coffee", "Color Picker", "Item 9", "Item 10",
            "Quicklinks", "Snippets", "Window Management", "Zoom",
        ])
}

@Test func withNoExtensionsTheListIsFudgesOwnPages() {
    #expect(
        SettingsSidebar.extensions([], titles: .forTests([])).map(\.tag) == [
            ":calculator", ":calendar", ":color-picker", ":quicklinks", ":snippets", ":window-management",
        ])
}

@Test func noExtensionCanTakeOneOfFudgesPages() throws {
    let own = SettingsSidebar.top + SettingsSidebar.builtInExtensions
    #expect(own.allSatisfy { $0.tag.hasPrefix(":") }, "an extension id can't start with \":\"")
    #expect(Set(own.map(\.tag)).count == own.count, "each page has its own tag")
    #expect(SettingsSidebar.tag(of: try page("calendar", "Calendar")) == "calendar")
}

@Test func anExtensionTitledLikeABuiltInPageComesRightAfterIt() throws {
    let pages = [try page("color-picker", "Color Picker"), try page("calendar", "Calendar")]
    let list = SettingsSidebar.extensions(pages, titles: .forTests(pages))
    #expect(
        list.map(\.tag) == [
            ":calculator", ":calendar", "calendar", ":color-picker", "color-picker", ":quicklinks", ":snippets",
            ":window-management",
        ],
        "Fudge's own first, then the extension's, each with its own tag")
    #expect(
        list.map(\.title) == [
            "Calculator", "Calendar", "Calendar (installed)", "Color Picker", "Color Picker (installed)",
            "Quicklinks", "Snippets", "Window Management",
        ])
    #expect(
        SettingsSidebar.extensions(pages.reversed(), titles: .forTests(pages.reversed())) == list,
        "the order never depends on the input's")
}

@Test func anExtensionWhoseNameStartsWithADigitStillComesAfterTheBuiltInPage() throws {
    // "1calendar" sorts before ":calendar" with plain `<`; the built-in page goes first by rule.
    let pages = [try page("1calendar", "Calendar")]
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.tag).prefix(3) == [
            ":calculator", ":calendar", "1calendar",
        ])
    #expect(SettingsSidebar.extensions(pages, titles: .forTests(pages))[2].title == "Calendar (installed)")
}

@Test func theSuffixGoesOnlyOnExactlyABuiltInPagesTitle() throws {
    #expect(alone(try page("bear", "Bear")) == "Bear")
    #expect(alone(try page("colors", "Color Pickers")) == "Color Pickers")
    #expect(alone(try page("my-colors", "color picker")) == "color picker", "another title")
    let bear = [try page("bear", "Bear")]
    let list = SettingsSidebar.extensions(bear, titles: .forTests(bear))
    #expect(list.filter { !$0.tag.hasPrefix(":") }.map(\.title) == ["Bear"])
}

@Test func twoExtensionsWithTheSameTitleKeepTheirTagsOrder() throws {
    let pages = [try page("coffee-b", "Coffee"), try page("coffee-a", "Coffee")]
    let tags = { (pages: [InstalledExtension]) in
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.tag).filter { $0.hasPrefix("coffee") }
    }
    #expect(tags(pages) == ["coffee-a", "coffee-b"])
    #expect(tags(pages.reversed()) == ["coffee-a", "coffee-b"], "whichever order they're given in")
}

@Test func twoGitHubPagesHaveTwoTags() throws {
    let pages = [
        try page("github", "GitHub", in: "someone/tools"), try page("github", "GitHub", in: "raycast/extensions"),
        try page("github", "GitHub", in: "fudgeapp/development"),
    ]
    let rows = SettingsSidebar.extensions(pages, titles: .forTests(pages)).filter { !$0.tag.hasPrefix(":") }
    #expect(
        rows.map(\.tag) == ["fudgeapp+development+github", "github", "someone+tools+github"], "each page by its id")
    #expect(rows.map(\.title) == ["GitHub (development)", "GitHub (raycast/extensions)", "GitHub (someone/tools)"])
    #expect(
        SettingsSidebar.extensions(pages.reversed(), titles: .forTests(pages.reversed()))
            == SettingsSidebar.extensions(pages, titles: .forTests(pages)))
    for tag in ["github", "someone+tools+github", "fudgeapp+development+github"] {
        #expect(SettingsSidebar.lists(tag, among: pages), "\(tag)")
        #expect(!SettingsSidebar.lists(tag, among: pages.filter { $0.id.key != tag }), "\(tag) removed")
    }
}

/// A made-up bundled extension with a Settings page, as `InstalledExtension.all(paths:resources:)` lists one.
private func bundledPage(_ name: String, _ title: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "preferences": [], "commands": [] }"#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/resources/\(name)"), id: .bundled(name), repository: .bundled)
}

/// SPEC-177 test 1: rows of one title come Fudge's own page first, then by repository label, A to Z, whatever order the
/// repositories are listed in, then by tag.
@Test func oneTitlesRowsGoByRepositoryLabel() throws {
    let tools = try ExtensionRepository.parse(address: "https://github.com/someone/tools").get()
    func settings(raycast: String?, tools label: String?, toolsFirst: Bool = false) -> FudgeSettings {
        var settings = FudgeSettings()
        let entries = [
            ListedRepository(repository: .raycast, label: raycast), ListedRepository(repository: tools, label: label),
        ]
        settings.extensionRepositories = toolsFirst ? Array(entries.reversed()) : entries
        return settings
    }
    func shown(_ pages: [InstalledExtension], _ settings: FudgeSettings, prefix: String) -> [String] {
        let titles = ExtensionTitles(pages, names: RepositoryNames(settings: settings))
        return SettingsSidebar.extensions(pages, titles: titles).map(\.title).filter { $0.hasPrefix(prefix) }
    }
    let pages = [
        try page("clipboard", "Clipboard History", in: "raycast/extensions"),
        try page("clipboard", "Clipboard History", in: "someone/tools"),
        try page("clipboard", "Clipboard History", in: "fudgeapp/development"),
        try bundledPage("clipboard-history", "Clipboard History"),
    ]
    let order = [
        "Clipboard History (Core)", "Clipboard History (development)", "Clipboard History (Fudge)",
        "Clipboard History (Raycast)",
    ]
    for toolsFirst in [false, true] {
        let named = settings(raycast: "Raycast", tools: "Fudge", toolsFirst: toolsFirst)
        #expect(shown(pages, named, prefix: "Clipboard") == order, "tools listed first: \(toolsFirst)")
        #expect(shown(pages.reversed(), named, prefix: "Clipboard") == order, "pages in any order")
    }
    // Named Aardvark, the added repository's row comes first, which the tags alone don't give.
    #expect(
        shown(pages, settings(raycast: "Raycast", tools: "Aardvark"), prefix: "Clipboard") == [
            "Clipboard History (Aardvark)", "Clipboard History (Core)", "Clipboard History (development)",
            "Clipboard History (Raycast)",
        ])
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.tag).filter { $0.contains("clipboard") } == [
            "clipboard-history", "fudgeapp+development+clipboard", "clipboard", "someone+tools+clipboard",
        ], "unnamed: Core, development, raycast/extensions, someone/tools")
    // Raycast's entry unnamed: its address sorts like any label.
    #expect(
        shown(Array(pages.prefix(2)), settings(raycast: nil, tools: nil), prefix: "Clipboard") == [
            "Clipboard History (raycast/extensions)", "Clipboard History (someone/tools)",
        ])
    // Fudge's own Calendar page still comes first among rows of its title.
    let calendars = [try page("calendar", "Calendar", in: "someone/tools"), try bundledPage("calendar", "Calendar")]
    #expect(
        shown(calendars, settings(raycast: nil, tools: "Aardvark"), prefix: "Calendar") == [
            "Calendar", "Calendar (Aardvark)", "Calendar (Core)",
        ])
    // Two of one repository with one title fall back to the tag.
    let two = [
        try page("notes-b", "Notes", in: "someone/tools"), try page("notes-a", "Notes", in: "someone/tools"),
        try page("notes", "Notes", in: "raycast/extensions"),
    ]
    #expect(
        SettingsSidebar.extensions(two, titles: .forTests(two)).map(\.tag).filter { $0.contains("notes") } == [
            "notes", "someone+tools+notes-a", "someone+tools+notes-b",
        ])
}

/// SPEC-174 test 8: " (installed)" goes on any install without a label, from any repository; one with a label shows
/// it instead, never both.
@Test func anUnlabeledCopyFromAnyRepositoryIsInstalledAndALabeledOneNeverIs() throws {
    for folder in ["raycast/extensions", "someone/tools", "fudgeapp/development"] {
        #expect(alone(try page("color-picker", "Color Picker", in: folder)) == "Color Picker (installed)", "\(folder)")
    }
    #expect(alone(try page("bear", "Bear", in: "someone/tools")) == "Bear")
    for folder in ["someone/tools", "fudgeapp/development"] {
        let pages = [
            try page("color-picker", "Color Picker", in: folder),
            try page("colors", "Color Picker", in: "raycast/extensions"),
        ]
        // By repository label, after Fudge's own page (SPEC-177).
        let labeled =
            folder == "someone/tools"
            ? ["Color Picker (raycast/extensions)", "Color Picker (someone/tools)"]
            : ["Color Picker (development)", "Color Picker (raycast/extensions)"]
        #expect(
            SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.title)
                .filter { $0.hasPrefix("Color Picker") } == ["Color Picker"] + labeled, "\(folder)")
    }
}

@Test func theFixedTagsAreEveryPageOfFudgesOwn() {
    #expect(
        SettingsSidebar.fixedTags == [
            ":general", ":permissions", ":notifications", ":commands", ":sign-in", ":development", ":calculator",
            ":calendar", ":color-picker", ":quicklinks", ":snippets", ":window-management",
        ])
    #expect(SettingsSidebar.fixedTags.contains(SettingsSidebar.calculatorPage))
    #expect(SettingsSidebar.notificationsPage == ":notifications")
}

@Test func aSelectedPageStaysWhileItsListed() throws {
    let pages = [try page("weather", "Weather")]
    #expect(SettingsSidebar.lists(":calculator", among: pages))
    #expect(SettingsSidebar.lists(":general", among: []))
    #expect(SettingsSidebar.lists(":notifications", among: pages), "a reload keeps the Notifications page")
    #expect(SettingsSidebar.lists(":notifications", among: []))
    #expect(SettingsSidebar.lists("weather", among: pages))
    #expect(!SettingsSidebar.lists("weather", among: []), "an extension removed while its page is open")
    #expect(!SettingsSidebar.lists(":gone", among: pages))
    #expect(!SettingsSidebar.lists(nil, among: pages))
}

@Test func theCurrencyCardOpensTheCalculatorPage() {
    // The card's ↵ and its action panel's Turn On Currency Conversion both open this page.
    #expect(RootActions.currencySettingsPage == ":calculator")
    #expect(
        SettingsSidebar.extensions([], titles: .forTests([])).contains {
            $0.tag == RootActions.currencySettingsPage && $0.title == "Calculator"
        })
}
