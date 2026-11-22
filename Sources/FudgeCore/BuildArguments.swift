import Foundation

/// `fudge build <folder> [--into <extensions folder>] [--swift-parts build|leave-out]`. With `--into`, the extension is
/// installed in that folder and nowhere else; it must be an absolute path to a folder that exists. Without it, the
/// default extensions folder. `--swift-parts` says what to do with a part written in Swift (SPEC-145 §2), and an
/// extension with one needs it.
public struct BuildArguments: Sendable, Equatable {
    public var source: URL
    public var destination: URL?
    public var swiftParts: SwiftParts?

    /// What `fudge build` does with an extension's parts written in Swift (`swift:` imports).
    public enum SwiftParts: String, Sendable, Equatable, CaseIterable {
        /// Build each with Apple's Command Line Tools (`CommandLineTools.resolve`).
        case build
        /// Install without them: their functions refuse every call.
        case leaveOut = "leave-out"
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let usage =
        "usage: fudge build <folder> [--into <extensions folder>] [--swift-parts build|leave-out]"

    /// Reads the arguments after `build`. `fileExists` is injected so tests don't touch the disk.
    public static func parse(
        _ arguments: [String], isDirectory: (String) -> Bool = BuildArguments.isDirectory
    ) throws -> BuildArguments {
        var rest = arguments
        var swiftParts: SwiftParts?
        if let index = rest.firstIndex(of: "--swift-parts") {
            guard index + 1 < rest.count, let choice = SwiftParts(rawValue: rest[index + 1]) else {
                throw Invalid(description: "--swift-parts takes build or leave-out")
            }
            swiftParts = choice
            rest.removeSubrange(index...(index + 1))
        }
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
        return BuildArguments(
            source: URL(fileURLWithPath: rest[0]).standardizedFileURL, destination: destination, swiftParts: swiftParts)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
