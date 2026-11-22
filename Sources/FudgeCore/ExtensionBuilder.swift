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
    /// Compiling runs Fudge's own Node.js and its bundling script (`ExtensionBuilder.locateBundler`), and one of them
    /// isn't beside the tool.
    case noBundler
    /// The compile step exited with `status`, and `output` is what esbuild printed. The step is named rather than its
    /// command, which holds a request file that's deleted with the build's scratch folder.
    case compileFailed(status: Int32, output: String)
    /// Another build of this extension into this folder holds its lock (`ExtensionBuilder.lockBuild`), so this one
    /// stopped before writing anything. The name and the extensions folder.
    case alreadyBuilding(String, String)
    /// The build's lock file couldn't be opened or locked, for a reason other than another build holding it.
    case cantLock(path: String, reason: String)

    /// `fudge build`'s exit status for `alreadyBuilding` (`EX_TEMPFAIL`), which it uses for nothing else; the Extension
    /// Store reads it (`alreadyBuildingStatus` in `store.ts`), and `runtime/test/fixtures/build-statuses.json` pins both.
    public static let alreadyBuildingStatus: Int32 = 75

    /// The exit status `fudge build` ends with for this error.
    public var exitStatus: Int32 {
        if case .alreadyBuilding = self { return Self.alreadyBuildingStatus }
        return 1
    }

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
        case .noBundler:
            "compiling needs Fudge's own Node.js and its bundling script, which aren't beside this fudge tool; "
                + "use the fudge inside Fudge.app"
        case .compileFailed(let status, let output):
            ShellError.describe("compiling the extension", status: status, output: output)
        case .alreadyBuilding(let name, let folder):
            "another fudge build is installing \(name) into \(folder); try again when it has finished"
        case .cantLock(let path, let reason):
            "couldn't lock \(path): \(reason)"
        }
    }
}

/// Compiles a Raycast extension from its source folder and installs it.
///
/// It compiles with esbuild's JavaScript API, through the bundling script (`bundle-extension.cjs`, from
/// `runtime/scripts/compile/`) run by Fudge's own Node.js, so the `rust:` and `swift:` imports get their plugins.
///
/// The source folder is never written to. When the extension's dependencies
/// aren't installed there, they're installed into a temporary folder that
/// esbuild finds through `nodePaths`.
public struct ExtensionBuilder: Sendable {
    /// Modules the extension host provides, so they stay out of the bundle. `fudge:app` is Fudge's own calls for its
    /// bundled extensions (Search Files' `searchFiles`), not part of Raycast's API.
    public static let providedModules = [
        "@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime", "fudge:app",
    ]
    static let sourceExtensions = ["tsx", "ts", "jsx", "js"]

    public var esbuild: URL
    /// Fudge's own Node.js, which runs the bundling script, and whose npm installs an extension's dependencies
    /// (`Runtime.locateNode`).
    public var node: BundledNode?
    /// The bundling script (`locateBundler`), which drives `esbuild` through its JavaScript API.
    public var bundler: URL?
    public var log: @Sendable (String) -> Void

    /// Finds which commands use something Fudge doesn't support, from the source folder (`fudge scan`, through
    /// `CompatScanner.commands`); nil skips it. A scan that throws leaves the install without `compatibility.json`,
    /// so every command is enabled, as before SPEC-109.
    public var scanCommands: (@Sendable (URL) throws -> CommandCompatibility)?

    /// What to do with the extension's parts written in Swift (`--swift-parts`, SPEC-145 §2); nil when it wasn't said,
    /// which stops the build of an extension that has one.
    public var swiftParts: BuildArguments.SwiftParts?
    /// Apple's Command Line Tools for `--swift-parts build`, found as Settings → Development finds them
    /// (`CommandLineTools.resolve`), or nil when they aren't set up. Asked only when a build may need them.
    public var commandLineTools: @Sendable () -> CommandLineTools.Tools? = { nil }
    /// SwiftPM's shared cache (`FudgePaths.swiftPackageCache`).
    public var swiftPackageCache = FudgePaths.swiftPackageCache()
    /// Called with the build's lock held, just before the finished build replaces the install: a seam for the test of
    /// two builds of one extension racing to `replace`.
    var beforeReplace: (@Sendable () -> Void)?

    public init(
        esbuild: URL, node: BundledNode? = nil, bundler: URL? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in },
        scanCommands: (@Sendable (URL) throws -> CommandCompatibility)? = nil
    ) {
        self.esbuild = esbuild
        self.node = node
        self.bundler = bundler
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
        // One build of this extension into this folder at a time (SPEC-153 A): a second stops here, before writing
        // anything. The kernel drops the lock when this process ends, however it ends.
        try files.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let lock = try Self.lockBuild(of: manifest.name, in: extensionsDirectory)
        defer { Self.unlockBuild(lock) }
        try Self.checkDestination(extensionsDirectory.appendingPathComponent(manifest.name), source: source)
        // Every build runs Fudge's own Node.js: the bundling script compiles, and its npm installs the dependencies.
        let installsDependencies =
            manifest.hasDependencies && !files.fileExists(atPath: source.appendingPathComponent("node_modules").path)
        if installsDependencies, node == nil { throw BuildError.noNode }
        guard let node, let bundler else { throw BuildError.noBundler }

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

        var nodePaths: [String] = []
        if installsDependencies {
            log("installing dependencies")
            nodePaths = [try Self.installDependencies(of: source, into: scratch, with: node).path]
        }

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
        // A part written in Swift is built, or left out, by the bundling script's `swift:` plugin, in the scratch
        // folder; the tools are looked for only when they may be needed.
        let tools = swiftParts == .build ? commandLineTools() : nil
        let swift = SwiftRequest(mode: swiftParts, tools: tools, cache: swiftPackageCache, scratch: scratch)
        let compiled = try Self.compile(
            BundleRequest(
                extensionFolder: source.path,
                options: BundleOptions(entries: entries, source: source, output: output, nodePaths: nodePaths),
                swift: swift),
            in: source, scratch: scratch, esbuild: esbuild, node: node.node, bundler: bundler,
            environment: tools.map { ["DEVELOPER_DIR": $0.folder.path] } ?? [:])
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
        try Self.installSwiftParts(swift, into: staging)

        let destination = extensionsDirectory.appendingPathComponent(manifest.name, isDirectory: true)
        // From here the staging folder is the install: a signal no longer deletes it.
        children.forget(staging)
        beforeReplace?()
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

    /// esbuild's options for the compile step: one for one what `fudge build` passed esbuild's command line before
    /// SPEC-144 (`--bundle`, `--platform=node`, `--format=cjs`, …), so an extension without `rust:` or `swift:` imports
    /// compiles to the same bytes. `nodePaths` stands for `NODE_PATH`, which esbuild's JavaScript API doesn't read.
    struct BundleOptions: Encodable, Equatable {
        var entryPoints: [String]
        var bundle = true
        var platform = "node"
        var format = "cjs"
        var target = "node22"
        var jsx = "automatic"
        var outdir: String
        var outbase: String
        var outExtension = [".js": ".cjs"]
        var define = ["process.env.NODE_ENV": "\"production\""]
        var legalComments = "none"
        var logLevel = "warning"
        /// The command line's default: it shows 6 messages and says how many there were. The JavaScript API's default
        /// is no limit.
        var logLimit = 6
        var external = ExtensionBuilder.providedModules
        var nodePaths: [String]

        init(entries: [URL], source: URL, output: URL, nodePaths: [String]) {
            entryPoints = entries.map(\.path)
            outdir = output.path
            outbase = source.appendingPathComponent("src").path
            self.nodePaths = nodePaths
        }
    }

    /// What the bundling script reads: the extension's folder (the one holding `package.json`, which a `rust:` import
    /// mustn't leave) and esbuild's options.
    struct BundleRequest: Encodable, Equatable {
        var extensionFolder: String
        var options: BundleOptions
        var swift: SwiftRequest

        enum CodingKeys: String, CodingKey {
            case extensionFolder = "extension"
            case options
            case swift
        }
    }

    /// What the `swift:` plugin is told (`SwiftRequest` in `scripts/compile/swift.ts`): the mode, the tools' `swift`,
    /// SwiftPM's cache, where it builds, where the programs go, and where it says which mode each package got.
    struct SwiftRequest: Encodable, Equatable {
        var mode: String?
        var swift: String?
        var cache: String
        var scratch: String
        var binaries: String
        var report: String

        init(mode: BuildArguments.SwiftParts?, tools: CommandLineTools.Tools?, cache: URL, scratch: URL) {
            self.mode = mode?.rawValue
            swift = tools?.swift.path
            self.cache = cache.path
            self.scratch = scratch.appendingPathComponent("swift", isDirectory: true).path
            binaries = scratch.appendingPathComponent("swift-programs", isDirectory: true).path
            report = scratch.appendingPathComponent("swift-parts-report.json").path
        }
    }

    /// Where Raycast's JavaScript runs a Swift part's program: `assets/compiled_raycast_swift/<package folder name>`.
    static let swiftProgramsFolder = "assets/compiled_raycast_swift"

    /// Puts the programs the `swift:` plugin built (mode 755) into the install, over any of the same name the
    /// extension's own `assets` held, and records what was done with its Swift parts (`SwiftPartsRecord`).
    static func installSwiftParts(_ swift: SwiftRequest, into staging: URL) throws {
        let files = FileManager.default
        let programs = URL(fileURLWithPath: swift.binaries, isDirectory: true)
        let names = (try? files.contentsOfDirectory(atPath: programs.path)) ?? []
        if !names.isEmpty {
            let folder = staging.appendingPathComponent(swiftProgramsFolder, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in names {
                let destination = folder.appendingPathComponent(name)
                if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                // The plugin made it mode 755, which the copy keeps.
                try files.copyItem(at: programs.appendingPathComponent(name), to: destination)
            }
        }
        if let record = SwiftPartsRecord(report: URL(fileURLWithPath: swift.report)) {
            try record.write(to: staging)
        }
    }

    /// Runs the bundling script on `request`, written into `scratch`, with Fudge's own Node.js in the extension's
    /// folder, driving `esbuild` (`ESBUILD_BINARY_PATH`), with `environment` added to the one `fudge build` has
    /// (`DEVELOPER_DIR` for a part written in Swift), nothing else added and nothing taken away. esbuild prints its
    /// warnings and errors as its command line does, and a failure is `BuildError.compileFailed` holding them.
    static func compile(
        _ request: BundleRequest, in source: URL, scratch: URL, esbuild: URL, node: URL, bundler: URL,
        environment: [String: String] = [:]
    ) throws -> ShellResult {
        let file = scratch.appendingPathComponent("bundle-request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(request).write(to: file)
        do {
            return try Shell.run(
                node, [bundler.path, file.path], in: source,
                environment: environment.merging(["ESBUILD_BINARY_PATH": esbuild.path]) { _, new in new })
        } catch let failure as ShellError {
            throw BuildError.compileFailed(status: failure.status, output: failure.output)
        }
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
        "package.json", ExtensionLayout.oldFolder, "assets", CommandCompatibility.fileName, SwiftPartsRecord.fileName,
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

    /// The lock file of the builds of `name` into `extensionsDirectory`: a dot file, which the watcher, the layout and
    /// `InstalledExtension.all` skip. It stays after the build, since deleting a lock file another build may have open
    /// would break the lock.
    static func lockFile(of name: String, in extensionsDirectory: URL) -> URL {
        extensionsDirectory.appendingPathComponent(".build-\(name).lock")
    }

    /// Takes the exclusive lock of the builds of `name` into `extensionsDirectory`, without waiting, and returns its
    /// descriptor, which the caller gives back with `unlockBuild`. Another build holding it throws `alreadyBuilding`.
    /// The lock belongs to this open of the file, so a second open in this process conflicts too, and the kernel drops
    /// it when the process ends.
    /// `O_CLOEXEC` keeps it out of any program the build starts, on top of `ChildProcesses.spawn`'s
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a child left running never holds it.
    static func lockBuild(of name: String, in extensionsDirectory: URL) throws -> Int32 {
        let file = lockFile(of: name, in: extensionsDirectory)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw BuildError.cantLock(path: file.path, reason: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { throw BuildError.alreadyBuilding(name, extensionsDirectory.path) }
            throw BuildError.cantLock(path: file.path, reason: String(cString: strerror(error)))
        }
        return descriptor
    }

    /// Releases the lock `lockBuild` took, then closes its descriptor. The lock belongs to the open file description,
    /// and `close` alone releases it only when no other process shares that description. A program another thread is
    /// starting holds a copy of every descriptor from `posix_spawn`'s copy of the table until its exec drops the
    /// close-on-exec ones (`O_CLOEXEC` and `POSIX_SPAWN_CLOEXEC_DEFAULT` act only then), so for that moment it would
    /// keep the lock, and the next build of the name in this process would be refused. `LOCK_UN` releases it on the
    /// description itself, whoever holds a copy.
    static func unlockBuild(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
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

    /// The bundling script: `$FUDGE_BUNDLER`, else `Contents/Resources/runtime/bundle-extension.cjs` beside the tool in
    /// `Contents/Helpers`, as `make app` puts it.
    public static func locateBundler(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL
    ) -> URL? {
        if let override = environment["FUDGE_BUNDLER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let executable else { return nil }
        let script = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../Resources/runtime/bundle-extension.cjs").standardizedFileURL
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
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
