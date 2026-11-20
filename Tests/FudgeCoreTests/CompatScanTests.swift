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
        environment: ["PATH": "/usr/bin"])
    #expect(arguments == ["/app/Resources/runtime/compat-scan.js", "/ext/greeter", "--json"])
    #expect(
        environment == [
            "PATH": "/usr/bin", "FUDGE_ESBUILD": "/app/Helpers/esbuild",
            "FUDGE_RAYCAST_TYPES": "/app/Resources/runtime/raycast-api.d.ts",
        ])
}
