import Foundation
import Testing

@testable import FudgeCore

/// A made-up Fudge.app with the `fudge` tool in `Contents/Helpers`, its Info.plist saying `info`.
private func app(info: [String: Any]?) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("version-\(UUID().uuidString)")
    let contents = root.appendingPathComponent("Fudge.app/Contents")
    try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
    let tool = contents.appendingPathComponent("Helpers/fudge")
    try Data().write(to: tool)
    if let info {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    return tool
}

private var fudgeInfo: [String: Any] {
    [
        "CFBundleIdentifier": "io.github.jakeobsen.fudge", "CFBundleShortVersionString": "0.3.0",
        "FudgeGitDescribe": "v0.3.0",
    ]
}

@Test func theAppReadsItsOwnInfoPlist() {
    let info = FudgeVersion.info(
        bundle: fudgeInfo, executable: URL(fileURLWithPath: "/Applications/Fudge.app/Contents/MacOS/Fudge"))
    #expect(info?["CFBundleShortVersionString"] as? String == "0.3.0")
}

@Test func theToolReadsTheAppsInfoPlistBesideItsHelpersFolder() throws {
    let tool = try app(info: fudgeInfo)
    let info = FudgeVersion.info(bundle: [:], executable: tool)
    #expect(info?["CFBundleShortVersionString"] as? String == "0.3.0")
    #expect(info?["FudgeGitDescribe"] as? String == "v0.3.0")
}

@Test func theToolReadsItThroughASymlinkOnThePath() throws {
    let tool = try app(info: fudgeInfo)
    let link = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fudge")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
    #expect(FudgeVersion.info(bundle: nil, executable: link)?["CFBundleShortVersionString"] as? String == "0.3.0")
}

@Test func anotherProgramsVersionIsNeverTakenForFudges() throws {
    // A test runner's own bundle.
    let runner: [String: Any] = [
        "CFBundleIdentifier": "com.apple.dt.xctest.tool", "CFBundleShortVersionString": "16.0",
    ]
    #expect(FudgeVersion.info(bundle: runner, executable: URL(fileURLWithPath: "/usr/bin/xctest")) == nil)
    // A Helpers folder in another app, or one with no Info.plist.
    var other = fudgeInfo
    other["CFBundleIdentifier"] = "com.example.other"
    #expect(FudgeVersion.info(bundle: nil, executable: try app(info: other)) == nil)
    #expect(FudgeVersion.info(bundle: nil, executable: try app(info: nil)) == nil)
    // `swift run fudge` from .build.
    #expect(FudgeVersion.info(bundle: nil, executable: URL(fileURLWithPath: "/tmp/.build/debug/fudge")) == nil)
}

@Test func theVersionShownIsTheDescribesTagOrABuildAfterIt() {
    let cases: [(String, String)] = [
        // A tag.
        ("v0.3.0", "0.3.0"),
        ("v1.2.0-rc.1", "1.2.0-rc.1"),
        ("v0.3.0\n", "0.3.0"),
        // After a tag, or with changes: the tag's version, `dev`, and the rest as build metadata.
        ("v0.3.0-14-ga539cdd", "0.3.0-dev+14.a539cdd"),
        ("v0.3.0-14-ga539cdd-dirty", "0.3.0-dev+14.a539cdd.dirty"),
        ("v0.3.0-dirty", "0.3.0-dev+dirty"),
        ("v1.2.0-rc.1-3-gabc1234", "1.2.0-rc.1.dev+3.abc1234"),
        ("v1.2.0+build.7-2-gabc1234", "1.2.0-dev+2.abc1234"),
        // No version tag.
        ("a539cdd", "0.0.0-dev+a539cdd"),
        ("a539cdd-dirty", "0.0.0-dev+a539cdd.dirty"),
        ("nightly-3-gabc1234", "0.0.0-dev+abc1234"),
        ("v1.2", "0.0.0-dev"),
        ("dev", "0.0.0-dev"),
        ("", "0.0.0-dev"),
    ]
    for (describe, shown) in cases {
        #expect(FudgeVersion.display(describe: describe) == shown, "\(describe)")
    }
    // The update check reads the shown form as the tag's own version, so a build after v0.3.0 isn't told about it.
    for describe in ["v0.3.0", "v0.3.0-14-ga539cdd-dirty", "v1.2.0-rc.1-3-gabc1234", "v1.2.0+build.7-2-gabc1234"] {
        #expect(RunningVersion(FudgeVersion.display(describe: describe)) == RunningVersion(describe), "\(describe)")
    }
}
