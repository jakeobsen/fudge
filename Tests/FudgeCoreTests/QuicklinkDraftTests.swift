import Foundation
import Testing

@testable import FudgeCore

// Quicklinks, part B (FUD-86): the draft's rules, Action.CreateQuicklink's request, and the Create Quicklink form.

private let jira = Quicklink(
    id: "q1", name: "Jira Ticket", link: "https://jira.example.com/browse/{ticket}", application: "com.apple.Safari",
    createdAt: "2026-11-20T10:00:00Z")

private let safari = QuicklinkApplication(
    name: "Safari", bundleId: "com.apple.Safari", path: "/Applications/Safari.app")
private let finder = QuicklinkApplication(
    name: "Finder", bundleId: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")
private let applications = [safari, finder]

// MARK: - The draft's rules

@Test func aNameHasOneToSixtyFourCharactersAndIsUniqueIgnoringCase() {
    func nameProblem(_ name: String, id: String? = nil) -> String? {
        QuicklinkDraft(id: id, name: name, link: "https://e.com").problems(among: [jira]).name
    }
    #expect(nameProblem("") == "Enter a name.")
    #expect(nameProblem("   ") == "Enter a name.")
    #expect(nameProblem(String(repeating: "a", count: 64)) == nil)
    #expect(nameProblem(String(repeating: "a", count: 65)) == "Use at most 64 characters.")
    #expect(nameProblem("Search") == nil)
    #expect(nameProblem("jira ticket") == "Another quicklink is called “jira ticket”.", "ignoring case")
    #expect(nameProblem("  Jira Ticket ") != nil, "ignoring spaces around it")
    #expect(nameProblem("JIRA TICKET", id: "q1") == nil, "editing keeps its own name")
}

@Test func aLinkIsAURLWithASchemeOrAPathWithNoProblem() {
    func linkProblem(_ link: String) -> String? {
        QuicklinkDraft(name: "New", link: link).problems(among: []).link
    }
    #expect(linkProblem("") == "Enter a link.")
    #expect(linkProblem("  ") == "Enter a link.")
    for link in [
        "https://e.com/?q={argument}", "slack://channel?id=1", "mailto:{argument name=\"to\"}", "~/Documents",
        "/Applications", "~", "{clipboard}", "{argument name=\"url\"}",
    ] {
        #expect(linkProblem(link) == nil, "\(link) can be saved")
    }
    #expect(linkProblem("example.com") == "Start the link with a scheme, like https://, or a path, like ~/Documents.")
    #expect(linkProblem("~someone/x") == "Start a path with / or ~/.")
    #expect(linkProblem("https://e.com/{selection}") == "Fudge doesn't support “{selection}” in a quicklink.")
    #expect(linkProblem("https://e.com/{a}/{b}/{c}/{d}") == "A quicklink can have at most 3 fields.")
    #expect(QuicklinkDraft().problems(among: []) == .init(name: "Enter a name.", link: "Enter a link."))
    #expect(QuicklinkDraft(name: "Ok", link: "https://e.com").problems(among: [jira]).isEmpty)
}

@Test func savingAddsANewOneOrReplacesTheEditedOneById() throws {
    var store = QuicklinkStore([jira])
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let added = QuicklinkDraft(name: " Search ", link: " https://e.com/?q={argument} ").save(into: &store, now: now)
    #expect(added.name == "Search" && added.link == "https://e.com/?q={argument}", "trimmed")
    #expect(added.application == nil && added.createdAt == now.formatted(.iso8601) && !added.id.isEmpty)
    #expect(store.quicklinks.map(\.name) == ["Jira Ticket", "Search"])

    var edited = QuicklinkDraft(editing: jira)
    #expect(edited.id == "q1" && edited.name == "Jira Ticket" && edited.application == "com.apple.Safari")
    edited.name = "Tickets"
    edited.application = nil
    let replaced = edited.save(into: &store, now: now)
    #expect(replaced.id == "q1" && replaced.createdAt == "2026-11-20T10:00:00Z", "the same one, made when it was")
    #expect(store.quicklinks.map(\.name) == ["Tickets", "Search"], "in its place")
    #expect(store.quicklink(id: "q1")?.application == nil)

    // Deleted meanwhile: saving the edit adds it back.
    store.remove(id: "q1")
    edited.save(into: &store, now: now)
    #expect(store.quicklinks.map(\.id) == [added.id, "q1"])
}

@Test func editingKeepsKeysFudgeDoesntKnow() throws {
    let data = Data(
        #"{"quicklinks":[{"id":"q1","name":"Jira","link":"https://j.com/{t}","icon":"bolt","x":1}]}"#.utf8)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-ql-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try data.write(to: file)
    var store = QuicklinkStore.load(from: file)
    var draft = QuicklinkDraft(editing: try #require(store.quicklink(id: "q1")))
    draft.name = "Jira Tickets"
    draft.save(into: &store)
    try store.save(to: file)
    let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    guard case .object(let root) = saved, case .array(let entries) = root["quicklinks"],
        case .object(let entry) = entries.first
    else {
        Issue.record("no entry")
        return
    }
    #expect(entry["name"] == .string("Jira Tickets") && entry["icon"] == .string("bolt") && entry["x"] == .number(1))
}

// MARK: - Action.CreateQuicklink

@Test func createQuicklinksPropIsReadIntoARequest() {
    #expect(QuicklinkRequest(json: nil) == nil)
    #expect(QuicklinkRequest(json: .object(["name": .string("No link")])) == nil)
    #expect(
        QuicklinkRequest(json: .object(["link": .string("https://e.com")])) == QuicklinkRequest(link: "https://e.com"))
    #expect(
        QuicklinkRequest(
            json: .object([
                "link": .string("https://e.com"), "name": .string("E"), "application": .string("Safari"),
            ])) == QuicklinkRequest(link: "https://e.com", name: "E", application: .text("Safari")))
    #expect(
        QuicklinkRequest(
            json: .object([
                "link": .string("~/x"), "name": .string(" "),
                "application": .object(["name": .string("Finder"), "path": .string(finder.path)]),
            ]))
            == QuicklinkRequest(
                link: "~/x", application: .application(name: "Finder", path: finder.path, bundleId: nil)),
        "a blank name is no name")
}

@Test func theFormIsFilledInFromAnExtensionsRequest() {
    func draft(_ request: QuicklinkRequest) -> QuicklinkDraft {
        QuicklinkDraft(request: request, commandTitle: "Search Docs", applications: applications)
    }
    let plain = draft(QuicklinkRequest(link: "https://docs.e.com/?q={argument}"))
    #expect(
        plain == QuicklinkDraft(name: "Search Docs", link: "https://docs.e.com/?q={argument}"), "the command's title")
    #expect(draft(QuicklinkRequest(link: "https://e.com", name: "E")).name == "E")

    func application(_ reference: QuicklinkRequest.Application) -> String? {
        draft(QuicklinkRequest(link: "https://e.com", application: reference)).application
    }
    #expect(application(.text("com.apple.safari")) == "com.apple.Safari", "a bundle id, ignoring case")
    #expect(application(.text("safari")) == "com.apple.Safari", "a name")
    #expect(application(.text("Finder.app")) == "com.apple.finder")
    #expect(application(.text("/Applications/Safari.app")) == "com.apple.Safari", "a path")
    #expect(application(.application(name: nil, path: nil, bundleId: "com.apple.finder")) == "com.apple.finder")
    #expect(application(.application(name: "Other", path: safari.path, bundleId: nil)) == "com.apple.Safari")
    #expect(application(.application(name: "Finder", path: nil, bundleId: "com.example.gone")) == "com.apple.finder")
    #expect(application(.text("Nowhere")) == nil, "unknown: Default")
}

@Test func anActionCreateQuicklinkNodeRunsTheAppsForm() {
    func node(_ props: [String: JSONValue]) -> UINode {
        UINode(id: 7, type: "Action", props: props.merging(["title": .string("Create Quicklink")]) { a, _ in a })
    }
    let quicklink = JSONValue.object(["link": .string("https://e.com"), "application": .string("Safari")])
    #expect(
        ActionPanelReader.entry(node(["fudgeBuiltIn": .string("createQuicklink"), "quicklink": quicklink]))?.target
            == .createQuicklink(QuicklinkRequest(link: "https://e.com", application: .text("Safari"))))
    #expect(
        ActionPanelReader.entry(node(["fudgeBuiltIn": .string("createQuicklink")]))?.target == .node(7),
        "without a quicklink it's the extension's own action")
    #expect(ActionPanelReader.entry(node([:]))?.target == .node(7))
}

// MARK: - The form

@Test func theFormHasNameLinkAndOpenWithAndSaves() throws {
    let view = QuicklinkForm.view(draft: QuicklinkDraft(), applications: [safari, finder])
    #expect(view.type == "Form" && view.string("navigationTitle") == "Create Quicklink")
    let form = FormContent(view)
    #expect(form.fields.map(\.fieldId) == ["name", "link", "application"])
    #expect(form.fields.map(\.title) == ["Name", "Link", "Open With"])
    #expect(form.fields.map(\.kind) == [.textField, .textField, .dropdown])
    #expect(
        form.fields.map(\.id) == [QuicklinkForm.Node.name, QuicklinkForm.Node.link, QuicklinkForm.Node.application])
    #expect(form.fields[1].info == #"Use {argument name="…"} for a field, or {clipboard}, {date}, {uuid}."#)
    #expect(form.fields.allSatisfy { $0.value == nil }, "uncontrolled, so what's typed stays")
    let items = try #require(form.fields[2].options?.items)
    #expect(items.map(\.title) == ["Default", "Finder", "Safari"], "Default, then by name")
    #expect(items.map(\.value) == ["", "com.apple.finder", "com.apple.Safari"])
    #expect(items[2].icon == .object(["fileIcon": .string(safari.path)]))
    #expect(form.fields[2].initialValue() == .string(""))

    let actions = ActionPanelReader.sections(of: view.node("actions"))
    let save = try #require(ActionPanelReader.flat(actions).first)
    #expect(save.title == "Save Quicklink" && save.id == QuicklinkForm.Node.save && save.target == .node(save.id))
}

@Test func theFormStartsOnTheDraftAndShowsItsProblems() {
    var draft = QuicklinkDraft(editing: jira)
    let view = QuicklinkForm.view(
        draft: draft, problems: .init(name: "Enter a name."), applications: [finder])
    #expect(view.string("navigationTitle") == "Edit Quicklink")
    let form = FormContent(view)
    #expect(
        form.fields.map { $0.initialValue() } == [
            .string("Jira Ticket"), .string(jira.link), .string("com.apple.Safari"),
        ])
    #expect(form.fields.map(\.error) == ["Enter a name.", nil, nil])
    #expect(
        form.fields[2].options?.items.map(\.title) == ["Default", "com.apple.Safari", "Finder"],
        "an app that isn't listed is kept, by its bundle id")

    draft = QuicklinkForm.draft(
        draft, with: ["name": .string("Tickets"), "link": .string("https://t.com/{t}"), "application": .string("")])
    #expect(draft == QuicklinkDraft(id: "q1", name: "Tickets", link: "https://t.com/{t}", createdAt: jira.createdAt))
}

// MARK: - Placeholders (reviewer's notes on part A)

@Test func aBarInsideQuotesIsntAModifier() {
    let template = QuicklinkTemplate(#"https://e.com/?q={argument name="q" default="a|b" | uppercase}"#)
    #expect(template.problem == nil)
    #expect(template.arguments.first?.defaultValue == "a|b")
    #expect(template.fill(arguments: [:], context: .init(clipboard: nil)) == "https://e.com/?q=A%7CB")
}

@Test func datesAreWrittenInTheMacsCalendar() {
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
    let context = QuicklinkTemplate.Context(
        clipboard: nil, now: Date(timeIntervalSince1970: 1_795_000_000), locale: Locale(identifier: "en_US"),
        timeZone: buddhist.timeZone, calendar: buddhist)
    let filled = QuicklinkTemplate("{date}").fill(arguments: [:], context: context)
    #expect(filled.contains("2569"), "the Buddhist year of 2026: \(filled)")
}
