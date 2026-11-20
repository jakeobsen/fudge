import Foundation
import FudgeCore

let usage = """
    Usage: fudge <command>

    Commands:
      help        Show this help.
      version     Print the fudge version.
    """

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print(FudgeVersion.current)
default:
    FileHandle.standardError.write(Data("fudge: unknown command '\(arguments[0])'\n\n\(usage)\n".utf8))
    exit(2)
}
