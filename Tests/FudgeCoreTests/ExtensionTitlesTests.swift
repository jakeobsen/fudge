import Foundation
import Testing

@testable import FudgeCore

extension ExtensionTitles {
    /// `installed` named with the defaults: Raycast's official repository alone in the list, with no name.
    static func forTests(_ installed: [InstalledExtension]) -> ExtensionTitles {
        ExtensionTitles(installed, names: RepositoryNames(settings: FudgeSettings()))
    }
}

/// How each install is named (SPEC-174 A): its title, and its repository only while another install has its title.
private func install(_ name: String, _ title: String, in folder: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "commands": [] }"#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/\(folder)/\(name)"),
        id: try #require(ExtensionID(name: name, repositoryFolder: folder)),
        repository: try #require(InstalledExtension.Repository(folder: folder)))
}

/// A made-up bundled extension, as `InstalledExtension.all(paths:resources:)` lists one.
private func bundled(_ name: String, _ title: String) throws -> InstalledExtension {
    let json = #"{ "name": "\#(name)", "title": "\#(title)", "commands": [] }"#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/resources/\(name)"), id: .bundled(name), repository: .bundled)
}

/// The titles of `installed` as `titles` names them, in the same order.
private func shown(_ installed: [InstalledExtension], _ titles: ExtensionTitles) -> [String] {
    installed.map(titles.title(of:))
}

@Test func anInstallAloneShowsItsBareTitleWhereverItsFrom() throws {
    let each = [
        try install("scratch", "Scratch", in: "raycast/extensions"),
        try install("notes", "Notes", in: "jakeobsen/raycast"),
        try install("github", "GitHub", in: "fudgeapp/development"),
        try bundled("fudge-clipboard-history", "Clipboard History"),
    ]
    for item in each {
        let titles = ExtensionTitles.forTests([item])
        #expect(titles.label(of: item) == nil, "\(item.id.key)")
        #expect(titles.title(of: item) == item.manifest.title, "\(item.id.key)")
    }
    #expect(shown(each, .forTests(each)) == ["Scratch", "Notes", "GitHub", "Clipboard History"], "titles all differ")
}

@Test func aClashLabelsBothRaycastsIncludedAndNoOtherInstall() throws {
    let raycast = try install("scratch", "Scratch", in: "raycast/extensions")
    let added = try install("scratch", "Scratch", in: "jakeobsen/raycast")
    let other = try install("notes", "Notes", in: "jakeobsen/raycast")
    let titles = ExtensionTitles.forTests([raycast, added, other])
    #expect(
        shown([raycast, added, other], titles) == [
            "Scratch (raycast/extensions)", "Scratch (jakeobsen/raycast)", "Notes",
        ])
    #expect(titles.label(of: raycast) == "raycast/extensions" && titles.label(of: added) == "jakeobsen/raycast")
    #expect(titles.label(of: other) == nil)
}

@Test func aBundledRaycastsAndADevelopmentInstallOfOneTitleEachSayWhereTheyreFrom() throws {
    let three = [
        try bundled("fudge-clipboard-history", "Clipboard History"),
        try install("clipboard-history", "Clipboard History", in: "raycast/extensions"),
        try install("clipboard-history", "Clipboard History", in: "fudgeapp/development"),
    ]
    #expect(
        shown(three, .forTests(three)) == [
            "Clipboard History (Core)", "Clipboard History (raycast/extensions)", "Clipboard History (development)",
        ])
}

@Test func titlesAreTheSameNameTrimmedAndIgnoringCaseButNotInsideSpaces() throws {
    let raycast = try install("scratch", "Scratch", in: "raycast/extensions")
    let lower = try install("scratch", "scratch", in: "jakeobsen/raycast")
    let spaced = try install("scratch", " Scratch\\n", in: "fudgeapp/development")
    let inside = try install("scr-atch", "Scr atch", in: "someone/tools")
    let titles = ExtensionTitles.forTests([raycast, lower, spaced, inside])
    #expect(
        shown([raycast, lower, spaced, inside], titles) == [
            "Scratch (raycast/extensions)", "scratch (jakeobsen/raycast)", " Scratch\n (development)", "Scr atch",
        ], "each shows its own title as written")

    let precomposed = try install("cafe", "Caf\u{E9}", in: "raycast/extensions")
    let decomposed = try install("cafe", "Cafe\u{301}", in: "someone/tools")
    let picker = try install("picker", "Color Picker", in: "raycast/extensions")
    let doubled = try install("picker", "Color  Picker", in: "someone/tools")
    let street = try install("street", "Stra\u{DF}e", in: "raycast/extensions")
    let upper = try install("street", "STRASSE", in: "someone/tools")
    let more = ExtensionTitles.forTests([precomposed, decomposed, picker, doubled, street, upper])
    #expect(more.label(of: precomposed) == "raycast/extensions" && more.label(of: decomposed) == "someone/tools")
    #expect(more.label(of: picker) == nil && more.label(of: doubled) == nil, "two spaces inside are another name")
    #expect(more.label(of: street) == "raycast/extensions" && more.label(of: upper) == "someone/tools")
    #expect(ExtensionTitles.same("Scratch", " scratch\n") && !ExtensionTitles.same("Scratch", "Scr atch"))
}

@Test func twoInstallsFromOneRepositoryWithOneTitleBothGetItsLabel() throws {
    let first = try install("scratch", "Scratch", in: "someone/tools")
    let second = try install("scratch-two", "Scratch", in: "someone/tools")
    let titles = ExtensionTitles.forTests([first, second])
    #expect(shown([first, second], titles) == ["Scratch (someone/tools)", "Scratch (someone/tools)"])
}

@Test func theOrderOfTheInstallsDoesntMatter() throws {
    let installed = [
        try bundled("fudge-clipboard-history", "Clipboard History"),
        try install("clipboard-history", "Clipboard History", in: "raycast/extensions"),
        try install("scratch", "Scratch", in: "raycast/extensions"),
        try install("scratch", "scratch", in: "jakeobsen/raycast"),
        try install("scratch-two", "Scratch", in: "jakeobsen/raycast"),
        try install("notes", "Notes", in: "fudgeapp/development"),
    ]
    #expect(ExtensionTitles.forTests(installed) == ExtensionTitles.forTests(installed.reversed()))
    #expect(shown(installed, .forTests(installed)) == shown(installed, .forTests(installed.reversed())))
}

@Test func labelsComeFromTheRepositoriesNames() throws {
    let raycast = try install("scratch", "Scratch", in: "raycast/extensions")
    let added = try install("scratch", "Scratch", in: "jakeobsen/raycast")
    let named = try install("scratch", "Scratch", in: "someone/tools")
    let gone = try install("scratch", "Scratch", in: "gone/tools")
    let installed = [raycast, added, named, gone]

    var settings = FudgeSettings()
    let jakeobsen = try ExtensionRepository.parse(address: "https://github.com/JakeObsen/Raycast").get()
    let tools = try ExtensionRepository.parse(address: "https://github.com/someone/tools", existing: [jakeobsen]).get()
    #expect(jakeobsen.folder == "jakeobsen/raycast" && jakeobsen.name == "JakeObsen/Raycast")
    let others = [ListedRepository(repository: jakeobsen), ListedRepository(repository: tools, label: "mine")]
    // Raycast's official repository's entry is named as any other is: none, its name, or its folder once removed.
    let raycastEntries: [([ListedRepository], String)] = [
        ([ListedRepository(repository: .raycast)], "raycast/extensions"),
        ([ListedRepository(repository: .raycast, on: false, label: "Raycast")], "Raycast"),
        ([], "raycast/extensions"),
    ]
    for (raycastEntry, label) in raycastEntries {
        settings.extensionRepositories = others + raycastEntry
        let titles = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
        #expect(
            shown(installed, titles) == [
                "Scratch (\(label))", "Scratch (JakeObsen/Raycast)", "Scratch (mine)", "Scratch (gone/tools)",
            ], "Raycast's \(label); a listed one without a name as typed, one no longer listed by its folder")
    }

    settings.extensionRepositories = [ListedRepository(repository: tools, label: "mine")]
    let unlisted = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
    #expect(unlisted.title(of: added) == "Scratch (jakeobsen/raycast)", "removed from the list: its folder")
    settings.extensionRepositories = [ListedRepository(repository: jakeobsen, label: "jakeobsen")]
    let renamed = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
    #expect(renamed.title(of: added) == "Scratch (jakeobsen)", "added back with a name")
    #expect(renamed.title(of: named) == "Scratch (someone/tools)")

    let names = RepositoryNames(settings: settings)
    #expect(names.label(of: .raycast) == "raycast/extensions" && names.label(of: .development) == "development")
    #expect(names.label(of: .bundled) == "Core")
}

// MARK: - One name rule (SPEC-175)

/// The one name rule's fixture, which the Extension Store's `store-names.test.ts` reads too, so the app's
/// `ExtensionTitles.key` and `RepositoryNames.check` and the store's `repository-name.ts` can't drift apart.
func repositoryNamesFixture() throws -> [String: Any] {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/repository-names.json")
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

/// `text`'s scalars in hex, for a failure's message.
func scalarsInHex(_ text: String) -> String {
    text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
}

/// An install titled `title` exactly, whatever characters it has.
private func titled(_ name: String, _ title: String, in folder: String) throws -> InstalledExtension {
    let json = try JSONSerialization.data(withJSONObject: ["name": name, "title": title, "commands": []])
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: json),
        directory: URL(fileURLWithPath: "/nonexistent/\(folder)/\(name)"),
        id: try #require(ExtensionID(name: name, repositoryFolder: folder)),
        repository: try #require(InstalledExtension.Repository(folder: folder)))
}

@Test func theNameKeyTrimsFoldsAndDecomposesAsTheFixtureSays() throws {
    let fixture = try repositoryNamesFixture()
    let trimmed = try #require(fixture["trimmed"] as? [String])
    #expect(ExtensionTitles.trimmedScalars.map { String(format: "%04X", $0.value) } == trimmed)
    let folds = try #require(fixture["folds"] as? [[String]])
    #expect(folds.count == ExtensionTitles.folds.count)
    for fold in folds {
        let scalars = Array(fold[0].unicodeScalars)
        let mapped = scalars.count == 1 ? ExtensionTitles.folds[scalars[0]] : nil
        #expect(mapped?.unicodeScalars.elementsEqual(fold[1].unicodeScalars) == true, "\(scalarsInHex(fold[0]))")
    }
    let keys = try #require(fixture["keys"] as? [[String: String]])
    #expect(keys.count == 32)
    for pair in keys {
        let text = try #require(pair["text"])
        let key = try #require(pair["key"])
        let same = ExtensionTitles.key(text).unicodeScalars.elementsEqual(key.unicodeScalars)
        #expect(same, "\(scalarsInHex(text)) gave \(scalarsInHex(ExtensionTitles.key(text)))")
    }
}

@Test func theFixturesSetsOfTitlesAreLabeledAsTheStoreLabelsThem() throws {
    let sets = try #require(try repositoryNamesFixture()["sets"] as? [[String: Any]])
    for set in sets {
        let titles = try #require(set["titles"] as? [String])
        let labeled = try #require(set["labeled"] as? [Bool])
        var installed: [InstalledExtension] = []
        for (index, title) in titles.enumerated() {
            installed.append(try titled("scratch", title, in: "someone/tools\(index)"))
        }
        let names = ExtensionTitles.forTests(installed)
        let expected = labeled.enumerated().map { index, yes in yes ? "someone/tools\(index)" : nil }
        #expect(installed.map { names.label(of: $0) } == expected, "\(titles.map(scalarsInHex))")
    }
}

@Test func theStoreAnswerHasEachLabeledInstallsLabelByItsId() throws {
    let raycast = try install("clipboard-history", "Clipboard History", in: "raycast/extensions")
    let core = try bundled("fudge-clipboard-history", "Clipboard History")
    let notes = try install("notes", "Notes", in: "someone/tools")
    let installed = [raycast, core, notes]
    let unnamed: JSONValue = .object([
        "clipboard-history": .string("raycast/extensions"), "fudge-clipboard-history": .string("Core"),
    ])
    #expect(
        ExtensionTitles.forTests(installed).storeAnswer == unnamed,
        "Raycast's entry with no name, by its folder; Notes shares no name")

    var settings = FudgeSettings()
    settings.extensionRepositories = [ListedRepository(repository: .raycast, label: "Raycast")]
    #expect(
        ExtensionTitles(installed, names: RepositoryNames(settings: settings)).storeAnswer
            == .object(["clipboard-history": .string("Raycast"), "fudge-clipboard-history": .string("Core")]))
    #expect(ExtensionTitles.forTests([raycast, notes]).storeAnswer == .object([:]), "no two titles the same")
}
