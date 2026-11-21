import Foundation
import Testing

@testable import FudgeCore

private let license = URL(fileURLWithPath: "/Applications/Fudge.app/Contents/Resources/LICENSE.txt")
private let notices = URL(fileURLWithPath: "/Applications/Fudge.app/Contents/Resources/Third-Party Notices.txt")

@Test func aboutGivesTheLicenseNoticeAndLinksToTheSourceTheLicenseAndTheNotices() {
    let credits = AboutFudge.credits(describe: "v0.3.0", license: license, notices: notices)
    #expect(credits.hasPrefix(AboutFudge.notice + "\n\n"))
    #expect(AboutFudge.notice.contains("GNU Affero General Public License, version 3 or later"))
    #expect(AboutFudge.notice.contains("no warranty"))
    #expect(credits.contains("[Source code](https://github.com/jakeobsen/fudge/tree/v0.3.0)"))
    #expect(credits.contains("[License](file:///Applications/Fudge.app/Contents/Resources/LICENSE.txt)"))
    #expect(
        credits.contains(
            "[Third-party notices](file:///Applications/Fudge.app/Contents/Resources/Third-Party%20Notices.txt)"),
        "the space is encoded, so the Markdown link holds")
    // Each link reads back as a link to its file.
    let parsed = try? AttributedString(markdown: credits)
    let targets = parsed.map { text in text.runs.compactMap { $0.link } } ?? []
    #expect(targets == [URL(string: "https://github.com/jakeobsen/fudge/tree/v0.3.0")!, license, notices])
}

@Test func aboutLinksTheSourceAtTheTagOnlyForAReleaseBuild() {
    #expect(AboutFudge.sourceURL(describe: "v0.3.0").absoluteString == "https://github.com/jakeobsen/fudge/tree/v0.3.0")
    #expect(AboutFudge.sourceURL(describe: "v1.2.0-rc.1").absoluteString.hasSuffix("/tree/v1.2.0-rc.1"))
    for describe in ["v0.3.0-14-ga539cdd", "v0.3.0-dirty", "a539cdd", "dev", ""] {
        #expect(AboutFudge.sourceURL(describe: describe) == AboutFudge.source, "\(describe)")
    }
}

@Test func aFileTheAppDoesntHaveIsLeftOut() {
    let credits = AboutFudge.credits(describe: "dev", license: nil, notices: nil)
    #expect(credits.hasSuffix("[Source code](https://github.com/jakeobsen/fudge)"))
}

@Test func theCopyrightIsTheInfoPlists() throws {
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("App/Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(info?["NSHumanReadableCopyright"] as? String == AboutFudge.copyright)
}

@Test func escAndCommandWAndQCloseTheAboutPanel() {
    #expect(AboutFudge.closesPanel(KeyShortcut(key: "escape", modifiers: [])))
    #expect(AboutFudge.closesPanel(KeyShortcut(key: "w", modifiers: ["cmd"])))
    #expect(AboutFudge.closesPanel(KeyShortcut(key: "q", modifiers: ["cmd"])))
    #expect(!AboutFudge.closesPanel(KeyShortcut(key: "escape", modifiers: ["shift"])))
    #expect(!AboutFudge.closesPanel(KeyShortcut(key: "c", modifiers: ["cmd"])), "copying a link's text stays")
}
