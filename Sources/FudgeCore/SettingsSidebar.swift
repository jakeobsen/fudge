import Foundation

/// The Settings window's sidebar: Fudge's core pages on top, then one Extensions list, where the pages of Fudge's own
/// features that aren't core to it sit among the installed extensions' pages, sorted by title (SPEC-159).
/// `SettingsView` only draws the two lists, and `SettingsModel` keeps a page selected only while it's listed.
public enum SettingsSidebar {
    /// One row: the page's tag, which the sidebar selects; its title; and its SF Symbol, which only the top rows have.
    public struct Entry: Sendable, Equatable {
        public let tag: String
        public let title: String
        public let symbol: String?

        public init(tag: String, title: String, symbol: String? = nil) {
            self.tag = tag
            self.title = title
            self.symbol = symbol
        }
    }

    // Fudge's own pages are tagged with a leading ":", which no extension id can have, so no extension takes one.
    public static let generalPage = ":general"
    public static let permissionsPage = ":permissions"
    public static let notificationsPage = ":notifications"
    public static let commandsPage = ":commands"
    public static let signInPage = ":sign-in"
    public static let developmentPage = ":development"
    public static let calculatorPage = ":calculator"
    public static let calendarPage = ":calendar"
    public static let colorPickerPage = ":color-picker"
    public static let quicklinksPage = ":quicklinks"
    public static let snippetsPage = ":snippets"
    public static let windowManagementPage = ":window-management"

    /// The pages on top, core to Fudge, in this order.
    public static let top: [Entry] = [
        Entry(tag: generalPage, title: "General", symbol: "gearshape"),
        Entry(tag: permissionsPage, title: "Permissions", symbol: "hand.raised"),
        Entry(tag: notificationsPage, title: "Notifications", symbol: "bell"),
        Entry(tag: commandsPage, title: "Commands", symbol: "command"),
        Entry(tag: signInPage, title: "Sign-in", symbol: "person.badge.key"),
        Entry(tag: developmentPage, title: "Development", symbol: "hammer"),
    ]

    /// Fudge's own pages under Extensions, drawn like the extensions' rows: the title only.
    public static let builtInExtensions: [Entry] = [
        Entry(tag: calculatorPage, title: "Calculator"),
        Entry(tag: calendarPage, title: "Calendar"),
        Entry(tag: colorPickerPage, title: "Color Picker"),
        Entry(tag: quicklinksPage, title: "Quicklinks"),
        Entry(tag: snippetsPage, title: "Snippets"),
        Entry(tag: windowManagementPage, title: "Window Management"),
    ]

    /// Every page of Fudge's own, on top or under Extensions.
    public static var fixedTags: Set<String> { Set((top + builtInExtensions).map(\.tag)) }

    /// The page an installed extension's row selects: its id (FUD-183), which Configure Extension and
    /// `openExtensionPreferences()` open the window on too, so two extensions of one name have a page each.
    public static func tag(of installed: InstalledExtension) -> String { installed.id.key }

    /// An installed extension's row title, so no two rows look the same: a development build's and an added
    /// repository's say where they're from (`displayTitle`), and one from Raycast's official repository is followed
    /// by " (installed)" when it's exactly the title of one of Fudge's own pages under Extensions (the Extension Store
    /// has a "Color Picker"). Never both.
    public static func title(of installed: InstalledExtension) -> String {
        switch installed.repository {
        case .development, .added: return installed.displayTitle
        case .raycast, .bundled:
            let title = installed.manifest.title
            return builtInExtensions.contains { sameTitle($0.title, title) } ? title + " (installed)" : title
        }
    }

    /// The Extensions section: Fudge's own pages there and `pages` (`InstalledExtension.settingsPages`), one list
    /// sorted by title, without the suffix, as `InstalledExtension.all` sorts the extensions. Rows with the same title
    /// have a fixed order, so it never changes between reloads: Fudge's own page first, by rule, since an extension's
    /// tag can start with a digit and sort before ":"; then the extensions by tag.
    public static func extensions(_ pages: [InstalledExtension]) -> [Entry] {
        let rows =
            builtInExtensions.map { (entry: $0, sortTitle: $0.title, own: true) }
            + pages.map {
                (entry: Entry(tag: tag(of: $0), title: title(of: $0)), sortTitle: $0.manifest.title, own: false)
            }
        return rows.sorted { first, second in
            switch first.sortTitle.localizedStandardCompare(second.sortTitle) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.own != second.own ? first.own : first.entry.tag < second.entry.tag
            }
        }.map(\.entry)
    }

    /// Two titles `localizedStandardCompare` ties, which it does only for the same text: "color picker" is another
    /// title than "Color Picker".
    static func sameTitle(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedSame
    }

    /// Whether `tag` is a page the sidebar lists, so it can stay selected: one of Fudge's own, or one of `pages`.
    public static func lists(_ tag: String?, among pages: [InstalledExtension]) -> Bool {
        guard let tag else { return false }
        return fixedTags.contains(tag) || pages.contains { self.tag(of: $0) == tag }
    }
}
