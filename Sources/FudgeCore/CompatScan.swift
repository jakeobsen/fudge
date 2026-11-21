import Foundation

/// `fudge scan <folder> [--json]`: the compatibility scan of one extension, as the Extension Store runs it before an
/// install. The scanner is TypeScript (`runtime/scripts/compat/fudge-scan.ts`), bundled into `compat-scan.js`; the
/// tool runs it with node and tells it where esbuild's binary and Raycast's types are.
public struct ScanArguments: Sendable, Equatable {
    public var folder: URL
    public var json: Bool

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let usage = "usage: fudge scan <folder> [--json]"

    /// Reads the arguments after `scan`. `isDirectory` is injected so tests don't touch the disk.
    public static func parse(
        _ arguments: [String], isDirectory: (String) -> Bool = BuildArguments.isDirectory
    ) throws -> ScanArguments {
        let json = arguments.contains("--json")
        let rest = arguments.filter { $0 != "--json" }
        guard rest.count == 1, !rest[0].hasPrefix("--") else { throw Invalid(description: usage) }
        guard isDirectory(rest[0]) else { throw Invalid(description: "no such folder: \(rest[0])") }
        return ScanArguments(folder: URL(fileURLWithPath: rest[0]).standardizedFileURL, json: json)
    }
}

public enum CompatScanner {
    /// The bundled scanner: `$FUDGE_COMPAT_SCAN`, else `Contents/Resources/runtime/compat-scan.js` beside the tool
    /// in `Contents/Helpers`.
    public static func locateScript(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL
    ) -> URL? {
        if let override = environment["FUDGE_COMPAT_SCAN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let executable else { return nil }
        let script = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../Resources/runtime/compat-scan.js").standardizedFileURL
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    /// Raycast's types, which the scanner reads to tell Raycast's API from other paths: `raycast-api.d.ts` beside
    /// the script, as `make app` puts it.
    public static func types(beside script: URL) -> URL {
        script.deletingLastPathComponent().appendingPathComponent("raycast-api.d.ts")
    }

    /// Which commands of the extension in `folder` use something Fudge doesn't support: `fudge scan --json`'s
    /// per-command results, read from its stdout alone. Throws when the scan fails or its report has none.
    public static func commands(
        of folder: URL, node: URL, script: URL, esbuild: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CommandCompatibility {
        let (arguments, environment) = invocation(
            script: script, esbuild: esbuild, arguments: ScanArguments(folder: folder, json: true),
            environment: environment)
        let result = try Shell.run(node, arguments, environment: environment, discardingErrors: true)
        guard let compatibility = CommandCompatibility(report: Data(result.output.utf8)) else {
            throw ScanArguments.Invalid(description: "the scan's report had no commands")
        }
        return compatibility
    }

    /// node's arguments and environment for the scan: the script, the folder and `--json`; `FUDGE_ESBUILD` added to
    /// `environment`, and `FUDGE_RAYCAST_TYPES` only when it isn't set already and the types are beside the script.
    /// So a value the user set wins, and a script with no types beside it (`FUDGE_COMPAT_SCAN` pointing at
    /// `runtime/dist/compat-scan.js` in a checkout) reads the vendored ones itself. `fileExists` is injected for tests.
    public static func invocation(
        script: URL, esbuild: URL, arguments: ScanArguments, environment: [String: String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (arguments: [String], environment: [String: String]) {
        var environment = environment
        environment["FUDGE_ESBUILD"] = esbuild.path
        let types = types(beside: script)
        if environment["FUDGE_RAYCAST_TYPES", default: ""].isEmpty, fileExists(types.path) {
            environment["FUDGE_RAYCAST_TYPES"] = types.path
        }
        return ([script.path, arguments.folder.path] + (arguments.json ? ["--json"] : []), environment)
    }
}
