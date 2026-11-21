import Foundation

/// A snippet's text, read into text and placeholders, and filled in when it's pasted or copied (SPEC-078 §2). It
/// shares `QuicklinkTemplate`'s parser, in snippet mode:
///
/// - Dynamic values: `{clipboard}`, `{uuid}`, `{date}`, `{time}`, `{datetime}` and `{day}` (the day of the week).
/// - `{cursor}`, at most once: where the caret ends up after pasting.
/// - Modifiers after `|`: `uppercase`, `lowercase`, `trim` (`raw` and `percent-encode` change nothing here).
///
/// Nothing is encoded. A snippet has no fields, so arguments and any other word in braces are a `problem`.
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
                piece = template.raw(placeholder.value, values: [:], context: context)
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
