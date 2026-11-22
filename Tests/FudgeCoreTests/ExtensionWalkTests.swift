import Foundation
import Testing

@testable import FudgeCore

/// Made-up installs in a temporary extensions folder, for the walk, the move and the watcher.
enum Layout {
    /// Writes an install of `name` (its `package.json`) at `path` in `extensions`, made with the folders on the way.
    @discardableResult
    static func install(_ name: String, at path: String, in extensions: URL, title: String? = nil) throws -> URL {
        let folder = extensions.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest =
            #"{"name":"\#(name)","title":"\#(title ?? name)","commands":[{"name":"run","title":"Run","mode":"no-view"}]}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
        return folder
    }

    /// Each install the loader finds, as `<id> <repository> <path relative to the extensions folder>`.
    static func loaded(_ extensions: URL) -> [String] {
        InstalledExtension.load(walking: extensions).installed.map(describe(in: extensions)).sorted()
    }

    static func describe(in extensions: URL) -> (InstalledExtension) -> String {
        { install in
            let base = extensions.resolvingSymlinksInPath().path + "/"
            let path = install.directory.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            return "\(install.id.key) \(install.repository) \(relative)"
        }
    }
}

@Test func theWalkFindsEachKindOfInstall() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "raycast/extensions/github", in: extensions)
    try Layout.install("github", at: "fudgeapp/development/github", in: extensions)
    try Layout.install("github", at: "someone/tools/github", in: extensions)
    try Layout.install("github", at: "fudgeapp/tools/github", in: extensions)
    try Layout.install("github", at: "raycast/tools/github", in: extensions)
    try Layout.install("github", at: "git.example.org_8443/team/extensions/github", in: extensions)
    try Layout.install("weather", at: "weather", in: extensions)

    #expect(
        Layout.loaded(extensions) == [
            "fudgeapp+development+github development fudgeapp/development/github",
            "fudgeapp+tools+github added(\"fudgeapp/tools\") fudgeapp/tools/github",
            "git.example.org_8443+team+extensions+github added(\"git.example.org_8443/team/extensions\") "
                + "git.example.org_8443/team/extensions/github",
            "github raycast raycast/extensions/github",
            "raycast+tools+github added(\"raycast/tools\") raycast/tools/github",
            "someone+tools+github added(\"someone/tools\") someone/tools/github",
            "weather raycast weather",
        ])
    #expect(InstalledExtension.load(walking: extensions).skipped.isEmpty)
}

@Test func raycastsInstallAndADevelopmentBuildOfOneNameBothLoad() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "raycast/extensions/github", in: extensions, title: "GitHub")
    try Layout.install("github", at: "fudgeapp/development/github", in: extensions, title: "GitHub")
    let load = InstalledExtension.load(walking: extensions)
    #expect(load.installed.map(\.id.key).sorted() == ["fudgeapp+development+github", "github"])
    #expect(load.installed.map(\.displayTitle).sorted() == ["GitHub", "GitHub (development)"])
    #expect(load.skipped.isEmpty, "neither is skipped, and nothing is logged")
    let development = try #require(load.installed.first { $0.repository == .development })
    #expect(development.id == Development.id("github"))
}

@Test func linksAndHiddenEntriesAreSkippedAndATopLevelLinkIsLogged() throws {
    let extensions = try Fixtures.temporaryDirectory()
    let elsewhere = try Fixtures.temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: extensions)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let target = try Layout.install("linked", at: "linked", in: elsewhere)
    let files = FileManager.default
    try files.createSymbolicLink(at: extensions.appendingPathComponent("linked"), withDestinationURL: target)
    try Layout.install("hidden", at: ".hidden", in: extensions)
    try Layout.install("hidden", at: "raycast/extensions/.staging-hidden-1", in: extensions)
    try Layout.install("github", at: "someone/.tools/github", in: extensions)
    try files.createDirectory(
        at: extensions.appendingPathComponent("someone/tools"), withIntermediateDirectories: true)
    try files.createSymbolicLink(
        at: extensions.appendingPathComponent("someone/tools/linked"), withDestinationURL: target)
    try files.createDirectory(
        at: extensions.appendingPathComponent("raycast/extensions"), withIntermediateDirectories: true)
    try files.createSymbolicLink(
        at: extensions.appendingPathComponent("raycast/extensions/linked"), withDestinationURL: target)
    try files.createDirectory(
        at: extensions.appendingPathComponent("git.example.org"), withIntermediateDirectories: true)
    try files.createSymbolicLink(
        at: extensions.appendingPathComponent("git.example.org/team"), withDestinationURL: elsewhere)

    let load = InstalledExtension.load(walking: extensions)
    #expect(load.installed.isEmpty, "\(load.installed.map(\.directory.path))")
    #expect(load.skipped == ["skipped linked: it's a link, so it's neither moved nor loaded"])
}

/// Six path segments below a host's folder, then the extension: seven folders down. One more is too deep.
@Test func aHostRepositoryOfSixSegmentsLoadsAndOneFolderDeeperDoesnt() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "git.example.org/a/b/c/d/e/f/github", in: extensions)
    try Layout.install("weather", at: "git.example.org/a/b/c/d/e/f/g/weather", in: extensions)
    #expect(
        Layout.loaded(extensions) == [
            "git.example.org+a+b+c+d+e+f+github added(\"git.example.org/a/b/c/d/e/f\") git.example.org/a/b/c/d/e/f/github"
        ])
}

/// A folder whose name isn't its manifest's is skipped, with one line naming it, in every repository's folder, so no id
/// is found twice.
@Test(arguments: ["raycast/extensions", "fudgeapp/development", "someone/tools", "git.example.org/team"])
func aFolderNotNamedAfterItsExtensionIsSkipped(_ repository: String) throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "\(repository)/github", in: extensions)
    try Layout.install("github", at: "\(repository)/github-copy", in: extensions)
    let load = InstalledExtension.load(walking: extensions)
    #expect(load.installed.map { $0.directory.lastPathComponent } == ["github"])
    #expect(
        load.skipped == ["skipped \(repository)/github-copy: its folder isn't named after its extension, github"])
}

@Test func anInstallOutsideARepositorysFolderIsSkipped() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "Owner/tools/github", in: extensions)
    try Layout.install("github", at: "git.example.org/github", in: extensions)
    try Layout.install("tools", at: "someone/tools", in: extensions)
    let load = InstalledExtension.load(walking: extensions)
    #expect(load.installed.isEmpty)
    #expect(
        load.skipped.sorted() == [
            "skipped Owner/tools/github: Owner/tools isn't a repository's folder",
            "skipped git.example.org/github: git.example.org isn't a repository's folder",
            "skipped someone/tools: an extension there isn't in a repository's folder",
        ])
}

/// An install the move hasn't filed yet loads as Raycast's, with its name as its id; once Raycast's folder has that id,
/// the moved one wins.
@Test func anUnmovedInstallLoadsAsRaycastsUntilAMovedOneIsThere() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "github", in: extensions)
    #expect(Layout.loaded(extensions) == ["github raycast github"])
    try Layout.install("github", at: "raycast/extensions/github", in: extensions)
    let load = InstalledExtension.load(walking: extensions)
    #expect(load.installed.map(Layout.describe(in: extensions)) == ["github raycast raycast/extensions/github"])
    #expect(load.skipped == ["skipped github: raycast/extensions/github is installed too, and that one loads"])
}

@Test func aBundledExtensionStillLoadsFromAFolderNamedDifferently() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources")
    try Layout.install("fudge-extension-store", at: "store-extension", in: resources, title: "Extension Store")
    let paths = FudgePaths(supportDirectory: root.appendingPathComponent("support"))
    try Layout.install("github", at: "raycast/extensions/github", in: paths.extensionsDirectory)
    let installed = InstalledExtension.all(paths: paths, resources: resources)
    #expect(installed.map(\.id.key).sorted() == ["fudge-extension-store", "github"])
    #expect(installed.first { $0.id == ExtensionStore.id }?.repository == .bundled)
}

@Test func eachSkippedLineIsWrittenOncePerRun() {
    let written = LockedLines()
    let log = ExtensionsFolderLog { written.append($0) }
    log.report(["skipped a: why", "skipped b: why"])
    log.report(["skipped a: why", "skipped c: why"])
    #expect(written.lines == ["skipped a: why", "skipped b: why", "skipped c: why"])
}

/// Lines written from any thread.
final class LockedLines: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

/// The walk's folders are where an install can land: the watcher stamps each (`FolderStamps`).
@Test func theWalkListsEveryFolderOnTheWayToAnInstall() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "raycast/extensions/github", in: extensions)
    try Layout.install("github", at: "someone/tools/github", in: extensions)
    try Layout.install("github", at: "git.example.org/team/extensions/github", in: extensions)
    try Layout.install("weather", at: "weather", in: extensions)
    #expect(
        ExtensionWalk(extensions).folders == [
            "", "git.example.org", "git.example.org/team", "git.example.org/team/extensions", "raycast",
            "raycast/extensions", "someone", "someone/tools",
        ])
}
