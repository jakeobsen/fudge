import Foundation

/// What About Fudge shows (SPEC-113 §3), the "Appropriate Legal Notices" of the GPL family (v3 §0, §5(d)): the
/// copyright, that Fudge comes with no warranty and may be shared and changed under the AGPL, and where its license and
/// source are, with the third-party notices beside them.
public enum AboutFudge {
    /// `NSHumanReadableCopyright` in App/Info.plist, which the standard About panel shows under the version.
    public static let copyright = "Copyright © 2026 Morten Jakobsen."
    public static let source = URL(string: "https://github.com/jakeobsen/fudge")!

    /// The license notice, every line of the panel's credits but the links.
    public static let notice =
        "Fudge is free software: you can share and change it under the GNU Affero General Public License, version 3 "
        + "or later. It comes with no warranty."

    /// The panel's credits as Markdown: the notice, then links to the source (at the build's tag when it's exactly one,
    /// `describe` being `FudgeVersion.describe`), Fudge's license and the third-party notices, those two being the
    /// files in the app; a file that isn't there is left out.
    public static func credits(describe: String, license: URL?, notices: URL?) -> String {
        var links = ["[Source code](\(sourceURL(describe: describe).absoluteString))"]
        if let license { links.append("[License](\(license.absoluteString))") }
        if let notices { links.append("[Third-party notices](\(notices.absoluteString))") }
        return notice + "\n\n" + links.joined(separator: " · ")
    }

    /// The source at the build's tag when the build is exactly one (`v0.3.0`), else the repository.
    public static func sourceURL(describe: String) -> URL {
        let tag = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.hasPrefix("v"), FudgeVersion.display(describe: tag) == String(tag.dropFirst()),
            let url = URL(string: "\(source.absoluteString)/tree/\(tag)")
        else { return source }
        return url
    }

    /// Esc, ⌘W and ⌘Q close the About panel, as they close Fudge's other windows; an accessory app has no File menu
    /// to do it.
    public static func closesPanel(_ pressed: KeyShortcut) -> Bool {
        pressed == KeyShortcut(key: "escape", modifiers: []) || WindowShortcut.closesWindow(pressed, recording: false)
    }
}
