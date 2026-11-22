import Foundation
import Testing

@testable import FudgeCore

// Every definition here is made up for these tests, in the shape Dictionary Services gives: the headword, the
// pronunciation between bars, then the parts of speech, numbered senses, `•` sub-senses and sections.

// MARK: - The word

@Test func theWordIsTheFirstLineThatIsntBlankTrimmedAndCut() {
    #expect(DefineWord.word(from: "  serendipity  ") == "serendipity")
    #expect(DefineWord.word(from: "\n  \n ice cream \nand more lines\nof a page") == "ice cream")
    #expect(DefineWord.word(from: "line one\r\nline two") == "line one")
    let page = String(repeating: "long ", count: 100)
    #expect(DefineWord.word(from: page)?.count == DefineWord.wordLimit - 1, "cut to 100, then trimmed")
    #expect(DefineWord.wordLimit == 100)
    #expect(DefineWord.word(from: " \n\t ") == nil)
    #expect(DefineWord.word(from: "") == nil)
    #expect(DefineWord.word(from: nil) == nil)
}

private actor SelectionReads {
    var count = 0
    func read(_ text: String?) -> String? {
        count += 1
        return text
    }
}

@Test func aTypedWordIsLookedUpWithoutReadingTheSelection() async {
    let reads = SelectionReads()
    let start = await DefineWord.start(argument: " ephemeral ") { await reads.read("selected") }
    #expect(start == .lookUp("ephemeral"))
    #expect(await reads.count == 0)
}

@Test func withNothingTypedTheSelectionIsLookedUp() async {
    let reads = SelectionReads()
    let start = await DefineWord.start(argument: "  ") { await reads.read("quixotic\nthe rest of the page") }
    #expect(start == .lookUp("quixotic"))
    #expect(await reads.count == 1)
}

@Test func withNothingTypedOrSelectedItAsksForAWord() async {
    #expect(await DefineWord.start(argument: "") { nil } == .askForWord)
    #expect(await DefineWord.start(argument: "") { "  \n " } == .askForWord)
}

@Test func dictionaryLinksArePercentEncodedAndCut() throws {
    #expect(DefineWord.dictionaryURL(for: "serendipity")?.absoluteString == "dict://serendipity")
    #expect(DefineWord.dictionaryURL(for: "ice cream")?.absoluteString == "dict://ice%20cream")
    #expect(DefineWord.dictionaryURL(for: "café")?.absoluteString == "dict://caf%C3%A9")
    #expect(DefineWord.dictionaryURL(for: "a/b?c#d&e")?.absoluteString == "dict://a%2Fb%3Fc%23d%26e")
    #expect(DefineWord.dictionaryURL(for: "re-do_it.now~")?.absoluteString == "dict://re-do_it.now~")
    let long = try #require(DefineWord.dictionaryURL(for: String(repeating: "x", count: 500)))
    #expect(long.absoluteString == "dict://" + String(repeating: "x", count: 100))
    #expect(DefineWord.dictionaryURL(for: "") == nil)
}

// MARK: - Formatting

@Test func numberedSensesAndSectionsGetTheirOwnLines() {
    let text =
        "glimmerwort | ˈɡlɪmərˌwɔːrt | noun 1 a small plant whose leaves shine faintly at dusk. "
        + "2 informal a person who is quietly cheerful. ORIGIN early 21st century: made up for a test."
    #expect(
        DefinitionText.markdown(word: "glimmerwort", text: text)
            == """
            # glimmerwort

            \\| ˈɡlɪmərˌwɔːrt \\|

            *noun*

            **1** a small plant whose leaves shine faintly at dusk\\.

            **2** informal a person who is quietly cheerful\\.

            **ORIGIN** early 21st century\\: made up for a test\\.
            """)
}

@Test func anUnnumberedDefinitionHasItsPartOfSpeechOnItsOwnLine() {
    let text = "plinth-cat | ˈplɪnθ kat | adjective sitting very still, as if on a pedestal: the dog sat plinth-cat."
    #expect(
        DefinitionText.markdown(word: "plinth-cat", text: text)
            == """
            # plinth\\-cat

            \\| ˈplɪnθ kat \\|

            *adjective*

            sitting very still, as if on a pedestal\\: the dog sat plinth\\-cat\\.
            """)
}

@Test func senseNumbersStartOverAtANewPartOfSpeechAndBulletsSplit() {
    let text =
        "fernwhistle | ˈfɜːnˌwɪsəl | noun 1 a reed pipe cut from a fern stem. 2 the sound one makes. "
        + "verb 1 play such a pipe. • whistle softly, as wind through ferns. 2 make up a test definition. "
        + "PHRASAL VERBS fernwhistle away spend time idly."
    let blocks = Markdown.blocks(DefinitionText.markdown(word: "fernwhistle", text: text))
    #expect(
        blocks == [
            .heading(level: 1, text: "fernwhistle"),
            .paragraph("\\| ˈfɜːnˌwɪsəl \\|"),
            .paragraph("*noun*"),
            .paragraph("**1** a reed pipe cut from a fern stem\\."),
            .paragraph("**2** the sound one makes\\."),
            .paragraph("*verb*"),
            .paragraph("**1** play such a pipe\\."),
            .paragraph("• whistle softly, as wind through ferns\\."),
            .paragraph("**2** make up a test definition\\."),
            .paragraph("**PHRASAL VERBS** fernwhistle away spend time idly\\."),
        ])
}

@Test func numbersInsideASenseStayInIt() {
    let text = "dawdlewick | ˈdɔːdlwɪk | noun 1 a candle that burns for about 3 hours, or 1 night. 2 a slow person."
    let blocks = Markdown.blocks(DefinitionText.markdown(word: "dawdlewick", text: text))
    #expect(blocks.contains(.paragraph("**1** a candle that burns for about 3 hours, or 1 night\\.")))
    #expect(blocks.contains(.paragraph("**2** a slow person\\.")))
    #expect(blocks.count == 5)
}

@Test func withoutAPronunciationTheWordIsTheHeading() {
    #expect(
        DefinitionText.markdown(word: "Zork", text: "A made-up name used in tests.")
            == "# Zork\n\nA made\\-up name used in tests\\.")
}

@Test func nothingFromTheDictionaryIsReadAsMarkdown() {
    let text =
        "odd | ɒd | noun # not a heading - not a list 1. not numbered [not](a link) *not em* `no code` > no quote"
    let markdown = DefinitionText.markdown(word: "odd", text: text)
    let blocks = Markdown.blocks(markdown)
    #expect(blocks.first == .heading(level: 1, text: "odd"))
    #expect(blocks.dropFirst().allSatisfy { if case .paragraph = $0 { true } else { false } })
    #expect(markdown.contains("\\# not a heading \\- not a list 1\\. not numbered \\[not\\]\\(a link\\) \\*not em\\*"))
    #expect(markdown.contains("\\`no code\\` \\> no quote"))
    #expect(DefinitionText.escaped("a\\b") == "a\\\\b")
}

/// What `MarkdownView` draws of `text` once it's escaped: its characters, and whether any of it is formatted or linked.
private func drawn(_ text: String) -> (text: String, formatted: Bool) {
    let drawn = Markdown.inline(DefinitionText.escaped(text))
    return (String(drawn.characters), drawn.runs.contains { $0.inlinePresentationIntent != nil || $0.link != nil })
}

@Test func markdownWithCombiningOrPrependedMarksIsDrawnAsItIs() {
    let shapes = [
        // A combining mark after the punctuation: one Character, but Markdown still reads the `*`.
        "*\u{0301}word*\u{0301}", "**\u{0301}word**\u{0301}", "_\u{0301}word_\u{0301}",
        "`\u{0301}code`\u{0301}", "~\u{0301}~\u{0301}gone~\u{0301}~\u{0301}",
        // A prepended mark takes the backslash after it into its Character; escaped per character, the backslash
        // cancelled the escape after it, and two of them drew the text in italics.
        "\u{0600}\\*x*", "\u{0600}\\*x\u{0600}\\*",
        // Links, images, autolinks and entities stay text too.
        "[a](https://example.com)", "![a](https://example.com/a.png)", "[\u{0301}a](https://example.com)",
        "<https://example.com>", "see https://example.com/a.b", "&amp; &lt;b&gt;", "a\\b",
    ]
    for shape in shapes {
        let (text, formatted) = drawn(shape)
        #expect(text == shape, "drawn as it is: \(shape.debugDescription)")
        #expect(!formatted, "nothing formatted or linked: \(shape.debugDescription)")
    }
}

@Test func aCraftedHeadwordOrWordIsDrawnAsItIs() throws {
    let crafted = "*\u{0301}x*\u{0301}"
    let markdown = DefinitionText.markdown(word: "x", text: "\(crafted) | x | noun a thing.")
    guard case .heading(level: 1, let heading) = Markdown.blocks(markdown).first else {
        Issue.record("no heading in \(markdown.debugDescription)")
        return
    }
    #expect(String(Markdown.inline(heading).characters) == crafted)
    #expect(!Markdown.inline(heading).runs.contains { $0.inlinePresentationIntent != nil })

    // With no definition, the word the user typed or selected is in the heading.
    let missing = try #require(DefineWordView.view(word: crafted, definition: nil).string("markdown"))
    guard case .heading(_, let title) = Markdown.blocks(missing).first else {
        Issue.record("no heading in \(missing.debugDescription)")
        return
    }
    #expect(String(Markdown.inline(title).characters) == "No definition for “\(crafted)”")
    #expect(!Markdown.inline(title).runs.contains { $0.inlinePresentationIntent != nil })
}

// MARK: - The view

@Test func theDefinitionShowsWithLookUpAndCopy() throws {
    let view = DefineWordView.view(word: "plinth-cat", definition: "plinth-cat | ˈplɪnθ kat | adjective very still.")
    #expect(view.type == "Detail")
    #expect(view.string("navigationTitle") == "Define Word")
    #expect(view.string("markdown")?.hasPrefix("# plinth\\-cat\n\n") == true)
    let entries = ActionPanelReader.sections(of: view.node("actions")).flatMap(\.entries)
    #expect(entries.map(\.title) == ["Look Up in Dictionary", "Copy Definition"], "↵ looks it up, ⌘↵ copies")
    #expect(entries.map(\.shortcut) == [DefineWordView.lookUpShortcut, nil])
    #expect(DefineWordView.lookUpShortcut == KeyShortcut(key: "d", modifiers: ["cmd"]))
    let targets = entries.map { entry -> DefineWordView.Target? in
        guard case .node(let node) = entry.target else { return nil }
        return DefineWordView.target(of: node)
    }
    #expect(targets == [.lookUpInDictionary, .copyDefinition])
    #expect(DefineWordView.target(of: view.id) == nil)
}

@Test func noDefinitionSaysSoAndOffersOnlyLookUp() {
    let view = DefineWordView.view(word: "zzyzx*", definition: nil)
    #expect(view.string("markdown") == "## No definition for “zzyzx\\*”")
    let entries = ActionPanelReader.sections(of: view.node("actions")).flatMap(\.entries)
    #expect(entries.map(\.title) == ["Look Up in Dictionary"])
}

@Test func fixedDefinitionsIgnoreCaseAndLoadFromAFile() async throws {
    let lookup = FixedDefinitions(["Ephemeral": "ephemeral | made up"])
    #expect(await lookup.definition(of: "EPHEMERAL") == "ephemeral | made up")
    #expect(await lookup.definition(of: "other") == nil)
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("definitions.json")
    try #"{"glimmerwort":"glimmerwort | made up"}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(await FixedDefinitions.load(file).definition(of: "glimmerwort") == "glimmerwort | made up")
    #expect(await FixedDefinitions.load(file.appendingPathExtension("missing")).definition(of: "glimmerwort") == nil)
}

// MARK: - Root search

private let defineWordID = ":tools/define-word"

/// Root search's command items as `applySettings` gives them: Fudge's own, and two made up, one with an argument,
/// under the System group's key, since a group's key is one of a closed list (`BuiltInGroup`).
private func items(_ settings: FudgeSettings = FudgeSettings()) -> [RootItem] {
    let madeUp = [
        RootItem(
            id: "command::system/search", title: "Search", kind: .builtInCommand(group: .system, command: "search"),
            arguments: [DefineWord.argument]),
        RootItem(id: "command::system/plain", title: "Plain", kind: .builtInCommand(group: .system, command: "plain")),
    ]
    return RootSearch.applying(settings, to: BuiltInCommandGroup.all.flatMap(RootItem.builtInCommands) + madeUp)
}

private func settings(aliases: [String: String]) -> FudgeSettings {
    var settings = FudgeSettings()
    for (id, alias) in aliases { settings.commands[id] = .init(alias: alias) }
    return settings
}

@Test func defineWordTakesAWordAndDefineIsItsDefaultAlias() throws {
    #expect(CommandAliases.defaults == [defineWordID: "define"])
    let define = try #require(items().first { $0.title == "Define Word" })
    #expect(define.arguments == [DefineWord.argument])
    #expect(define.arguments.first?.required == false && define.arguments.first?.placeholder == "Word")
    #expect(define.alias == "define", "the default applies while settings.json has none")
    #expect(FudgeSettings().alias(ofCommand: defineWordID) == "define")
    let handed = try #require(CommandAliases.handOff("define serendipity", in: items()))
    #expect(handed.item.title == "Define Word" && handed.rest == "serendipity")
    #expect(CommandAliases.handOff("Define ice cream", in: items())?.rest == "ice cream", "ignoring case")
    #expect(CommandAliases.handOff("definer x", in: items()) == nil)
    #expect(CommandAliases.handOff("define", in: items()) == nil, "no space, no hand-off")
    #expect(
        RootSearch.exactAliasMatch(in: items(), query: "define")?.title == "Define Word",
        "and it ranks as an alias does")
}

@Test func aUsersOwnDefineAliasWinsOverTheDefault() throws {
    let taken = settings(aliases: [":system/search": "define"])
    #expect(taken.alias(ofCommand: defineWordID) == nil, "the default isn't applied")
    #expect(items(taken).first { $0.title == "Define Word" }?.alias == nil)
    #expect(try #require(CommandAliases.handOff("define x", in: items(taken))).item.title == "Search")
    #expect(
        CommandAliases.handOff("define x", in: items(settings(aliases: [":system/plain": "DEFINE"]))) == nil,
        "an alias without arguments hands nothing off, and still takes the word, ignoring case")
    var off = FudgeSettings()
    off.commands[defineWordID] = .init(enabled: false)
    #expect(CommandAliases.handOff("define x", in: items(off)) == nil, "turned off, it isn't in root search")
}

@Test func theDefaultCanBeChangedOrClearedAndStaysCleared() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.setAlias("", ofCommand: defineWordID)
    #expect(settings.commands[defineWordID]?.alias == "", "a cleared default is kept as an empty alias")
    #expect(settings.alias(ofCommand: defineWordID) == nil)
    try settings.save(to: file)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let commands = try #require(object["commands"] as? [String: Any])
    #expect((commands[defineWordID] as? [String: Any])?["alias"] as? String == "")

    // The next launch reads it back: still cleared, so `define` is free.
    let reloaded = FudgeSettings.load(from: file)
    #expect(reloaded.alias(ofCommand: defineWordID) == nil)
    #expect(CommandAliases.handOff("define x", in: items(reloaded)) == nil)
    #expect(items(reloaded).first { $0.title == "Define Word" }?.alias == nil)

    // An alias of the user's own works as `define` did, and `define` no longer does.
    var custom = reloaded
    custom.setAlias("dw", ofCommand: defineWordID)
    #expect(try #require(CommandAliases.handOff("dw glimmerwort", in: items(custom))).item.title == "Define Word")
    #expect(CommandAliases.handOff("define x", in: items(custom)) == nil)

    // Clearing an alias of a command with no default removes it, as before.
    var other = FudgeSettings()
    other.setAlias("s", ofCommand: ":system/search")
    other.setAlias("", ofCommand: ":system/search")
    #expect(other.commands[":system/search"]?.alias == nil)
}

@Test func theDefaultIsNeverWrittenToSettings() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try #"{"hotkey":"option+space","commands":{"a/b":{"alias":"ab"}}}"#.write(
        to: file, atomically: true, encoding: .utf8)
    let loaded = FudgeSettings.load(from: file)
    #expect(loaded.alias(ofCommand: defineWordID) == "define")
    try loaded.save(to: file)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((object["commands"] as? [String: Any])?.keys.sorted() == ["a/b"], "settings that exist aren't changed")
}
