import Foundation

/// A snippet's text, read into text and placeholders, and filled in when it's pasted or copied (SPEC-078 §2). It
/// shares `QuicklinkTemplate`'s parser, in snippet mode:
///
/// - Dynamic values: `{clipboard}`, `{uuid}`, `{date}`, `{time}`, `{datetime}` and `{day}` (the day of the week);
///   `{date}`, `{time}` and `{datetime}` can take a `format="…"`, a Unicode date pattern.
/// - `{cursor}`, at most once: where the caret ends up after pasting.
/// - Modifiers after `|`: `uppercase`, `lowercase`, `trim` (`raw` and `percent-encode` change nothing here).
///
/// Nothing is encoded. Only those names are placeholders, wherever they sit, as in Raycast; any other text in braces
/// is the snippet's own (FUD-130). A snippet has no fields, so `{argument}` is a `problem`, as are Raycast's other
/// names Fudge can't fill, a name used wrongly, and a second `{cursor}`.
public struct SnippetTemplate: Sendable, Equatable {
    private let template: QuicklinkTemplate

    public var text: String { template.link }
    public var segments: [QuicklinkTemplate.Segment] { template.segments }
    /// What's wrong with the text, naming the placeholder; nil when it's fine.
    public let problem: String?

    public init(_ text: String) {
        template = QuicklinkTemplate(text, mode: .snippet)
        let cursors = template.segments.filter {
            if case .placeholder(let placeholder) = $0 { return placeholder.value == .dynamic(.cursor) }
            return false
        }.count
        problem = template.problem ?? (cursors > 1 ? "A snippet can have only one {cursor}." : nil)
    }

    /// The most ← presses that place `{cursor}`. Further from the end than this, the caret stays at the end of the
    /// pasted text: a long snippet would otherwise have Fudge post tens of thousands of key presses.
    public static let leftArrowLimit = 2_000

    /// How many ← presses put the caret where `{cursor}` was, after pasting: one per character after it, or none
    /// without a `{cursor}` or past `leftArrowLimit`.
    public static func leftArrows(afterCursor: Int?) -> Int {
        guard let afterCursor, afterCursor <= leftArrowLimit else { return 0 }
        return afterCursor
    }

    /// Whether it uses `{clipboard}`, so filling it reads the clipboard only then.
    public var usesClipboard: Bool { template.usesClipboard }

    /// The text filled in, and how many characters follow `{cursor}` (grapheme clusters, so one ← each), or nil
    /// when there's no `{cursor}`.
    public func fill(context: QuicklinkTemplate.Context) -> (text: String, afterCursor: Int?) {
        var before = ""
        var after: String?
        for segment in segments {
            var piece = ""
            switch segment {
            case .text(let text):
                piece = text
            case .placeholder(let placeholder):
                if placeholder.value == .dynamic(.cursor) {
                    after = ""
                    continue
                }
                piece = template.raw(placeholder.value, values: [:], context: context, format: placeholder.format)
                for modifier in placeholder.modifiers {
                    switch modifier {
                    case .uppercase: piece = piece.uppercased()
                    case .lowercase: piece = piece.lowercased()
                    case .trim: piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .raw, .percentEncode: break
                    }
                }
            }
            if after != nil { after! += piece } else { before += piece }
        }
        guard let after else { return (before, nil) }
        return (before + after, after.count)
    }
}
