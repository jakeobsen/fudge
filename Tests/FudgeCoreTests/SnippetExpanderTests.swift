import Foundation
import Testing

@testable import FudgeCore

private let snippets = [
    Snippet(id: "addr", name: "Address", text: "1 Main St", keyword: ";addr"),
    Snippet(id: "sig", name: "Signature", text: "Best", keyword: "sig!"),
    Snippet(id: "plain", name: "No keyword", text: "x"),
]

/// A key that types `character`, as the tap reads it (the key code doesn't matter for typed text).
private func key(_ character: Character) -> SnippetKeyEvent {
    SnippetKeyEvent(keyCode: 0, characters: String(character))
}

private let leftArrow = SnippetKeyEvent(keyCode: 123, characters: "\u{F702}")
private let delete = SnippetKeyEvent(keyCode: 51, characters: "\u{7F}")

/// Types `text` one key at a time; returns every output.
private func type(
    _ text: String, into expander: inout SnippetExpander, secureInput: Bool = false, fudgeInFront: Bool = false
) -> [SnippetExpander.Output] {
    text.compactMap { expander.handle(key($0), secureInput: secureInput, fudgeInFront: fudgeInFront) }
}

@Test func typingAKeywordAsksToExpandItsSnippet() {
    var expander = SnippetExpander(snippets: snippets)
    #expect(expander.hasKeywords)
    #expect(type("Send it to ;add", into: &expander).isEmpty)
    #expect(type("r", into: &expander) == [.expand(snippetID: "addr")])
    // The buffer starts over after an expansion: the same keyword needs typing again.
    #expect(type("r", into: &expander).isEmpty)
    #expect(type("ok sig!", into: &expander) == [.expand(snippetID: "sig")])
    #expect(type(";ADDR", into: &expander).isEmpty, "a keyword is matched as it's written")
}

@Test func deleteTakesBackATypedCharacter() {
    var expander = SnippetExpander(snippets: snippets)
    _ = type(";adx", into: &expander)
    #expect(expander.handle(delete, secureInput: false, fudgeInFront: false) == nil)
    #expect(type("dr", into: &expander) == [.expand(snippetID: "addr")])
    // ⌥⌫ deletes a word, which the buffer can't follow, so it starts over.
    _ = type(";add", into: &expander)
    let optionDelete = SnippetKeyEvent(keyCode: 51, characters: "\u{7F}", option: true)
    #expect(expander.handle(optionDelete, secureInput: false, fudgeInFront: false) == nil)
    #expect(type("r", into: &expander).isEmpty)
}

@Test func everyResetClearsWhatWasTyped() {
    let resets: [(String, (inout SnippetExpander) -> Void)] = [
        ("a click", { $0.reset(.click) }),
        ("an app switch", { $0.reset(.appSwitch) }),
        ("switching it off", { $0.reset(.switchedOff) }),
        ("Input Monitoring revoked", { $0.reset(.permissionRevoked) }),
        ("the snippets changing", { $0.setSnippets(snippets) }),
        ("←", { _ = $0.handle(leftArrow, secureInput: false, fudgeInFront: false) }),
        (
            "↵",
            { _ = $0.handle(SnippetKeyEvent(keyCode: 36, characters: "\r"), secureInput: false, fudgeInFront: false) }
        ),
        (
            "Tab",
            { _ = $0.handle(SnippetKeyEvent(keyCode: 48, characters: "\t"), secureInput: false, fudgeInFront: false) }
        ),
        (
            "F5",
            {
                _ = $0.handle(
                    SnippetKeyEvent(keyCode: 96, characters: "\u{F708}"), secureInput: false, fudgeInFront: false)
            }
        ),
        (
            "⌘V",
            {
                _ = $0.handle(
                    SnippetKeyEvent(keyCode: 9, characters: "v", command: true), secureInput: false, fudgeInFront: false
                )
            }
        ),
        (
            "⌃A",
            {
                _ = $0.handle(
                    SnippetKeyEvent(keyCode: 0, characters: "\u{1}", control: true), secureInput: false,
                    fudgeInFront: false)
            }
        ),
        ("secure input", { _ = $0.handle(key("x"), secureInput: true, fudgeInFront: false) }),
        ("Fudge's own window", { _ = $0.handle(key("x"), secureInput: false, fudgeInFront: true) }),
    ]
    for (name, reset) in resets {
        var expander = SnippetExpander(snippets: snippets)
        _ = type(";add", into: &expander)
        reset(&expander)
        #expect(type("r", into: &expander).isEmpty, "\(name) starts the buffer over")
        #expect(type(";addr", into: &expander) == [.expand(snippetID: "addr")], "and typing works again after \(name)")
    }
}

@Test func nothingIsKeptOrExpandedUnderSecureInputOrInFudge() {
    var expander = SnippetExpander(snippets: snippets)
    #expect(type(";addr", into: &expander, secureInput: true).isEmpty, "a password field")
    #expect(type(";addr", into: &expander, fudgeInFront: true).isEmpty, "Fudge's own windows")
    // Half typed in a password field, finished outside it: nothing from the password field was kept.
    _ = type(";ad", into: &expander, secureInput: true)
    #expect(type("dr", into: &expander).isEmpty)
}

@Test func fudgesOwnKeysAreIgnored() {
    var expander = SnippetExpander(snippets: snippets)
    _ = type(";add", into: &expander)
    // Fudge's own ⌫ and ← (an expansion's) don't change the buffer, and don't reset it either.
    for event in [delete, leftArrow, SnippetKeyEvent(keyCode: 9, characters: "v", command: true)] {
        var marked = event
        marked.sourceUserData = SnippetExpander.marker
        #expect(expander.handle(marked, secureInput: false, fudgeInFront: false) == nil)
    }
    var markedR = key("r")
    markedR.sourceUserData = SnippetExpander.marker
    #expect(expander.handle(markedR, secureInput: false, fudgeInFront: false) == nil, "a marked key is never typing")
    #expect(type("r", into: &expander) == [.expand(snippetID: "addr")])
}

@Test func keywordsThatContainAnotherNeverExpand() {
    // Only a hand-edited snippets.json can hold these: the form refuses them (MUST 1).
    let clashing = [
        Snippet(id: "dt", name: "A", text: "a", keyword: "dt"),
        Snippet(id: "adtb", name: "B", text: "b", keyword: "adtb"),
        Snippet(id: "xdt", name: "C", text: "c", keyword: "XDT"),
        Snippet(id: "ok", name: "D", text: "d", keyword: "ok;"),
    ]
    var expander = SnippetExpander(snippets: clashing)
    #expect(type("adtb dt XDT", into: &expander).isEmpty, "inside, prefix or suffix, ignoring case: neither expands")
    #expect(type("ok;", into: &expander) == [.expand(snippetID: "ok")])
}

@Test func theBufferKeepsOnlyTheLongestKeywordsWorth() {
    let long = String(repeating: "k", count: 31) + "!"
    var expander = SnippetExpander(snippets: [Snippet(id: "long", name: "Long", text: "x", keyword: long)])
    #expect(type(String(repeating: "z", count: 200) + long, into: &expander) == [.expand(snippetID: "long")])
    // A dead key types nothing yet; the composed character comes with the next key.
    #expect(
        expander.handle(SnippetKeyEvent(keyCode: 32, characters: ""), secureInput: false, fudgeInFront: false) == nil)
    var accents = SnippetExpander(snippets: [Snippet(id: "cafe", name: "Café", text: "x", keyword: "café")])
    #expect(type("café", into: &accents) == [.expand(snippetID: "cafe")])
}

@Test func whatsTypedNeverLeavesTheExpander() {
    // The reviewer's MUST 2: outputs name a snippet and nothing else, and printing or dumping the expander shows
    // nothing typed.
    let secret = "hunter2-correct-horse"
    var expander = SnippetExpander(snippets: snippets)
    var outputs = type(secret + " ;addr", into: &expander)
    _ = type(secret, into: &expander)
    outputs += type(";add", into: &expander)
    #expect(outputs == [.expand(snippetID: "addr")])
    #expect(outputs.map(\.description) == ["expand snippet addr"])
    var dumped = ""
    dump(expander, to: &dumped)
    for text in [String(describing: expander), String(reflecting: expander), dumped] {
        #expect(!text.contains("hunter") && !text.contains("horse") && !text.contains(";add"), "\(text)")
    }
    #expect(Mirror(reflecting: expander).children.isEmpty)
}

@Test func expandingAsYouTypeIsOffUntilSwitchedOn() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    #expect(!FudgeSettings.load(from: file).expandSnippets)
    var settings = FudgeSettings()
    settings.expandSnippets = true
    try settings.save(to: file)
    #expect(try String(contentsOf: file, encoding: .utf8).contains(#""expandSnippets" : true"#))
    #expect(FudgeSettings.load(from: file).expandSnippets)
    settings.expandSnippets = false
    try settings.save(to: file)
    #expect(
        !(try String(contentsOf: file, encoding: .utf8)).contains("expandSnippets"), "off is the default, not written")
}
