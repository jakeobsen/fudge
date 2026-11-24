import Foundation
import Testing

@testable import FudgeCore

extension ExtensionTitles {
    /// `installed` named with no repository in the list, as a fresh `settings.json` has it.
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
    #expect(shown([raycast, added, other], titles) == ["Scratch (raycast)", "Scratch (jakeobsen/raycast)", "Notes"])
    #expect(titles.label(of: raycast) == "raycast" && titles.label(of: added) == "jakeobsen/raycast")
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
            "Clipboard History (Fudge)", "Clipboard History (raycast)", "Clipboard History (development)",
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
            "Scratch (raycast)", "scratch (jakeobsen/raycast)", " Scratch\n (development)", "Scr atch",
        ], "each shows its own title as written")

    let precomposed = try install("cafe", "Caf\u{E9}", in: "raycast/extensions")
    let decomposed = try install("cafe", "Cafe\u{301}", in: "someone/tools")
    let picker = try install("picker", "Color Picker", in: "raycast/extensions")
    let doubled = try install("picker", "Color  Picker", in: "someone/tools")
    let street = try install("street", "Stra\u{DF}e", in: "raycast/extensions")
    let upper = try install("street", "STRASSE", in: "someone/tools")
    let more = ExtensionTitles.forTests([precomposed, decomposed, picker, doubled, street, upper])
    #expect(more.label(of: precomposed) == "raycast" && more.label(of: decomposed) == "someone/tools")
    #expect(more.label(of: picker) == nil && more.label(of: doubled) == nil, "two spaces inside are another name")
    #expect(more.label(of: street) == "raycast" && more.label(of: upper) == "someone/tools")
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
    settings.extensionRepositories = [
        ListedRepository(repository: jakeobsen), ListedRepository(repository: tools, label: "mine"),
    ]
    for state in RaycastRepositoryState.allCases {
        settings.raycastRepositoryState = state
        let titles = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
        #expect(
            shown(installed, titles) == [
                "Scratch (raycast)", "Scratch (JakeObsen/Raycast)", "Scratch (mine)", "Scratch (gone/tools)",
            ], "Raycast's \(state); a listed one without a name as typed, one no longer listed by its folder")
    }

    settings.extensionRepositories = [ListedRepository(repository: tools, label: "mine")]
    let unlisted = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
    #expect(unlisted.title(of: added) == "Scratch (jakeobsen/raycast)", "removed from the list: its folder")
    settings.extensionRepositories = [ListedRepository(repository: jakeobsen, label: "jakeobsen")]
    let renamed = ExtensionTitles(installed, names: RepositoryNames(settings: settings))
    #expect(renamed.title(of: added) == "Scratch (jakeobsen)", "added back with a name")
    #expect(renamed.title(of: named) == "Scratch (someone/tools)")

    let names = RepositoryNames(settings: settings)
    #expect(names.label(of: .raycast) == "raycast" && names.label(of: .development) == "development")
    #expect(names.label(of: .bundled) == "Fudge" && ExtensionRepositoryText.raycastLabel == "raycast")
}
