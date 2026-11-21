import Foundation
import Testing

@testable import FudgeCore

/// Saturday, 21 November 2026, 10:00 UTC.
private let context = QuicklinkTemplate.Context(
    clipboard: "copied", now: Date(timeIntervalSince1970: 1_795_255_200), locale: Locale(identifier: "en_US"),
    timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian), makeUUID: { "U-1" })

@Test func aSnippetFillsItsDynamicValuesWithoutEncoding() {
    let template = SnippetTemplate("Hi & bye {clipboard} {uuid} on {day}, {date|uppercase}")
    #expect(template.problem == nil)
    let filled = template.fill(context: context)
    #expect(filled.text.hasPrefix("Hi & bye copied U-1 on Saturday, NOV"), "\(filled.text)")
    #expect(filled.text.contains("2026"))
    #expect(filled.afterCursor == nil)
    #expect(template.usesClipboard)
    #expect(SnippetTemplate("{Day|lowercase}").fill(context: context).text == "saturday", "names ignore case")
}

@Test func cursorMarksWhereTheCaretEndsCountedInCharacters() {
    let template = SnippetTemplate("Dear {cursor}, thanks 👍🏽")
    #expect(template.problem == nil)
    let filled = template.fill(context: context)
    #expect(filled.text == "Dear , thanks 👍🏽")
    #expect(filled.afterCursor == 10, "one ← per character, the emoji with its skin tone counting once")
    #expect(SnippetTemplate("{cursor}").fill(context: context) == ("", 0))
    #expect(SnippetTemplate("a{cursor}b{cursor}").problem == "A snippet can have only one {cursor}.")
}

@Test func aSnippetHasNoFieldsAndRefusesWhatItCantFill() {
    #expect(SnippetTemplate("{argument}").problem == "Fudge doesn't support “{argument}” in a snippet.")
    #expect(SnippetTemplate("{selection}").problem == "Fudge doesn't support “{selection}” in a snippet.")
    #expect(
        SnippetTemplate("{snippet name=\"x\"}").problem == "Fudge doesn't support “{snippet name=\"x\"}” in a snippet.")
    #expect(SnippetTemplate("{date|shout}").problem == "Fudge doesn't know the modifier “shout” in “{date|shout}”.")
    #expect(SnippetTemplate("plain text, no braces").fill(context: context).text == "plain text, no braces")
}

@Test func quicklinksStillRefuseDayAndCursor() {
    #expect(QuicklinkTemplate("https://x.test/{day}").problem == "Fudge doesn't support “{day}” in a quicklink.")
    #expect(QuicklinkTemplate("https://x.test/{cursor}").problem == "Fudge doesn't support “{cursor}” in a quicklink.")
    #expect(QuicklinkTemplate("https://x.test/{q}").arguments.map(\.name) == ["q"], "bare words stay arguments")
}
