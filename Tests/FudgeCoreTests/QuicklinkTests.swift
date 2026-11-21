import Foundation
import Testing

@testable import FudgeCore

// Quicklinks, part A (FUD-86): the store, placeholders, opening, root search and ⌘K.

/// A throwaway support folder, removed when the test ends.
private final class Folder {
    let url: URL
    var file: URL { url.appendingPathComponent("quicklinks.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fudge-quicklinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: file)
    }

    func read() -> String? {
        (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
    }

    func json() -> JSONValue? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

// MARK: - The store

@Test func quicklinksRoundTripThroughTheFile() throws {
    let folder = try Folder()
    var store = QuicklinkStore.load(from: folder.file)
    #expect(store.quicklinks.isEmpty, "a missing file has none")
    #expect(QuicklinkStore.isWritable(folder.file))
    let jira = Quicklink(
        id: "q1", name: "Jira Ticket", link: "https://jira.example.com/browse/{ticket}",
        application: "com.apple.Safari", createdAt: "2026-11-21T10:00:00Z")
    store.add(jira)
    store.add(Quicklink(id: "q2", name: "Downloads", link: "~/Downloads"))
    try store.save(to: folder.file)
    let loaded = QuicklinkStore.load(from: folder.file)
    #expect(loaded.quicklinks.map(\.id) == ["q1", "q2"], "in the order they were added")
    #expect(loaded.quicklink(id: "q1") == jira)
    #expect(loaded.quicklink(id: "q2")?.application == nil)
    #expect(folder.read()?.contains("https://jira.example.com/browse/{ticket}") == true, "slashes written as they are")
}

@Test func theStoreKeepsKeysItDoesntKnowAndEntriesThatArentQuicklinks() throws {
    let folder = try Folder()
    try folder.write(
        #"""
        {"version": 2, "quicklinks": [
          {"id": "q1", "name": "Docs", "link": "https://example.com", "icon": "globe", "tags": ["a"]},
          {"id": "q2", "name": "", "link": "https://example.com/empty-name"},
          {"name": "No Id", "link": "https://example.com"},
          {"id": "q3", "name": "No Link"},
          {"id": "q4", "name": "\#(String(repeating: "n", count: 65))", "link": "https://example.com"},
          "not an object",
          {"id": "q1", "name": "Same Id", "link": "https://example.com/again"},
          {"id": "q5", "name": "Kept", "link": "https://example.com/kept"}
        ]}
        """#)
    var store = QuicklinkStore.load(from: folder.file)
    #expect(store.quicklinks.map(\.name) == ["Docs", "Kept"], "bad entries and a repeated id are skipped")
    store.remove(id: "q5")
    let replaced = store.replace(
        Quicklink(id: "q1", name: "Docs", link: "https://example.com/v2", createdAt: "2026-11-21"))
    #expect(replaced)
    try store.save(to: folder.file)
    guard case .object(let object) = folder.json(), case .array(let entries) = object["quicklinks"] else {
        Issue.record("not a quicklinks file")
        return
    }
    #expect(object["version"] == .number(2), "the file's own keys stay")
    #expect(entries.count == 7, "every entry but the removed one stays, bad ones included")
    guard case .object(let first) = entries[0] else { return }
    #expect(first["icon"] == .string("globe") && first["tags"] == .array([.string("a")]), "unknown keys stay")
    #expect(first["link"] == .string("https://example.com/v2"))
    #expect(entries[5] == .string("not an object"))
}

@Test func anUnreadableFileIsNeverOverwritten() throws {
    for text in ["not json", "[1, 2]", #"{"quicklinks": {"id": "q1"}}"#, #"{"quicklinks": "none"}"#] {
        let folder = try Folder()
        try folder.write(text)
        #expect(QuicklinkStore.load(from: folder.file).quicklinks.isEmpty, "\(text): read as none")
        #expect(!QuicklinkStore.isWritable(folder.file))
        var store = QuicklinkStore.load(from: folder.file)
        store.add(Quicklink(name: "New", link: "https://example.com"))
        #expect(throws: QuicklinkStore.Unreadable()) { try store.save(to: folder.file) }
        #expect(folder.read() == text, "\(text): left as it was")
    }
    let blank = try Folder()
    try blank.write("  \n")
    #expect(QuicklinkStore.isWritable(blank.file), "a blank file is written over")
    #expect(QuicklinkStore.Unreadable().description.contains("quicklinks.json"))
}

@Test func aNameHasOneToSixtyFourCharacters() {
    #expect(Quicklink.isValidName("Jira"))
    #expect(Quicklink.isValidName(String(repeating: "n", count: 64)))
    #expect(!Quicklink.isValidName(String(repeating: "n", count: 65)))
    #expect(!Quicklink.isValidName(""))
    #expect(!Quicklink.isValidName("   "))
}

// MARK: - Placeholders

private func context(clipboard: String? = "copied text") -> QuicklinkTemplate.Context {
    QuicklinkTemplate.Context(
        clipboard: clipboard, now: Date(timeIntervalSince1970: 1_795_000_000), locale: Locale(identifier: "en_US"),
        timeZone: TimeZone(identifier: "Europe/Copenhagen")!, makeUUID: { "11111111-2222-3333-4444-555555555555" })
}

@Test func readsEveryArgumentForm() {
    let unnamed = QuicklinkTemplate(#"https://example.com/{argument}/{argument name="ticket"}/{ticket}"#)
    #expect(unnamed.problem == nil)
    #expect(
        unnamed.arguments == [
            .init(name: "argument", defaultValue: nil, options: []),
            .init(name: "ticket", defaultValue: nil, options: []),
        ], "an unnamed one, and a named one used twice")
    let template = QuicklinkTemplate(
        #"https://example.com/?q={argument name="q" default="news"}&k={argument name="kind" options="bug, task , story,"}"#
    )
    #expect(template.problem == nil)
    #expect(
        template.arguments == [
            .init(name: "q", defaultValue: "news", options: []),
            .init(name: "kind", defaultValue: nil, options: ["bug", "task", "story"]),
        ])

    let fields = unnamed.fields + template.fields
    #expect(fields.map(\.type) == ["text", "text", "text", "dropdown"])
    #expect(fields.map(\.required) == [true, true, false, true], "required unless there's a default")
    #expect(fields.map(\.placeholder) == ["argument", "ticket", "news", "kind"], "the default as the placeholder")
    #expect(fields[3].data?.map(\.value) == ["bug", "task", "story"])
}

@Test func aBareWordIsAnArgumentAndTheSameNameIsOneField() {
    let template = QuicklinkTemplate(
        #"https://www.google.com/search?q={Query}&again={Query}&x={argument name="Query" default="cats"}"#)
    #expect(template.problem == nil)
    #expect(template.arguments == [.init(name: "Query", defaultValue: "cats", options: [])], "one field")
    #expect(
        template.fill(arguments: ["Query": "dogs"], context: context())
            == "https://www.google.com/search?q=dogs&again=dogs&x=dogs")
    #expect(
        template.fill(arguments: [:], context: context())
            == "https://www.google.com/search?q=cats&again=cats&x=cats", "left empty, the default")
}

@Test func atMostThreeArguments() {
    #expect(QuicklinkTemplate("https://e.com/{a}/{b}/{c}").problem == nil)
    #expect(QuicklinkTemplate("https://e.com/{a}/{b}/{c}/{a}").problem == nil, "the same name again is one field")
    #expect(QuicklinkTemplate("https://e.com/{a}/{b}/{c}/{d}").problem == "A quicklink can have at most 3 fields.")
}

@Test func valuesInAURLAreEncodedAsEncodeURIComponentDoes() {
    let template = QuicklinkTemplate("https://example.com/search?q={q}")
    #expect(
        template.fill(arguments: ["q": "a&b=c d/e+f#g"], context: context())
            == "https://example.com/search?q=a%26b%3Dc%20d%2Fe%2Bf%23g")
    #expect(QuicklinkTemplate.encodeURIComponent("AZaz09-_.!~*'()") == "AZaz09-_.!~*'()", "left alone")
    #expect(QuicklinkTemplate.encodeURIComponent("æ ø?") == "%C3%A6%20%C3%B8%3F", "UTF-8, byte by byte")
}

@Test func rawPathsAndALonePlaceholderAreNotEncoded() {
    #expect(
        QuicklinkTemplate("https://example.com/{path | raw}").fill(arguments: ["path": "a/b c"], context: context())
            == "https://example.com/a/b c")
    #expect(
        QuicklinkTemplate("~/Projects/{name}").fill(arguments: ["name": "My App"], context: context())
            == "~/Projects/My App", "a path takes values as they are")
    #expect(
        QuicklinkTemplate("/tmp/{name | percent-encode}").fill(arguments: ["name": "a b"], context: context())
            == "/tmp/a%20b", "unless asked")
    #expect(
        QuicklinkTemplate("{clipboard}").fill(arguments: [:], context: context(clipboard: "https://a.com/?x=1"))
            == "https://a.com/?x=1", "a link that is one placeholder is taken raw")
}

@Test func modifiersChangeTheValueBeforeItsEncoded() {
    let template = QuicklinkTemplate(
        "https://e.com/{a | uppercase}/{a | lowercase}/{b | trim}/{c | trim | uppercase | raw}")
    #expect(template.problem == nil)
    #expect(
        template.fill(arguments: ["a": "Mixed", "b": "  x y  ", "c": " z/z "], context: context())
            == "https://e.com/MIXED/mixed/x%20y/Z/Z")
}

@Test func dynamicPlaceholdersFillIn() {
    let template = QuicklinkTemplate("https://e.com/?c={clipboard}&u={uuid}&d={date}&t={time}&dt={datetime}")
    #expect(template.problem == nil && template.arguments.isEmpty)
    let filled = template.fill(arguments: [:], context: context())
    #expect(filled.hasPrefix("https://e.com/?c=copied%20text&u=11111111-2222-3333-4444-555555555555&d="))
    // 1,795,000,000 s is 18 November 2026, 09:46 in Copenhagen.
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
    calendar.locale = Locale(identifier: "en_US")
    func formatted(_ d: Date.FormatStyle.DateStyle, _ t: Date.FormatStyle.TimeStyle) -> String {
        QuicklinkTemplate.encodeURIComponent(
            date.formatted(
                Date.FormatStyle(
                    date: d, time: t, locale: Locale(identifier: "en_US"), calendar: calendar,
                    timeZone: calendar.timeZone)))
    }
    #expect(
        filled.hasSuffix(
            "&d=\(formatted(.abbreviated, .omitted))&t=\(formatted(.omitted, .shortened))"
                + "&dt=\(formatted(.abbreviated, .shortened))"))
    #expect(formatted(.abbreviated, .omitted).contains("Nov"), "in the Mac's format")
    #expect(
        QuicklinkTemplate("https://e.com/{clipboard}x").fill(arguments: [:], context: context(clipboard: nil))
            == "https://e.com/x", "no clipboard text reads as empty")
}

@Test func raycastsOtherDynamicNamesAreProblemsNotArguments() {
    for written in ["{selection}", "{day}", "{cursor}", "{browser-tab}", #"{snippet name="sig"}"#, "{Selection}"] {
        let template = QuicklinkTemplate("https://e.com/\(written)")
        #expect(template.problem == "Fudge doesn't support “\(written)” in a quicklink.", "\(written)")
        #expect(template.arguments.isEmpty, "\(written) isn't an argument")
    }
}

@Test func anythingElseInBracesIsAProblemThatNamesIt() {
    let cases: [(String, String)] = [
        (#"https://e.com/{date format="yyyy"}"#, #"Fudge doesn't support “{date format="yyyy"}” in a quicklink."#),
        (
            #"https://e.com/{argument name="q" size="2"}"#,
            #"Fudge doesn't support “{argument name="q" size="2"}” in a quicklink."#
        ),
        ("https://e.com/{q | shout}", "Fudge doesn't know the modifier “shout” in “{q | shout}”."),
        ("https://e.com/{}", "Fudge doesn't support “{}” in a quicklink."),
        ("https://e.com/{two words}", "Fudge doesn't support “{two words}” in a quicklink."),
        ("https://e.com/{q", "A “{” in the link has no “}” after it."),
        ("https://e.com/{a{b}}", "A “{” in the link has no “}” after it."),
        ("https://e.com/q}", "A “}” in the link has no “{” before it."),
    ]
    for (link, problem) in cases {
        #expect(QuicklinkTemplate(link).problem == problem, "\(link)")
    }
    #expect(QuicklinkTemplate("https://e.com/plain").problem == nil)
}

@Test func theClipboardSkipsConcealedAndTransientContent() {
    #expect(QuicklinkTemplate.clipboardText("hello", types: ["public.utf8-plain-text"]) == "hello")
    #expect(
        QuicklinkTemplate.clipboardText(
            "hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) == nil,
        "a password manager's copy")
    #expect(
        QuicklinkTemplate.clipboardText("x", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
            == nil)
    #expect(QuicklinkTemplate.clipboardText(nil, types: []) == nil)
}

@Test func theSchemeAndWhetherItsAPath() {
    #expect(QuicklinkTemplate("https://e.com/{q}").scheme == "https")
    #expect(QuicklinkTemplate("Slack://open?team={t}").scheme == "slack")
    #expect(QuicklinkTemplate("{clipboard}").scheme == nil, "a placeholder's scheme isn't known")
    #expect(QuicklinkTemplate("~/Downloads").isPath && QuicklinkTemplate("/tmp/{x}").isPath)
    #expect(!QuicklinkTemplate("https://e.com").isPath && QuicklinkTemplate("~/x").scheme == nil)
}

// MARK: - Opening

@Test func aFilledLinkOpensAsAURLOrAPathThatExists() {
    let exists: (String) -> Bool = { $0 == "/Users/me/Downloads" || $0 == "/tmp" }
    let web = QuicklinkTemplate("https://e.com/{q}")
    #expect(
        QuicklinkOpening.target(for: web, filled: "https://e.com/a%20b", home: "/Users/me", exists: exists)
            == .success(.url(URL(string: "https://e.com/a%20b")!)))
    #expect(
        QuicklinkOpening.target(for: web, filled: "slack://open", home: "/Users/me", exists: exists)
            .map(\.openText) == .success("slack://open"))
    let path = QuicklinkTemplate("~/Downloads")
    #expect(
        QuicklinkOpening.target(for: path, filled: "~/Downloads", home: "/Users/me", exists: exists)
            == .success(.path("/Users/me/Downloads")), "~ expanded")
    #expect(
        QuicklinkOpening.target(for: path, filled: "/tmp", home: "/Users/me", exists: exists) == .success(.path("/tmp"))
    )
}

@Test func openingFailsWithAMessage() {
    let exists: (String) -> Bool = { _ in false }
    func failure(_ link: String, _ filled: String) -> String? {
        if case .failure(let failure) = QuicklinkOpening.target(
            for: QuicklinkTemplate(link), filled: filled, home: "/Users/me", exists: exists)
        {
            return failure.description
        }
        return nil
    }
    #expect(failure("~/Gone", "~/Gone") == "“~/Gone” doesn't exist.")
    #expect(failure("~other/x", "~other/x") == "“~other/x” isn't a path Fudge can open.")
    #expect(failure("{clipboard}", "just some words") == "“just some words” isn't a link Fudge can open.")
    #expect(failure("{clipboard}", "example.com/page") == "“example.com/page” isn't a link Fudge can open.")
    #expect(failure("https://e.com/{selection}", "") == "Fudge doesn't support “{selection}” in a quicklink.")
}

// MARK: - Root search

@Test func aQuicklinkIsARootItemWithItsArgumentsAsFields() {
    let jira = Quicklink(
        id: "q1", name: "Jira Ticket", link: #"https://jira.example.com/browse/{argument name="ticket"}"#)
    let item = RootItem.quicklink(jira)
    #expect(item.id == "quicklink:q1" && item.title == "Jira Ticket")
    #expect(item.subtitle == nil, "the row's kind already says Quicklink")
    #expect(item.kind == .quicklink(jira))
    #expect(item.arguments.map(\.name) == ["ticket"] && item.arguments.first?.required == true)
    #expect(item.recordsLaunch)
}

@Test func theLinkIsASecondaryMatch() {
    let jira = RootItem.quicklink(Quicklink(id: "q1", name: "Tickets", link: "https://jira.example.com/browse/{t}"))
    let jiraApp = RootItem.application(at: URL(fileURLWithPath: "/Applications/Jira.app"), title: "Jira")
    let ranked = RootSearch.rank([jira, jiraApp], query: "jira", history: LaunchHistory())
    #expect(ranked.map(\.id) == [jiraApp.id, jira.id], "found by its link, below a title match")
    #expect(RootSearch.rank([jira], query: "tick", history: LaunchHistory()).map(\.id) == [jira.id])
    #expect(
        RootSearch.rank([jira, jiraApp], query: "quicklink", history: LaunchHistory()).map(\.id) == [jira.id],
        "typing quicklink lists them")
}

@Test func aQuicklinksActionsAreOpenCopyLinkAndDelete() {
    let jira = Quicklink(id: "q1", name: "Jira Ticket", link: "https://jira.example.com/browse/{ticket}")
    let entries = ActionPanelReader.flat(RootActions.sections(for: RootItem.quicklink(jira)))
    #expect(entries.map(\.title) == ["Open Quicklink", "Copy Link", "Delete Quicklink…"])
    #expect(
        entries.map(\.shortcut) == [
            KeyShortcut(key: "return", modifiers: []), KeyShortcut(key: "c", modifiers: ["cmd", "shift"]),
            KeyShortcut(key: "x", modifiers: ["ctrl"]),
        ])
    #expect(
        entries.map(\.target) == [
            .root(.open), .root(.copyQuicklink("https://jira.example.com/browse/{ticket}")),
            .root(.deleteQuicklink("q1")),
        ], "the link as saved, placeholders included")
    #expect(entries.map(\.destructive) == [false, false, true])
}

@Test func anArgumentFieldMustBeFilledUnlessItHasADefault() {
    let item = RootItem.quicklink(
        Quicklink(
            id: "q1", name: "Search", link: #"https://e.com/?q={argument name="q"}&n={argument name="n" default="10"}"#)
    )
    var input = ArgumentInput(arguments: item.arguments)
    let empty = input.checkRequired()
    #expect(!empty && input.focus == 0 && input.missing == 0, "q is empty")
    input.set("cats", at: 0)
    let filled = input.checkRequired()
    #expect(filled, "n has a default")
    let template = QuicklinkTemplate("https://e.com/?q={argument name=\"q\"}&n={argument name=\"n\" default=\"10\"}")
    #expect(template.fill(arguments: input.launchArguments, context: context()) == "https://e.com/?q=cats&n=10")
}
