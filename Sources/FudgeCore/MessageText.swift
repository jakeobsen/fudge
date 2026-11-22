import Foundation

/// Joins the two parts of a message Fudge shows, such as a HUD's "Can't open Notes: The file isn't there." (SPEC-152).
///
/// Fudge's text has no em dash, so the parts are joined with a colon, or with a space after a first part that already
/// ends a sentence or a clause, so it never reads "Done.: …".
public enum MessageText {
    /// The endings after which the second part follows a space instead of a colon.
    public static let endings: Set<Character> = [".", ":", "!", "?", "…"]

    /// `first` and `second` joined: "<first>: <second>", or "<first> <second>" when `first` ends in one of
    /// ``endings``.
    ///
    /// Each part is trimmed of the whitespace around it, and a part that's missing or empty is left out, so a toast with
    /// no title shows only its message, never ": message".
    public static func joined(_ first: String?, _ second: String?) -> String {
        let parts = [first, second].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count == 2 else { return parts.first ?? "" }
        let separator = parts[0].last.map(endings.contains) == true ? " " : ": "
        return parts[0] + separator + parts[1]
    }
}
