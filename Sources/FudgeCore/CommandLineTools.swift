import Foundation

/// Apple's Command Line Tools, which build the parts of extensions written in Swift (SPEC-145 §1): the folder Fudge
/// builds them with, chosen on Settings → Development (`commandLineTools` in `settings.json`) or found by itself.
/// The Development page, the Extension Store and `fudge build` all ask `resolve`, so they never disagree.
///
/// Found by itself means only `/Library/Developer/CommandLineTools` (D-117: Swift parts are built "only with Apple's
/// Command Line Tools"); Xcode is used only when the user chooses its folder.
///
/// Nothing here runs `/usr/bin/swift`, `xcrun` or any other of macOS's stubs in `/usr/bin`, which offer to install the
/// tools when they're missing: only a `swift` inside a folder, and only one that doesn't lead to a stub.
public enum CommandLineTools {
    /// Where `xcode-select --install` puts them.
    public static let defaultFolder = URL(fileURLWithPath: "/Library/Developer/CommandLineTools", isDirectory: true)

    /// Where the Command Line Tools keep `swift`.
    static let toolsSwiftPath = "usr/bin/swift"
    /// Where a chosen folder's `swift` is: the Command Line Tools' `usr/bin`, else Xcode's default toolchain, since
    /// Xcode's `Contents/Developer` has no `usr/bin/swift`.
    static let chosenSwiftPaths = [toolsSwiftPath, "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"]

    /// The oldest Swift that builds the parts: the floor of Raycast's Swift tools package. A package asking for more
    /// fails with SwiftPM's own message.
    public static let minimumVersion = SwiftVersion(major: 6, minor: 0)

    /// The Development page's words.
    public enum Text {
        public static let title = "Command Line Tools"
        public static let help = "Fudge uses these to build extensions with parts written in Swift."
        public static let notFound = "Not found"
        public static let tooOld = "Swift 6.0 or later is needed"
        public static let choose = "Choose…"
        public static let useDefault = "Use Default"
        public static let install = "Install…"
    }

    /// A Swift's version, as `swift --version` names it.
    public struct SwiftVersion: Sendable, Equatable, Comparable {
        public var major: Int
        public var minor: Int
        /// The version as written (`6.3.3`), which the Development page shows.
        public var text: String

        public init(major: Int, minor: Int, text: String? = nil) {
            self.major = major
            self.minor = minor
            self.text = text ?? "\(major).\(minor)"
        }

        public static func < (lhs: SwiftVersion, rhs: SwiftVersion) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }

        public static func == (lhs: SwiftVersion, rhs: SwiftVersion) -> Bool {
            (lhs.major, lhs.minor) == (rhs.major, rhs.minor)
        }

        /// The version after `Apple Swift version` in `swift --version`'s output, or nil. Never the first number: the
        /// first line starts `swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-…)`.
        public init?(versionOutput text: String) {
            guard let match = text.firstMatch(of: /Apple Swift version ((\d+)\.(\d+)(?:\.\d+)*)/),
                let major = Int(match.2), let minor = Int(match.3)
            else { return nil }
            self.init(major: major, minor: minor, text: String(match.1))
        }
    }

    /// Tools that build Swift parts: the developer folder (`DEVELOPER_DIR` for the build), its `swift`, and its
    /// version.
    public struct Tools: Sendable, Equatable {
        public var folder: URL
        public var swift: URL
        public var version: SwiftVersion

        public init(folder: URL, swift: URL, version: SwiftVersion) {
            self.folder = folder
            self.swift = swift
            self.version = version
        }
    }

    /// What `resolve` found.
    public enum Status: Sendable, Equatable {
        case found(Tools)
        /// A `swift` older than `minimumVersion`, which counts as not found.
        case tooOld(folder: URL, version: SwiftVersion)
        case notFound

        public var tools: Tools? {
            if case .found(let tools) = self { tools } else { nil }
        }

        /// The Development page's status line: `Swift 6.3.3`, or why there are none.
        public var line: String {
            switch self {
            case .found(let tools): "Swift \(tools.version.text)"
            case .tooOld: Text.tooOld
            case .notFound: Text.notFound
            }
        }
    }

    /// What `resolve` asks of the Mac, so tests answer for it.
    public protocol System: Sendable {
        /// Whether an executable file is at `path`, links followed.
        func isExecutable(_ path: String) -> Bool
        /// `path` with every link resolved.
        func realPath(_ path: String) -> String
        /// What `swift --version` prints on stdout, or nil when it fails.
        func versionOutput(of swift: URL) -> String?
    }

    /// The setting's folder when it's set, else `defaultFolder`, only with a `swift` of `minimumVersion` or later. A
    /// chosen folder is the only one looked at, so a choice that doesn't work says so rather than falling back.
    public static func resolve(setting: String?, system: System = MacSystem()) -> Status {
        if let setting, let folder = folder(setting: setting) {
            return status(of: folder, swiftPaths: chosenSwiftPaths, system: system)
        }
        return status(of: defaultFolder, swiftPaths: [toolsSwiftPath], system: system)
    }

    /// The setting's folder: an absolute path, else nil, which reads as unset.
    public static func folder(setting: String) -> URL? {
        guard setting.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: setting, isDirectory: true).standardizedFileURL
    }

    /// The tools in `folder`, if its `swift` (the first of `swiftPaths` there) runs and is new enough.
    static func status(of folder: URL, swiftPaths: [String], system: System) -> Status {
        guard let swift = swift(in: folder, swiftPaths: swiftPaths, system: system),
            let output = system.versionOutput(of: swift),
            let version = SwiftVersion(versionOutput: output)
        else { return .notFound }
        guard version >= minimumVersion else { return .tooOld(folder: folder, version: version) }
        return .found(Tools(folder: folder, swift: swift, version: version))
    }

    /// `folder`'s `swift`, never one that is, or leads to, a stub in `/usr/bin`: a chosen folder of `/` would otherwise
    /// name `/usr/bin/swift`, which offers to install the tools.
    static func swift(in folder: URL, swiftPaths: [String], system: System) -> URL? {
        for path in swiftPaths {
            let swift = folder.appendingPathComponent(path).standardizedFileURL
            guard system.isExecutable(swift.path) else { continue }
            let real = system.realPath(swift.path)
            if real.hasPrefix("/usr/bin/") || swift.path.hasPrefix("/usr/bin/") { continue }
            return swift
        }
        return nil
    }

    /// Install…: `xcode-select --install`, which shows Apple's own prompt to download the tools and returns. Nil once
    /// the prompt is up, else what `xcode-select` said (the tools are installed already, say).
    public static func requestInstall() -> String? {
        do {
            try Shell.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["--install"])
            return nil
        } catch let error as ShellError {
            let said = error.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty ? "xcode-select exited with \(error.status)" : said
        } catch {
            return String(describing: error)
        }
    }

    /// A snapshot run's fixed answer (`--command-line-tools found|old|missing`): the Command Line Tools in their usual
    /// folder with a made-up Swift 6.3.3, a Swift 5.10 there, or nothing. Anything else is nothing.
    public static func fixedStatus(_ name: String?) -> Status {
        let swift = defaultFolder.appendingPathComponent(toolsSwiftPath)
        switch name {
        case "found":
            return .found(
                Tools(folder: defaultFolder, swift: swift, version: SwiftVersion(major: 6, minor: 3, text: "6.3.3")))
        case "old":
            return .tooOld(folder: defaultFolder, version: SwiftVersion(major: 5, minor: 10))
        default:
            return .notFound
        }
    }

    /// The real Mac: `FileManager`, `realpath(3)` and the folder's own `swift`.
    public struct MacSystem: System {
        public init() {}

        public func isExecutable(_ path: String) -> Bool {
            FileManager.default.isExecutableFile(atPath: path)
        }

        public func realPath(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        public func versionOutput(of swift: URL) -> String? {
            try? Shell.run(swift, ["--version"], discardingErrors: true).output
        }
    }
}
