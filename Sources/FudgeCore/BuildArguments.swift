import Foundation

/// `fudge build <folder> [--into <extensions folder>] [--repository <repository folder>]
/// [--swift-parts build|leave-out] [--outcome <folder>]`. With `--into`, the extension is installed in that folder and
/// nowhere else; it must be an absolute path to a folder that exists. Without it, the default extensions folder.
/// `--repository` is the repository folder it goes in there (`raycast/extensions`, `owner/repository`); without it, or
/// with `fudgeapp/development`, it's a development build, in `fudgeapp/development` (FUD-183). `--swift-parts` says
/// what to do with a part written in Swift (SPEC-145 §2), and an extension with one needs it. With `--outcome`, an
/// absolute path to a folder that exists, the build writes its exit status there as it ends (`BuildOutcomeFile`,
/// SPEC-156 A.3).
public struct BuildArguments: Sendable, Equatable {
    public var source: URL
    public var destination: URL?
    /// The repository folder, as given; nil for none.
    public var repository: String?
    public var swiftParts: SwiftParts?
    public var outcome: URL?

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
        "usage: fudge build <folder> [--into <extensions folder>] [--repository <repository folder>] "
        + "[--swift-parts build|leave-out] [--outcome <folder>]"

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
        var repository: String?
        if let index = rest.firstIndex(of: "--repository") {
            guard index + 1 < rest.count else { throw Invalid(description: usage) }
            let folder = rest[index + 1]
            guard folder == ExtensionRepositoryFolder.raycast || ExtensionRepositoryFolder.isValid(folder) else {
                throw Invalid(
                    description:
                        "--repository takes a repository folder, such as raycast/extensions or owner/repository: \(folder)"
                )
            }
            repository = folder
            rest.removeSubrange(index...(index + 1))
        }
        let destination = try folder(after: "--into", in: &rest, isDirectory: isDirectory)
        let outcome = try folder(after: "--outcome", in: &rest, isDirectory: isDirectory)
        guard rest.count == 1, !rest[0].hasPrefix("--") else { throw Invalid(description: usage) }
        return BuildArguments(
            source: URL(fileURLWithPath: rest[0]).standardizedFileURL, destination: destination,
            repository: repository, swiftParts: swiftParts, outcome: outcome)
    }

    /// The folder after `option`, taken out of `rest`: an absolute path to a folder that exists.
    private static func folder(
        after option: String, in rest: inout [String], isDirectory: (String) -> Bool
    ) throws -> URL? {
        guard let index = rest.firstIndex(of: option) else { return nil }
        guard index + 1 < rest.count else { throw Invalid(description: usage) }
        let path = rest[index + 1]
        guard path.hasPrefix("/") else { throw Invalid(description: "\(option) needs an absolute path: \(path)") }
        guard isDirectory(path) else { throw Invalid(description: "\(option): no such folder: \(path)") }
        rest.removeSubrange(index...(index + 1))
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
