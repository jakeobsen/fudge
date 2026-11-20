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
      version         Print the fudge version.
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fudge: \(message)\n".utf8))
    exit(status)
}

func build(_ arguments: BuildArguments) {
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge inside Fudge.app")
    }
    let builder = ExtensionBuilder(esbuild: esbuild, log: { print("  \($0)") })
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
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    guard let script = CompatScanner.locateScript() else {
        fail(
            "can't find the compatibility scanner: set FUDGE_COMPAT_SCAN to compat-scan.js, or use the fudge inside Fudge.app"
        )
    }
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge inside Fudge.app")
    }
    guard let node = Runtime.locateNode(helpers: executable?.deletingLastPathComponent()) else {
        fail("can't find node: set FUDGE_NODE to its path")
    }
    let (nodeArguments, environment) = CompatScanner.invocation(
        script: script, esbuild: esbuild, arguments: arguments, environment: ProcessInfo.processInfo.environment)
    let process = Process()
    process.executableURL = node
    process.arguments = nodeArguments
    process.environment = environment
    do {
        try process.run()
    } catch {
        fail("couldn't run node: \(error)")
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print(FudgeVersion.current)
case "build":
    do {
        build(try BuildArguments.parse(Array(arguments.dropFirst())))
    } catch {
        fail(String(describing: error), status: 2)
    }
case "scan":
    do {
        scan(try ScanArguments.parse(Array(arguments.dropFirst())))
    } catch {
        fail(String(describing: error), status: 2)
    }
default:
    fail("unknown command '\(arguments[0])'\n\n\(usage)", status: 2)
}
