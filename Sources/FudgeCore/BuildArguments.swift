import Foundation

/// `fudge build <folder> [--into <extensions folder>]`. With `--into`, the extension is installed in that folder and
/// nowhere else; it must be an absolute path to a folder that exists. Without it, the default extensions folder.
public struct BuildArguments: Sendable, Equatable {
    public var source: URL
    public var destination: URL?

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let usage = "usage: fudge build <folder> [--into <extensions folder>]"

    /// Reads the arguments after `build`. `fileExists` is injected so tests don't touch the disk.
    public static func parse(
        _ arguments: [String], isDirectory: (String) -> Bool = BuildArguments.isDirectory
    ) throws -> BuildArguments {
        var rest = arguments
        var destination: URL?
        if let index = rest.firstIndex(of: "--into") {
            guard index + 1 < rest.count else { throw Invalid(description: usage) }
            let path = rest[index + 1]
            guard path.hasPrefix("/") else { throw Invalid(description: "--into needs an absolute path: \(path)") }
            guard isDirectory(path) else { throw Invalid(description: "--into: no such folder: \(path)") }
            destination = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            rest.removeSubrange(index...(index + 1))
        }
        guard rest.count == 1, !rest[0].hasPrefix("--") else { throw Invalid(description: usage) }
        return BuildArguments(source: URL(fileURLWithPath: rest[0]).standardizedFileURL, destination: destination)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
