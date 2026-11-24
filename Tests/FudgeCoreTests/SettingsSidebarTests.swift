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
        rows.map(\.tag) == ["github", "fudgeapp+development+github", "someone+tools+github"], "each page by its id")
    #expect(rows.map(\.title) == ["GitHub (raycast/extensions)", "GitHub (development)", "GitHub (someone/tools)"])
    #expect(
        SettingsSidebar.extensions(pages.reversed(), titles: .forTests(pages.reversed()))
            == SettingsSidebar.extensions(pages, titles: .forTests(pages)))
    for tag in ["github", "someone+tools+github", "fudgeapp+development+github"] {
        #expect(SettingsSidebar.lists(tag, among: pages), "\(tag)")
        #expect(!SettingsSidebar.lists(tag, among: pages.filter { $0.id.key != tag }), "\(tag) removed")
    }
}

@Test func oneTitlesRowsGoRaycastsThenTheDevelopmentFoldersThenTheAddedRepositoriesByFolder() throws {
    let folders = [
        "someone/tools", "fudgeapp/development", "some-one/tools", "git.example.org/team/tools", "raycast/extensions",
        "some/tools",
    ]
    let pages = try folders.map { try page("github", "GitHub", in: $0) }
    let expected = [
        "GitHub (raycast/extensions)", "GitHub (development)", "GitHub (git.example.org/team/tools)",
        "GitHub (some/tools)",
        "GitHub (some-one/tools)", "GitHub (someone/tools)",
    ]
    #expect(
        SettingsSidebar.extensions(pages, titles: .forTests(pages)).filter { !$0.tag.hasPrefix(":") }.map(\.title)
            == expected)
    #expect(
        SettingsSidebar.extensions(pages.reversed(), titles: .forTests(pages.reversed())).filter {
            !$0.tag.hasPrefix(":")
        }.map(\.title) == expected,
        "whichever order they're given in")
    // Fudge's own page still comes first among rows of its title, then Raycast's copy, then the others.
    let colorPickers = try ["someone/tools", "raycast/extensions", "fudgeapp/development"].map {
        try page("color-picker", "Color Picker", in: $0)
    }
    #expect(
        SettingsSidebar.extensions(colorPickers, titles: .forTests(colorPickers)).map(\.title).filter {
            $0.hasPrefix("Color Picker")
        } == [
            "Color Picker", "Color Picker (raycast/extensions)", "Color Picker (development)",
            "Color Picker (someone/tools)",
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
        let label = folder == "someone/tools" ? "someone/tools" : "development"
        #expect(
            SettingsSidebar.extensions(pages, titles: .forTests(pages)).map(\.title)
                .filter { $0.hasPrefix("Color Picker") } == [
                    "Color Picker", "Color Picker (raycast/extensions)", "Color Picker (\(label))",
                ], "\(folder)")
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
