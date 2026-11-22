import Foundation
import Testing

@testable import FudgeCore

/// A made-up installed extension with a Settings page, titled `title`.
private func page(_ name: String, _ title: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "preferences": [], "commands": [] }"#
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension(manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent/\(name)"))
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
        SettingsSidebar.extensions(pages).map(\.title) == [
            "Bear", "Calculator", "Calendar", "Coffee", "Color Picker", "Quicklinks", "Snippets",
            "Window Management", "Zoom",
        ])
    #expect(SettingsSidebar.extensions(pages).allSatisfy { $0.symbol == nil }, "the title only, as the extensions'")
}

@Test func theExtensionsListSortsAsFinderDoes() throws {
    // Plain `<` would put "bear notes" after "Zoom" and "Item 10" before "Item 9".
    let pages = [
        try page("zoom", "Zoom"), try page("item-10", "Item 10"), try page("bear-notes", "bear notes"),
        try page("coffee", "Coffee"), try page("item-9", "Item 9"), try page("bear", "Bear"),
    ]
    #expect(
        SettingsSidebar.extensions(pages).map(\.title) == [
            "Bear", "bear notes", "Calculator", "Calendar", "Coffee", "Color Picker", "Item 9", "Item 10",
            "Quicklinks", "Snippets", "Window Management", "Zoom",
        ])
}

@Test func withNoExtensionsTheListIsFudgesOwnPages() {
    #expect(
        SettingsSidebar.extensions([]).map(\.tag) == [
            ":calculator", ":calendar", ":color-picker", ":quicklinks", ":snippets", ":window-management",
        ])
}

@Test func noExtensionCanTakeOneOfFudgesPages() throws {
    let own = SettingsSidebar.top + SettingsSidebar.builtInExtensions
    #expect(own.allSatisfy { $0.tag.hasPrefix(":") }, "an extension name can't start with \":\"")
    #expect(Set(own.map(\.tag)).count == own.count, "each page has its own tag")
    #expect(SettingsSidebar.tag(of: try page("calendar", "Calendar")) == "calendar")
}

@Test func anExtensionTitledLikeABuiltInPageComesRightAfterIt() throws {
    let pages = [try page("color-picker", "Color Picker"), try page("calendar", "Calendar")]
    let list = SettingsSidebar.extensions(pages)
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
    #expect(SettingsSidebar.extensions(pages.reversed()) == list, "the order never depends on the input's")
}

@Test func anExtensionWhoseNameStartsWithADigitStillComesAfterTheBuiltInPage() throws {
    // "1calendar" sorts before ":calendar" with plain `<`; the built-in page goes first by rule.
    let pages = [try page("1calendar", "Calendar")]
    #expect(
        SettingsSidebar.extensions(pages).map(\.tag).prefix(3) == [":calculator", ":calendar", "1calendar"])
    #expect(SettingsSidebar.extensions(pages)[2].title == "Calendar (installed)")
}

@Test func theSuffixGoesOnlyOnExactlyABuiltInPagesTitle() throws {
    #expect(SettingsSidebar.title(of: try page("bear", "Bear")) == "Bear")
    #expect(SettingsSidebar.title(of: try page("colors", "Color Pickers")) == "Color Pickers")
    #expect(SettingsSidebar.title(of: try page("my-colors", "color picker")) == "color picker", "another title")
    let list = SettingsSidebar.extensions([try page("bear", "Bear")])
    #expect(list.filter { !$0.tag.hasPrefix(":") }.map(\.title) == ["Bear"])
}

@Test func twoExtensionsWithTheSameTitleKeepTheirTagsOrder() throws {
    let pages = [try page("coffee-b", "Coffee"), try page("coffee-a", "Coffee")]
    let tags = { (pages: [InstalledExtension]) in
        SettingsSidebar.extensions(pages).map(\.tag).filter { $0.hasPrefix("coffee") }
    }
    #expect(tags(pages) == ["coffee-a", "coffee-b"])
    #expect(tags(pages.reversed()) == ["coffee-a", "coffee-b"], "whichever order they're given in")
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
        SettingsSidebar.extensions([]).contains {
            $0.tag == RootActions.currencySettingsPage && $0.title == "Calculator"
        })
}
