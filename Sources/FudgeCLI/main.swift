import Foundation
import FudgeCore

let usage = """
    Usage: fudge <command>

    Commands:
      build <folder> [--into <extensions folder>] [--swift-parts build|leave-out]
            [--outcome <folder>]
                      Compile the Raycast extension in <folder> and install it, in the
                      default extensions folder or, with --into, in that one.
                      An extension with a part written in Swift needs --swift-parts:
                      build it with Apple's Command Line Tools, or leave it out.
                      With --outcome, write <pid>.ended.json there as it ends.
      scan <folder> [--json]
                      Say what the extension in <folder> uses that Fudge doesn't have
                      yet. Nothing is built or run.
      help            Show this help.
      version         Print the Fudge version.
    """

/// `fudge build --outcome`'s outcome, written at whichever exit comes first (SPEC-156 A.3).
let outcome = BuildOutcomeRecorder()

/// Ends the tool with `status`, writing the build's outcome first when it was asked for.
func finish(_ status: Int32) -> Never {
    outcome.ended(status: status)
    exit(status)
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fudge: \(message)\n".utf8))
    finish(status)
}

/// The folder this tool really is in, links resolved: the bundle's `Contents/Helpers`, beside Fudge's own Node.js.
let helpers = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()

func build(_ arguments: BuildArguments) -> Never {
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge tool inside Fudge.app")
    }
    // Every build runs Fudge's own Node.js and its bundling script, both in the app; without them it stops, saying so.
    let node = Runtime.locateNode(helpers: helpers)
    var builder = ExtensionBuilder(
        esbuild: esbuild, node: node, bundler: ExtensionBuilder.locateBundler(), log: { print("  \($0)") })
    // Which commands use Raycast AI or the Browser Extension, so they're installed not enabled (SPEC-109).
    if let script = CompatScanner.locateScript(), let node = node?.node {
        builder.scanCommands = { source in
            try CompatScanner.commands(of: source, node: node, script: script, esbuild: esbuild)
        }
    } else {
        print("  can't find the compatibility scanner or node, so every command is enabled")
    }
    // A part written in Swift (SPEC-145 §2): built with the Command Line Tools that Settings → Development finds.
    builder.swiftParts = arguments.swiftParts
    builder.commandLineTools = {
        CommandLineTools.resolve(setting: FudgeSettings.load(from: FudgePaths.standard().settingsFile).commandLineTools)
            .tools
    }
    do {
        let installed = try builder.build(
            source: arguments.source, into: arguments.destination ?? FudgePaths.standard().extensionsDirectory)
        let count = installed.manifest.commands.count
        print("→ installed \(installed.manifest.title) (\(count) command\(count == 1 ? "" : "s"))")
        finish(0)
    } catch {
        // Another build of this extension into this folder: 75, which the Extension Store reads (SPEC-153 A).
        fail(String(describing: error), status: (error as? BuildError)?.exitStatus ?? 1)
    }
}

/// Runs the bundled compatibility scanner with node; its output and exit status are the command's.
func scan(_ arguments: ScanArguments) -> Never {
    guard let script = CompatScanner.locateScript() else {
        fail(
            "can't find the compatibility scanner: set FUDGE_COMPAT_SCAN to compat-scan.js, or use the fudge inside Fudge.app"
        )
    }
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge inside Fudge.app")
    }
    guard let node = Runtime.locateNode(helpers: helpers)?.node else {
        fail("can't find Fudge's own Node.js beside this fudge tool: use the fudge inside Fudge.app")
    }
    let (nodeArguments, environment) = CompatScanner.invocation(
        script: script, esbuild: esbuild, arguments: arguments, environment: ProcessInfo.processInfo.environment)
    let pid: pid_t
    do {
        pid = try ChildProcesses.shared.spawn(node, nodeArguments, environment: environment)
    } catch {
        fail("couldn't run node: \(error)")
    }
    exit(ChildProcesses.shared.wait(pid))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print(FudgeVersion.current)
case "build":
    // A signal that ends the tool (the Extension Store's timeout, ⌃C) ends npm and esbuild with it, and the outcome
    // says so.
    ChildProcesses.endChildrenOnSignals(beforeExit: { outcome.ended(status: $0) })
    let parsed: BuildArguments
    do {
        parsed = try BuildArguments.parse(Array(arguments.dropFirst()))
    } catch {
        fail(String(describing: error), status: 2)
    }
    if let folder = parsed.outcome { outcome.record(into: folder) }
    build(parsed)
case "scan":
    ChildProcesses.endChildrenOnSignals()
    do {
        scan(try ScanArguments.parse(Array(arguments.dropFirst())))
    } catch {
        fail(String(describing: error), status: 2)
    }
default:
    fail("unknown command '\(arguments[0])'\n\n\(usage)", status: 2)
}
