import Foundation
import Testing

@testable import FudgeCore

// SPEC-109 §3: a command that uses Raycast AI or the Browser Extension is off until the user turns it on, and Fudge's
// default never looks like the user's choice (the spec review's MUST).

private let slack = "slack"
private let slackOwner = CommandOwner.extension(ExtensionID(stored: slack)!)
private let emojis = FudgeSettings.commandID(owner: slackOwner, command: "search-emojis")
private let search = FudgeSettings.commandID(owner: slackOwner, command: "search")

/// An installed extension with these commands, and what `compatibility.json` says they use.
private func installed(_ commands: [String], using: [String: [CommandCompatibility.Unsupported]]) -> InstalledExtension
{
    let list = commands.map { #"{"name":"\#($0)","title":"\#($0)","mode":"view"}"# }.joined(separator: ",")
    let json = #"{"name":"\#(slack)","title":"Slack","commands":[\#(list)]}"#
    let manifest = try! JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension.topLevel(
        manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent"),
        compatibility: CommandCompatibility(commands: using))
}

@Test func theScansReportGivesEachCommandsUnsupportedUse() throws {
    let report = """
        {"extension":"slack","supported":false,"gaps":[],"unreadable":[],"commands":[
          {"name":"search","unsupported":[],"traced":true},
          {"name":"search-emojis","unsupported":["AI"],"traced":true},
          {"name":"tabs","unsupported":["Browser Extension","AI","Telepathy"],"traced":false}]}
        """
    let compatibility = try #require(CommandCompatibility(report: Data(report.utf8)))
    #expect(compatibility.commands == ["search-emojis": [.ai], "tabs": [.ai, .browserExtension]])
    #expect(CommandCompatibility(report: Data(#"{"extension":"x","gaps":[]}"#.utf8)) == nil, "a scanner from before")
    #expect(CommandCompatibility(report: Data(#"{"commands":[{"name":1}]}"#.utf8)) == nil)
    #expect(CommandCompatibility(report: Data("not json".utf8)) == nil)
}

@Test func compatibilityJSONIsWrittenAndReadTolerantly() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let written = CommandCompatibility(commands: ["search-emojis": [.ai], "tabs": [.browserExtension, .ai], "x": []])
    try written.write(to: folder)
    #expect(CommandCompatibility.load(from: folder) == written)
    #expect(written.commands["x"] == nil, "a command that uses nothing isn't listed")

    let file = folder.appendingPathComponent(CommandCompatibility.fileName)
    try #"{"commands":{"Not Valid":["AI"],"ok":["AI","Telepathy"],"bad":"AI","none":[]}}"#.write(
        to: file, atomically: true, encoding: .utf8)
    #expect(CommandCompatibility.load(from: folder).commands == ["ok": [.ai]])
    try "{".write(to: file, atomically: true, encoding: .utf8)
    #expect(CommandCompatibility.load(from: folder) == CommandCompatibility())

    // Never read through a link, and nothing over the cap.
    let elsewhere = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try written.write(to: elsewhere)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(
        at: file, withDestinationURL: elsewhere.appendingPathComponent(CommandCompatibility.fileName))
    #expect(CommandCompatibility.load(from: folder) == CommandCompatibility())
    try FileManager.default.removeItem(at: file)
    try Data(repeating: 32, count: CommandCompatibility.maxBytes + 1).write(to: file)
    #expect(CommandCompatibility.load(from: folder) == CommandCompatibility())
    #expect(CommandCompatibility.load(from: folder.appendingPathComponent("missing")) == CommandCompatibility())
}

/// SPEC-143: command names as Raycast accepts them (`caffeinateWhile`, dots) are kept, in their own case.
@Test func compatibilityJSONKeepsCommandNamesAsRaycastAcceptsThem() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let written = CommandCompatibility(commands: ["caffeinateWhile": [.ai], "show-recent.command": [.browserExtension]])
    try written.write(to: folder)
    #expect(CommandCompatibility.load(from: folder) == written)
    #expect(CommandCompatibility.load(from: folder).commands["caffeinatewhile"] == nil, "the name keeps its case")
}

@Test func settingsSayWhyACommandIsOff() {
    let compatibility = CommandCompatibility(commands: ["ask": [.ai], "tabs": [.ai, .browserExtension]])
    #expect(compatibility.reason(for: "ask") == "Uses Raycast AI, which Fudge doesn't support.")
    #expect(
        compatibility.reason(for: "tabs")
            == "Uses Raycast AI and the Raycast Browser Extension, which Fudge doesn't support.")
    #expect(compatibility.reason(for: "search") == nil)
}

@Test func aCommandThatUsesRaycastAIIsOffByDefaultAndTheOthersOn() {
    let extensions = [installed(["search", "search-emojis"], using: ["search-emojis": [.ai], "not-a-command": [.ai]])]
    #expect(InstalledExtension.offByDefault(extensions) == [emojis], "only the manifest's commands")
    var settings = FudgeSettings()
    settings.offByDefault = InstalledExtension.offByDefault(extensions)
    #expect(!settings.isEnabled(commandID: emojis))
    #expect(settings.isEnabled(commandID: search))
    #expect(settings.commands.isEmpty, "nothing is written for it")

    // Root search leaves it out, and its hotkey isn't registered.
    let items = RootSearch.applying(settings, to: RootItem.commands(of: extensions[0]))
    #expect(items.compactMap(\.commandSettingsID) == [search])
    settings.commands[emojis] = .init(hotkey: "option+e")
    settings.commands[search] = .init(hotkey: "option+s")
    #expect(Set(settings.availableHotkeys(installed: [emojis, search]).keys) == [search])
}

@Test func theUsersChoiceWinsEitherWayAndFudgesDefaultFollowsAnUpdate() throws {
    var settings = FudgeSettings()
    // An update drops its AI use: with nothing chosen, it's on again.
    settings.offByDefault = [emojis]
    #expect(!settings.isEnabled(commandID: emojis))
    settings.offByDefault = []
    #expect(settings.isEnabled(commandID: emojis))

    // The user turned it on, and an update adds AI: it stays on. Turned off, it stays off without AI.
    settings.commands[search] = .init(enabled: true)
    settings.offByDefault = [search]
    #expect(settings.isEnabled(commandID: search))
    settings.commands[emojis] = .init(enabled: false)
    settings.offByDefault = []
    #expect(!settings.isEnabled(commandID: emojis))

    // The extension's own Enabled still applies.
    settings.extensions[slackOwner] = .init(enabled: false)
    #expect(!settings.isEnabled(commandID: search))
}

@Test func theTogglesOnIsWrittenAndKeepsAnOffByDefaultCommandOn() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.offByDefault = [emojis]
    settings.setEnabled(true, commandID: emojis)
    #expect(settings.commands[emojis]?.enabled == true, "on is the user's choice, written down")
    #expect(settings.isEnabled(commandID: emojis))
    try settings.save(to: file)

    // Read back with Fudge's default still off: the user's on wins.
    var reloaded = FudgeSettings.load(from: file)
    reloaded.offByDefault = [emojis]
    #expect(reloaded.isEnabled(commandID: emojis))
}

@Test func theTogglesOffIsWrittenAndKeepsACommandOffWhenItsDefaultIsOn() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.offByDefault = [emojis]
    settings.setEnabled(false, commandID: search)
    #expect(settings.commands[search]?.enabled == false)
    #expect(!settings.isEnabled(commandID: search))
    // Turned off while it's off by default, it stays off once an update drops the AI use.
    settings.setEnabled(false, commandID: emojis)
    try settings.save(to: file)

    var reloaded = FudgeSettings.load(from: file)
    reloaded.offByDefault = []
    #expect(!reloaded.isEnabled(commandID: search))
    #expect(!reloaded.isEnabled(commandID: emojis))
}

@Test func aUserEnabledCommandStaysEnabledAcrossSavesReloadsAndReinstalls() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.commands[emojis] = .init(enabled: true)
    settings.offByDefault = [emojis]
    try settings.save(to: file)

    let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let commands = try #require(saved["commands"] as? [String: [String: Any]])
    #expect(commands[emojis]?["enabled"] as? Bool == true, "the user's on is written, not dropped as a default")
    #expect(saved["offByDefault"] == nil, "Fudge's default is never saved")

    // A reload, then a reinstall that still uses AI: the user's choice is read back, so it stays on.
    var reloaded = FudgeSettings.load(from: file)
    reloaded.offByDefault = [emojis]
    #expect(reloaded.isEnabled(commandID: emojis))
}

@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct BuildRecordsCommandCompatibility {
    @Test func theBuildWritesWhatTheScanFoundIntoTheInstall() throws {
        let source = try Fixtures.greeterCopy()
        let extensions = try Fixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: extensions)
        }
        let builder = Fixtures.builder(scanCommands: { _ in CommandCompatibility(commands: ["quiet": [.ai]]) })
        let installed = try builder.build(source: source, into: extensions)
        #expect(installed.compatibility.commands == ["quiet": [.ai]])
        #expect(
            try InstalledExtension.load(from: installed.directory, id: installed.id, repository: installed.repository)
                .compatibility.commands == ["quiet": [.ai]])
        // Its own file, so building over it again isn't refused as "not an install".
        _ = try builder.build(source: source, into: extensions)
    }

    @Test func aScanThatFailsInstallsWithEveryCommandEnabled() throws {
        struct Failed: Error {}
        let source = try Fixtures.greeterCopy()
        let extensions = try Fixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: extensions)
        }
        let builder = Fixtures.builder(scanCommands: { _ in throw Failed() })
        let installed = try builder.build(source: source, into: extensions)
        #expect(installed.compatibility == CommandCompatibility())
        #expect(
            !FileManager.default.fileExists(
                atPath: installed.directory.appendingPathComponent(CommandCompatibility.fileName).path))
    }
}

@Suite(.enabled(if: Fixtures.canBuild && Tool.node != nil, "needs esbuild and node: run `make test`"))
struct BuildScansEndToEnd {
    /// `fudge build` through the real tool and the real scanner: only the command that reaches AI is listed.
    @Test func fudgeBuildListsTheCommandThatUsesRaycastAI() async throws {
        let installed = try await fudgeBuild(ask: "ask", plain: "plain")
        #expect(installed.compatibility.commands == ["ask": [.ai]])
        #expect(InstalledExtension.offByDefault([installed]) == ["fudgeapp+development+made-up/ask"])
    }

    /// SPEC-143: a command named as Raycast accepts it (`caffeinateWhile`) is scanned too, so one that uses AI is
    /// still off by default.
    @Test func fudgeBuildListsACamelCaseCommandThatUsesRaycastAI() async throws {
        let installed = try await fudgeBuild(ask: "askAway", plain: "plain.command")
        #expect(installed.compatibility.commands == ["askAway": [.ai]])
        #expect(InstalledExtension.offByDefault([installed]) == ["fudgeapp+development+made-up/askAway"])
    }

    /// Builds a made-up extension with the real `fudge build`: a command named `ask` that reaches Raycast AI through
    /// a module of its own, and one named `plain` that doesn't.
    private func fudgeBuild(ask: String, plain: String) async throws -> InstalledExtension {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("made-up")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("src/lib"), withIntermediateDirectories: true)
        let manifest = #"""
            {"name":"made-up","title":"Made Up","commands":[
              {"name":"\#(ask)","title":"Ask","mode":"no-view"},
              {"name":"\#(plain)","title":"Plain","mode":"no-view"}]}
            """#
        let files = [
            "package.json": manifest,
            "src/\(ask).ts": "import { ask } from \"./lib/ai\";\nexport default async () => { await ask(); };\n",
            "src/lib/ai.ts": "import { AI } from \"@raycast/api\";\nexport const ask = () => AI.ask(\"hi\");\n",
            "src/\(plain).ts":
                "import { showHUD } from \"@raycast/api\";\nexport default async () => showHUD(\"hi\");\n",
        ]
        for (path, text) in files {
            try text.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let extensions = folder.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = try Tool.bundled(in: folder.appendingPathComponent("app"), node: Tool.node)
        process.arguments = ["build", source.path, "--into", extensions.path]
        process.environment = [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "TMPDIR": folder.path + "/",
            "FUDGE_ESBUILD": try #require(Fixtures.esbuild).path, "FUDGE_BUNDLER": try #require(Fixtures.bundler).path,
            "FUDGE_COMPAT_SCAN": Fixtures.repository.appendingPathComponent("runtime/scripts/compat/fudge-scan.ts")
                .path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Waited for on a thread of its own, with a deadline Dispatch enforces (FUD-153).
        let exited = try await OffThePool.run(within: Tool.noHang) {
            process.waitUntilExit()
            return true
        }
        if exited != true { process.terminate() }
        try #require(exited == true, "fudge build exited")
        try #require(process.terminationStatus == 0)
        return try #require(InstalledExtension.all(in: extensions).first { $0.manifest.name == "made-up" })
    }
}
