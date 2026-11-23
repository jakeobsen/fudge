import Foundation
import Testing

@testable import FudgeCore

/// A Mac made up for `CommandLineTools.resolve`: which `swift`s exist, where links lead, and what each
/// `swift --version` prints. It records every `swift` it was asked to run.
private final class FakeToolsSystem: CommandLineTools.System, @unchecked Sendable {
    var executables: Set<String> = []
    var links: [String: String] = [:]
    var versions: [String: String] = [:]
    private let lock = NSLock()
    private var runs: [String] = []
    var ran: [String] { lock.withLock { runs } }

    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func realPath(_ path: String) -> String { links[path] ?? path }
    func versionOutput(of swift: URL) -> String? {
        lock.withLock { runs.append(swift.path) }
        return versions[swift.path]
    }
}

private let toolsSwift = "/Library/Developer/CommandLineTools/usr/bin/swift"
private let xcodeFolder = "/Applications/Xcode.app/Contents/Developer"
private let xcodeSwift = xcodeFolder + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
/// `swift --version`'s real output, whose first number is the driver's.
private let swift633 = """
    swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
    Target: arm64-apple-macosx26.0

    """
private let swift642 = """
    swift-driver version: 1.148.8 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
    Target: arm64-apple-macosx26.0

    """
private let swift510 = """
    swift-driver version: 1.90.11.1 Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)
    Target: arm64-apple-macosx14.0

    """

@Test func findsTheCommandLineToolsByThemselves() throws {
    let system = FakeToolsSystem()
    system.executables = [toolsSwift]
    system.versions = [toolsSwift: swift633]
    let status = CommandLineTools.resolve(setting: nil, system: system)
    let tools = try #require(status.tools)
    #expect(tools.folder.path == "/Library/Developer/CommandLineTools")
    #expect(tools.swift.path == toolsSwift)
    #expect(tools.version.text == "6.3.3")
    #expect(status.line == "Swift 6.3.3")
}

@Test func neverLooksForXcodeByItself() {
    // D-117: Swift parts are built "only with Apple's Command Line Tools", so Xcode counts only when it's chosen.
    let system = FakeToolsSystem()
    system.executables = [xcodeSwift, xcodeFolder + "/usr/bin/swift"]
    system.versions = [xcodeSwift: swift642, xcodeFolder + "/usr/bin/swift": swift642]
    #expect(CommandLineTools.resolve(setting: nil, system: system) == .notFound)
    #expect(system.ran.isEmpty)
}

@Test func choosingXcodesDeveloperFolderFindsItsToolchain() throws {
    // Xcode's developer folder has no usr/bin/swift: its Swift is in the default toolchain.
    let system = FakeToolsSystem()
    system.executables = [xcodeSwift]
    system.versions = [xcodeSwift: swift642]
    let status = CommandLineTools.resolve(setting: xcodeFolder, system: system)
    let tools = try #require(status.tools)
    #expect(tools.folder.path == xcodeFolder)
    #expect(tools.swift.path == xcodeSwift)
    #expect(status.line == "Swift 6.4.2")
}

@Test func nothingFoundWhenNoFolderHasASwift() {
    let system = FakeToolsSystem()
    #expect(CommandLineTools.resolve(setting: nil, system: system) == .notFound)
    #expect(CommandLineTools.resolve(setting: nil, system: system).line == "Not found")
    #expect(system.ran.isEmpty, "no swift ran")
}

@Test func aSwiftOlderThanSixCountsAsNotFound() {
    let system = FakeToolsSystem()
    system.executables = [toolsSwift]
    system.versions = [toolsSwift: swift510]
    let status = CommandLineTools.resolve(setting: nil, system: system)
    #expect(status.tools == nil)
    #expect(status.line == "Swift 6.0 or later is needed")
}

@Test func aSwiftWhoseVersionCantBeReadIsNotFound() {
    let system = FakeToolsSystem()
    system.executables = [toolsSwift]
    // A version with no "Apple Swift version" isn't read from its other numbers.
    system.versions = [toolsSwift: "swift-driver version: 6.148.6 something else\n"]
    #expect(CommandLineTools.resolve(setting: nil, system: system) == .notFound)
    system.versions = [:]
    #expect(CommandLineTools.resolve(setting: nil, system: system) == .notFound)
}

@Test func aChosenFolderIsTheOnlyOneLookedAt() throws {
    let system = FakeToolsSystem()
    system.executables = [toolsSwift, "/opt/tools/usr/bin/swift"]
    system.versions = [toolsSwift: swift633, "/opt/tools/usr/bin/swift": swift642]
    #expect(CommandLineTools.resolve(setting: "/opt/tools", system: system).tools?.folder.path == "/opt/tools")
    // A chosen folder without a working swift says so, rather than falling back to the default.
    #expect(CommandLineTools.resolve(setting: "/opt/nothing", system: system) == .notFound)
    // The Command Line Tools' usr/bin comes before a toolchain in the same folder.
    system.executables.insert("/opt/tools/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    #expect(
        CommandLineTools.resolve(setting: "/opt/tools", system: system).tools?.swift.path
            == "/opt/tools/usr/bin/swift")
}

@Test(arguments: ["/", "/usr/..", "/usr/bin/../.."])
func neverRunsTheStubsInUsrBin(folder: String) {
    // `/` + usr/bin/swift is macOS's stub, which offers to install the tools.
    let system = FakeToolsSystem()
    system.executables = ["/usr/bin/swift"]
    system.versions = ["/usr/bin/swift": swift633]
    #expect(CommandLineTools.resolve(setting: folder, system: system) == .notFound)
    #expect(system.ran.isEmpty, "the stub never ran")
}

@Test func neverRunsASwiftThatLeadsToTheStubs() {
    let system = FakeToolsSystem()
    system.executables = ["/opt/link/usr/bin/swift"]
    system.links = ["/opt/link/usr/bin/swift": "/usr/bin/swift"]
    system.versions = ["/opt/link/usr/bin/swift": swift633]
    #expect(CommandLineTools.resolve(setting: "/opt/link", system: system) == .notFound)
    #expect(system.ran.isEmpty)
}

@Test(arguments: [
    ("swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)", "6.3.3", true),
    ("Apple Swift version 6.0 (swiftlang-6.0.0.9.10 clang-1600.0.26.2)", "6.0", true),
    ("swift-driver version: 1.90.11.1 Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)", "5.10", false),
    ("Apple Swift version 5.9.2 (swiftlang-5.9.2.2.56 clang-1500.1.0.2.5)", "5.9.2", false),
])
func readsSwiftsVersion(line: String, text: String, newEnough: Bool) throws {
    let version = try #require(CommandLineTools.SwiftVersion(versionOutput: line))
    #expect(version.text == text)
    #expect((version >= CommandLineTools.minimumVersion) == newEnough)
}

@Test func theSettingIsAnAbsolutePathOrUnset() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    #expect(FudgeSettings.load(from: file).commandLineTools == nil)
    var settings = FudgeSettings()
    settings.commandLineTools = "/opt/tools"
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).commandLineTools == "/opt/tools")
    settings.commandLineTools = nil
    try settings.save(to: file)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(object?["commandLineTools"] == nil, "cleared, it's gone from the file")
    for value in [#""relative/tools""#, "42", "true", #"["/opt"]"#, #""""#] {
        try Data(#"{ "commandLineTools": \#(value) }"#.utf8).write(to: file)
        #expect(FudgeSettings.load(from: file).commandLineTools == nil, "\(value) reads as unset")
    }
    #expect(Backup.consentKeys.contains("commandLineTools"), "a path on this Mac: an import keeps this Mac's")
}
