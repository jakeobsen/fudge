import Foundation
import FudgeCore

// The tool `make dmg-image` runs to lay out the disk image's Finder window (SPEC-150). It's built, never shipped.
let usage = """
    Usage: FudgeDiskImage <command>

    Commands:
      layout <volume>     Write the .DS_Store of the mounted, writable disk image at <volume>, whose picture
                          is already at .background/background.tiff.
      background <file>   Draw the window's picture into <file>, a TIFF at 1x and 2x.

    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("FudgeDiskImage: \(message)\n".utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("layout", 2):
    do {
        try DiskImageLayout.write(toVolume: URL(fileURLWithPath: arguments[1], isDirectory: true))
    } catch {
        fail("couldn't lay out \(arguments[1]): \(error)")
    }
case ("background", 2):
    do {
        try DiskImageBackground.tiff().write(to: URL(fileURLWithPath: arguments[1]))
    } catch {
        fail("couldn't draw \(arguments[1]): \(error)")
    }
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
