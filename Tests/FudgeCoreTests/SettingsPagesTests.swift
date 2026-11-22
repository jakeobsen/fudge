import Testing

@testable import FudgeCore

@Test func aReloadKeepsEveryPageOfFudgesOwnTheNotificationsPageIncluded() {
    #expect(SettingsPages.notificationsPage == ":notifications")
    #expect(SettingsPages.fixedTags.count == 11)
    for tag in SettingsPages.fixedTags {
        #expect(tag.hasPrefix(":"), "\(tag)")
        #expect(SettingsPages.keeps(tag, extensionNames: []), "\(tag)")
    }
    #expect(SettingsPages.keeps(SettingsPages.notificationsPage, extensionNames: ["github"]))
}

@Test func aReloadKeepsAnInstalledExtensionsPageAndNothingElse() {
    #expect(SettingsPages.keeps("github", extensionNames: ["github", "linear"]))
    #expect(!SettingsPages.keeps("github", extensionNames: ["linear"]), "removed while its page was open")
    #expect(!SettingsPages.keeps(":nothing", extensionNames: []))
    #expect(!SettingsPages.keeps(nil, extensionNames: ["github"]))
}
