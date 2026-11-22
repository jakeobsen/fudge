import Foundation

/// The Settings window's pages of Fudge's own, by the tag the sidebar selects. They start with ":", which no extension
/// name can have, so no extension's page takes one.
public enum SettingsPages {
    public static let generalPage = ":general"
    public static let commandsPage = ":commands"
    public static let permissionsPage = ":permissions"
    public static let notificationsPage = ":notifications"
    public static let quicklinksPage = ":quicklinks"
    public static let snippetsPage = ":snippets"
    public static let colorPickerPage = ":color-picker"
    public static let windowManagementPage = ":window-management"
    public static let signInPage = ":sign-in"
    public static let calendarPage = ":calendar"
    public static let developmentPage = ":development"

    /// Every page of Fudge's own.
    public static let fixedTags: Set<String> = [
        generalPage, commandsPage, permissionsPage, notificationsPage, quicklinksPage, snippetsPage, colorPickerPage,
        windowManagementPage, signInPage, calendarPage, developmentPage,
    ]

    /// Whether `tag` can stay selected when the window reloads: one of Fudge's own pages, or the page of an installed
    /// extension in `extensionNames`. Anything else gives way to General, so an install while a page of Fudge's own is
    /// open never moves the window off it.
    public static func keeps(_ tag: String?, extensionNames: some Sequence<String>) -> Bool {
        guard let tag else { return false }
        return fixedTags.contains(tag) || extensionNames.contains(tag)
    }
}
