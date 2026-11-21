import Foundation
import Testing

@testable import FudgeCore

@Test func scanArgumentsTakeOneFolderAndJSON() throws {
    let folder = { (path: String) in path == "/ext/greeter" }
    #expect(
        try ScanArguments.parse(["/ext/greeter"], isDirectory: folder)
            == ScanArguments(folder: URL(fileURLWithPath: "/ext/greeter"), json: false))
    #expect(try ScanArguments.parse(["--json", "/ext/greeter"], isDirectory: folder).json)
    #expect(try ScanArguments.parse(["/ext/greeter", "--json"], isDirectory: folder).json)
    for wrong in [[], ["--json"], ["/ext/greeter", "/ext/other"], ["--into", "/ext/greeter"]] {
        #expect(throws: ScanArguments.Invalid(description: ScanArguments.usage)) {
            try ScanArguments.parse(wrong, isDirectory: { _ in true })
        }
    }
    #expect(throws: ScanArguments.Invalid(description: "no such folder: /nope")) {
        try ScanArguments.parse(["/nope"], isDirectory: folder)
    }
}

@Test func theScannerIsFoundInTheAppsResourcesOrThroughTheEnvironment() throws {
    let app = try Fixtures.temporaryDirectory().appendingPathComponent("Fudge.app/Contents")
    let tool = app.appendingPathComponent("Helpers/fudge")
    let script = app.appendingPathComponent("Resources/runtime/compat-scan.js")
    try FileManager.default.createDirectory(
        at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(CompatScanner.locateScript(environment: [:], executable: tool) == nil, "not built into the app")
    try Data().write(to: script)
    #expect(CompatScanner.locateScript(environment: [:], executable: tool)?.path == script.standardizedFileURL.path)
    #expect(
        CompatScanner.locateScript(environment: ["FUDGE_COMPAT_SCAN": "/dev/scan.js"], executable: tool)?.path
            == "/dev/scan.js")
    #expect(CompatScanner.types(beside: script).lastPathComponent == "raycast-api.d.ts")
}

@Test func theScannerRunsWithEsbuildAndRaycastsTypes() {
    let (arguments, environment) = CompatScanner.invocation(
        script: URL(fileURLWithPath: "/app/Resources/runtime/compat-scan.js"),
        esbuild: URL(fileURLWithPath: "/app/Helpers/esbuild"),
        arguments: ScanArguments(folder: URL(fileURLWithPath: "/ext/greeter"), json: true),
        environment: ["PATH": "/usr/bin"], fileExists: { $0 == "/app/Resources/runtime/raycast-api.d.ts" })
    #expect(arguments == ["/app/Resources/runtime/compat-scan.js", "/ext/greeter", "--json"])
    #expect(
        environment == [
            "PATH": "/usr/bin", "FUDGE_ESBUILD": "/app/Helpers/esbuild",
            "FUDGE_RAYCAST_TYPES": "/app/Resources/runtime/raycast-api.d.ts",
        ])
}

@Test func aUsersRaycastTypesWinAndAScriptWithoutTypesBesideItReadsItsOwn() {
    let scan = ScanArguments(folder: URL(fileURLWithPath: "/ext/greeter"), json: false)
    let esbuild = URL(fileURLWithPath: "/app/Helpers/esbuild")
    let bundled = URL(fileURLWithPath: "/app/Resources/runtime/compat-scan.js")
    let set = CompatScanner.invocation(
        script: bundled, esbuild: esbuild, arguments: scan, environment: ["FUDGE_RAYCAST_TYPES": "/mine/index.d.ts"],
        fileExists: { _ in true }
    ).environment
    #expect(set["FUDGE_RAYCAST_TYPES"] == "/mine/index.d.ts", "the user's own value wins")
    // The CLI's own hint: FUDGE_COMPAT_SCAN=runtime/dist/compat-scan.js, with no types beside it.
    let checkout = CompatScanner.invocation(
        script: URL(fileURLWithPath: "/repo/runtime/dist/compat-scan.js"), esbuild: esbuild, arguments: scan,
        environment: ["FUDGE_RAYCAST_TYPES": ""], fileExists: { _ in false }
    ).environment
    #expect(checkout["FUDGE_RAYCAST_TYPES", default: ""].isEmpty, "the script falls back to the vendored types")
    #expect(checkout["FUDGE_ESBUILD"] == esbuild.path)
}
