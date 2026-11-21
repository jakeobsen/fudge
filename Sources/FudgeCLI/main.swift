import Foundation
import FudgeCore

let usage = """
    Usage: fudge <command>

    Commands:
      build <folder> [--into <extensions folder>]
                      Compile the Raycast extension in <folder> and install it, in the
                      default extensions folder or, with --into, in that one.
      scan <folder> [--json]
                      Say what the extension in <folder> uses that Fudge doesn't have
                      yet. Nothing is built or run.
      help            Show this help.
      version         Print the Fudge version.
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fudge: \(message)\n".utf8))
    exit(status)
}

/// The folder this tool really is in, links resolved: the bundle's `Contents/Helpers`, beside Fudge's own Node.js.
let helpers = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()

func build(_ arguments: BuildArguments) {
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge tool inside Fudge.app")
    }
    // Node.js is needed only for an extension's dependencies; one without them builds without it.
    let node = Runtime.locateNode(helpers: helpers)
    var builder = ExtensionBuilder(esbuild: esbuild, node: node, log: { print("  \($0)") })
    // Which commands use Raycast AI or the Browser Extension, so they're installed not enabled (SPEC-109).
    if let script = CompatScanner.locateScript(), let node = node?.node {
        builder.scanCommands = { source in
            try CompatScanner.commands(of: source, node: node, script: script, esbuild: esbuild)
        }
    } else {
        print("  can't find the compatibility scanner or node, so every command is enabled")
    }
    do {
        let installed = try builder.build(
            source: arguments.source, into: arguments.destination ?? FudgePaths.standard().extensionsDirectory)
        let count = installed.manifest.commands.count
        print("→ installed \(installed.manifest.title) (\(count) command\(count == 1 ? "" : "s"))")
    } catch {
        fail(String(describing: error))
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
    // A signal that ends the tool (the Extension Store's timeout, ⌃C) ends npm and esbuild with it.
    ChildProcesses.endChildrenOnSignals()
    do {
        build(try BuildArguments.parse(Array(arguments.dropFirst())))
    } catch {
        fail(String(describing: error), status: 2)
    }
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
