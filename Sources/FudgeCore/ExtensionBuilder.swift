import Foundation

/// An extension in fudge's extensions folder.
public struct InstalledExtension: Sendable, Equatable {
    public var manifest: ExtensionManifest
    public var directory: URL
    /// Its commands that use something Fudge doesn't support (`compatibility.json`, SPEC-109).
    public var compatibility: CommandCompatibility

    public init(manifest: ExtensionManifest, directory: URL, compatibility: CommandCompatibility = .init()) {
        self.manifest = manifest
        self.directory = directory
        self.compatibility = compatibility
    }

    /// The compiled command, a CommonJS file the extension host can load: `<command>.cjs` beside `package.json`, as
    /// Raycast installs it (`ExtensionLayout`). An install from before keeps it in `dist/` until `ExtensionLayout.moveUp`
    /// moves it, so a command that isn't at the root yet is found there.
    public func entry(for command: String) -> URL {
        let file = ExtensionLayout.file(for: command)
        let entry = directory.appendingPathComponent(file)
        let old = directory.appendingPathComponent(ExtensionLayout.oldFolder).appendingPathComponent(file)
        let files = FileManager.default
        return !files.fileExists(atPath: entry.path) && files.fileExists(atPath: old.path) ? old : entry
    }

    public var assetsDirectory: URL {
        directory.appendingPathComponent("assets", isDirectory: true)
    }

    public static func load(from directory: URL) throws -> InstalledExtension {
        InstalledExtension(
            manifest: try ExtensionManifest.load(from: directory.appendingPathComponent("package.json")),
            directory: directory,
            compatibility: CommandCompatibility.load(from: directory)
        )
    }

    /// Every installed extension, sorted by title. Folders that fail to load are skipped.
    public static func all(in extensionsDirectory: URL) -> [InstalledExtension] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: extensionsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return
            folders
            .compactMap { try? load(from: $0) }
            .sorted { $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending }
    }
}

public enum BuildError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case invalidCommandName(String)
    /// Two commands' names differ only in case. The Mac's disk ignores case by default, so their built files would
    /// overwrite each other.
    case commandNamesDifferOnlyInCase(String, String)
    case noCommands
    case missingEntry(command: String, searched: [String])
    /// The source folder is where the build would go, or one holds the other.
    case sourceIsDestination(String)
    /// Something that isn't an extension fudge built is in the way.
    case notAnInstall(String)
    /// The extension's dependencies need npm, and Fudge's own Node.js isn't beside the tool.
    case noNode

    public var description: String {
        switch self {
        case .invalidName(let name):
            "the extension name \"\(name)\" may use only a-z, 0-9, - and _, starting with a letter or digit"
        case .invalidCommandName(let name):
            "the command name \"\(name)\" may use only letters, digits, ., - and _, starting with a letter or digit"
        case .commandNamesDifferOnlyInCase(let one, let other):
            "the command names \"\(one)\" and \"\(other)\" differ only in case, so their built files would be one file"
        case .noCommands:
            "the extension declares no commands"
        case .missingEntry(let command, let searched):
            "no source file for the command \"\(command)\" (looked for \(searched.joined(separator: ", ")))"
        case .sourceIsDestination(let path):
            "the extension would be installed at \(path), which is its own source folder or overlaps it; "
                + "install it into another folder"
        case .notAnInstall(let path):
            "\(path) isn't an extension Fudge built, so it won't be replaced"
        case .noNode:
            "the extension's dependencies need npm, from Fudge's own Node.js, which isn't beside this fudge tool; "
                + "use the fudge inside Fudge.app"
        }
    }
}

/// Compiles a Raycast extension from its source folder and installs it.
///
/// The source folder is never written to. When the extension's dependencies
/// aren't installed there, they're installed into a temporary folder that
/// esbuild finds through `NODE_PATH`.
public struct ExtensionBuilder: Sendable {
    /// Modules the extension host provides, so they stay out of the bundle. `fudge:app` is Fudge's own calls for its
    /// bundled extensions (Search Files' `searchFiles`), not part of Raycast's API.
    public static let providedModules = [
        "@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime", "fudge:app",
    ]
    static let sourceExtensions = ["tsx", "ts", "jsx", "js"]

    public var esbuild: URL
    /// Fudge's own Node.js, whose npm installs an extension's dependencies (`Runtime.locateNode`).
    public var node: BundledNode?
    public var log: @Sendable (String) -> Void

    /// Finds which commands use something Fudge doesn't support, from the source folder (`fudge scan`, through
    /// `CompatScanner.commands`); nil skips it. A scan that throws leaves the install without `compatibility.json`,
    /// so every command is enabled, as before SPEC-109.
    public var scanCommands: (@Sendable (URL) throws -> CommandCompatibility)?

    public init(
        esbuild: URL, node: BundledNode? = nil, log: @escaping @Sendable (String) -> Void = { _ in },
        scanCommands: (@Sendable (URL) throws -> CommandCompatibility)? = nil
    ) {
        self.esbuild = esbuild
        self.node = node
        self.log = log
        self.scanCommands = scanCommands
    }

    @discardableResult
    public func build(source: URL, into extensionsDirectory: URL) throws -> InstalledExtension {
        let files = FileManager.default
        let manifest = try ExtensionManifest.load(from: source.appendingPathComponent("package.json"))
        guard ExtensionManifest.isValidName(manifest.name) else { throw BuildError.invalidName(manifest.name) }
        guard !manifest.commands.isEmpty else { throw BuildError.noCommands }
        try Self.checkCommandNames(manifest.commands.map(\.name))
        let entries = try manifest.commands.map { try Self.entry(for: $0.name, in: source) }
        try Self.checkDestination(extensionsDirectory.appendingPathComponent(manifest.name), source: source)

        // A signal that ends `fudge build` skips every `defer`, so the two folders are named to the signal's handler
        // too, which deletes them before the tool exits (`ChildProcesses.deleteOnSignal`).
        let children = ChildProcesses.shared
        let scratch = Self.temporaryDirectory().appendingPathComponent("fudge-build-\(UUID().uuidString)")
        children.deleteOnSignal(scratch)
        defer {
            try? files.removeItem(at: scratch)
            children.forget(scratch)
        }
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)

        var environment: [String: String] = [:]
        if manifest.hasDependencies, !files.fileExists(atPath: source.appendingPathComponent("node_modules").path) {
            log("installing dependencies")
            guard let node else { throw BuildError.noNode }
            environment["NODE_PATH"] = try Self.installDependencies(of: source, into: scratch, with: node).path
        }

        try files.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let staging = extensionsDirectory.appendingPathComponent(".staging-\(manifest.name)-\(UUID().uuidString)")
        children.deleteOnSignal(staging)
        defer {
            try? files.removeItem(at: staging)
            children.forget(staging)
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        log("compiling \(entries.count) command\(entries.count == 1 ? "" : "s")")
        // esbuild writes into a folder of its own, and only the commands move up beside `package.json`
        // (`ExtensionLayout`): anything else it writes, such as a stylesheet an import pulled in, no command loads, and
        // at the root it would make the next build refuse to replace the install (`holdsOnlyABuild`).
        let output = staging.appendingPathComponent(".compiled", isDirectory: true)
        let compiled = try Shell.run(
            esbuild,
            Self.esbuildArguments(entries: entries, source: source, output: output),
            in: source,
            environment: environment
        )
        let warnings = compiled.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !warnings.isEmpty { log(warnings) }
        for command in manifest.commands {
            let file = ExtensionLayout.file(for: command.name)
            try files.moveItem(at: output.appendingPathComponent(file), to: staging.appendingPathComponent(file))
        }
        try files.removeItem(at: output)

        var compatibility = CommandCompatibility()
        if let scanCommands {
            log("checking which commands use Raycast AI")
            do {
                compatibility = try scanCommands(source)
                try compatibility.write(to: staging)
            } catch {
                compatibility = CommandCompatibility()
                log("couldn't check, so every command is enabled: \(error)")
            }
        }

        try files.copyItem(
            at: source.appendingPathComponent("package.json"),
            to: staging.appendingPathComponent("package.json")
        )
        let assets = source.appendingPathComponent("assets")
        if files.fileExists(atPath: assets.path) {
            try files.copyItem(at: assets, to: staging.appendingPathComponent("assets"))
        }

        let destination = extensionsDirectory.appendingPathComponent(manifest.name, isDirectory: true)
        // From here the staging folder is the install: a signal no longer deletes it.
        children.forget(staging)
        try Self.replace(destination, with: staging)
        return InstalledExtension(manifest: manifest, directory: destination, compatibility: compatibility)
    }

    /// Refuses a command name that isn't valid (`ExtensionManifest.isValidCommandName`), and two that differ only in
    /// case, since the disk usually ignores case and their `<command>.cjs` files would be one file.
    static func checkCommandNames(_ names: [String]) throws {
        var seen: [String: String] = [:]
        for name in names {
            guard ExtensionManifest.isValidCommandName(name) else { throw BuildError.invalidCommandName(name) }
            if let other = seen[name.lowercased()], other != name {
                throw BuildError.commandNamesDifferOnlyInCase(other, name)
            }
            seen[name.lowercased()] = name
        }
    }

    static func entry(for command: String, in source: URL) throws -> URL {
        let candidates = sourceExtensions.map { "src/\(command).\($0)" }
        for candidate in candidates {
            let url = source.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw BuildError.missingEntry(command: command, searched: candidates)
    }

    static func esbuildArguments(entries: [URL], source: URL, output: URL) -> [String] {
        entries.map(\.path) + [
            "--bundle",
            "--platform=node",
            "--format=cjs",
            "--target=node22",
            "--jsx=automatic",
            "--outdir=\(output.path)",
            "--outbase=\(source.appendingPathComponent("src").path)",
            "--out-extension:.js=.cjs",
            "--define:process.env.NODE_ENV=\"production\"",
            "--legal-comments=none",
            "--log-level=warning",
        ] + providedModules.map { "--external:\($0)" }
    }

    /// Installs the extension's dependencies under `scratch` and returns the `node_modules` folder.
    static func installDependencies(of source: URL, into scratch: URL, with node: BundledNode) throws -> URL {
        let files = FileManager.default
        let project = scratch.appendingPathComponent("dependencies", isDirectory: true)
        try files.createDirectory(at: project, withIntermediateDirectories: true)
        var hasLockfile = false
        for name in ["package.json", "package-lock.json", "npm-shrinkwrap.json", ".npmrc"] {
            let file = source.appendingPathComponent(name)
            guard files.fileExists(atPath: file.path) else { continue }
            try files.copyItem(at: file, to: project.appendingPathComponent(name))
            if name.hasSuffix(".json"), name != "package.json" { hasLockfile = true }
        }
        // Install scripts stay off: the bundle only needs the packages' JavaScript. npm is Fudge's own, run by its
        // own Node.js.
        let npm = node.npm(
            [hasLockfile ? "ci" : "install", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"],
            environment: ProcessInfo.processInfo.environment)
        try Shell.run(npm.executable, npm.arguments, in: project, environment: npm.environment)
        return project.appendingPathComponent("node_modules", isDirectory: true)
    }

    /// What an install folder holds besides its commands' `<command>.cjs` files (`holdsOnlyABuild`). `dist` is where
    /// builds from before SPEC-123 put the commands, so a rebuild still replaces such an install.
    static let installedItems: Set<String> = [
        "package.json", ExtensionLayout.oldFolder, "assets", CommandCompatibility.fileName,
    ]

    /// Whether `directory` holds only what a build writes, hidden files aside: `installedItems`, and `<command>.cjs` for
    /// each command its own `package.json` names (`manifest`, read from there when it isn't given). A folder that
    /// doesn't exist holds nothing, so it does.
    static func holdsOnlyABuild(_ directory: URL, manifest: ExtensionManifest? = nil) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !installedItems.contains($0) }
        guard !names.isEmpty else { return true }
        guard
            let manifest = manifest
                ?? (try? ExtensionManifest.load(from: directory.appendingPathComponent("package.json")))
        else { return false }
        let commands = Set(manifest.commands.map { ExtensionLayout.file(for: $0.name) })
        return names.allSatisfy(commands.contains)
    }

    /// Refuses a destination that is the source folder, holds it or sits inside it, compared after resolving
    /// symlinks and ignoring case (the file system does), since replacing it would delete the source. Refuses
    /// anything there that isn't a fudge build too.
    static func checkDestination(_ destination: URL, source: URL) throws {
        func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
        let target = key(destination.deletingLastPathComponent()) + "/" + destination.lastPathComponent.lowercased()
        let origin = key(source)
        if origin == target || origin.hasPrefix(target + "/") || target.hasPrefix(origin + "/") {
            throw BuildError.sourceIsDestination(destination.path)
        }
        if !holdsOnlyABuild(destination) { throw BuildError.notAnInstall(destination.path) }
    }

    /// Where the build's scratch folder goes: an absolute `$TMPDIR` when it's set, as for any command-line tool, else
    /// the user's temporary folder. Foundation's `temporaryDirectory` doesn't read `TMPDIR` on macOS.
    static func temporaryDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let path = environment["TMPDIR"], path.hasPrefix("/") else {
            return FileManager.default.temporaryDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Moves `staging` to `destination`, replacing what's there.
    static func replace(_ destination: URL, with staging: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: destination.path) else {
            try files.moveItem(at: staging, to: destination)
            return
        }
        let old = destination.deletingLastPathComponent()
            .appendingPathComponent(".old-\(destination.lastPathComponent)-\(UUID().uuidString)")
        try files.moveItem(at: destination, to: old)
        do {
            try files.moveItem(at: staging, to: destination)
        } catch {
            try? files.moveItem(at: old, to: destination)
            throw error
        }
        try? files.removeItem(at: old)
    }

    /// Finds esbuild: `$FUDGE_ESBUILD`, then next to `executable` (as inside Fudge.app), then on `$PATH`.
    public static func locateEsbuild(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL
    ) -> URL? {
        let files = FileManager.default
        if let override = environment["FUDGE_ESBUILD"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let executable {
            let sibling = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(
                "esbuild")
            if files.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("esbuild")
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
