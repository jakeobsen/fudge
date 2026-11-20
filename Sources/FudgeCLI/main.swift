import Foundation
import FudgeCore

let usage = """
    Usage: fudge <command>

    Commands:
      build <folder> [--into <extensions folder>]
                      Compile the Raycast extension in <folder> and install it, in the
                      default extensions folder or, with --into, in that one.
      help            Show this help.
      version         Print the fudge version.
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fudge: \(message)\n".utf8))
    exit(status)
}

func build(_ arguments: BuildArguments) {
    guard let esbuild = ExtensionBuilder.locateEsbuild() else {
        fail("can't find esbuild: set FUDGE_ESBUILD to its path, or use the fudge tool inside Fudge.app")
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
default:
    fail("unknown command '\(arguments[0])'\n\n\(usage)", status: 2)
}
