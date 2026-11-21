import Foundation

/// Where an install keeps its compiled commands (SPEC-123). `fudge build` writes each as `<extension>/<command>.cjs`,
/// beside `package.json` and `assets/`, as Raycast installs them, so a command's `__dirname` is the extension's folder
/// and `${__dirname}/assets/…` is its assets. Builds from before put them one folder down, in `dist/`; `moveUp` moves
/// such an install over without a rebuild, and `InstalledExtension.entry(for:)` finds a command in either place.
public enum ExtensionLayout {
    /// The folder builds from before SPEC-123 put the commands in.
    public static let oldFolder = "dist"

    /// The compiled command's file name. CommonJS, whatever the extension's `package.json` says about modules.
    public static func file(for command: String) -> String { "\(command).cjs" }

    /// Why an install with a `dist/` was left as it is, on `entry(for:)`'s fallback.
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        /// `dist/` holds something that isn't a regular `<command>.cjs` file its manifest names.
        case unknownItem
        /// A command's file is both in `dist/` and at the root, so moving it would replace one.
        case inBothPlaces
        /// `dist/` isn't a folder (a file, or a link).
        case notAFolder
        /// `dist/` couldn't be listed.
        case unreadable
        /// A rename or the removal of `dist/` failed with this `errno`.
        case failed(Int32)

        public var description: String {
            switch self {
            case .unknownItem: "dist/ holds something its manifest doesn't name"
            case .inBothPlaces: "a command is both in dist/ and beside package.json"
            case .notAFolder: "dist isn't a folder"
            case .unreadable: "dist/ couldn't be listed"
            case .failed(let code): "moving failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every command that was in `dist/` is beside `package.json` now, and `dist/` is gone.
        case moved
        /// Left as it is, on the fallback.
        case leftAlone(Refusal)
    }

    /// Moves each install in `extensionsDirectory` that still has a `dist/` to the new layout (`moveUp(_:)`), and says
    /// what happened to each, by folder name. Installs with nothing to move aren't listed.
    public static func moveUp(in extensionsDirectory: URL) -> [String: Outcome] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: extensionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var outcomes: [String: Outcome] = [:]
        for folder in folders {
            if let outcome = moveUp(folder) { outcomes[folder.lastPathComponent] = outcome }
        }
        return outcomes
    }

    /// Moves one install from before to the new layout: each `dist/<command>.cjs` up to `<command>.cjs`, by rename, then
    /// the empty `dist/` away. Nil when there's nothing to move: no `dist/`, or a folder that isn't a Fudge build
    /// (`ExtensionBuilder.holdsOnlyABuild`), which is never touched.
    ///
    /// It's safe to stop at any point. Each file is renamed, never copied, so a command is in one place or the other,
    /// whole, and `entry(for:)` finds it in either; the next load finishes the move. When `dist/` holds anything else,
    /// nothing is moved at all.
    public static func moveUp(_ directory: URL) -> Outcome? {
        let dist = directory.appendingPathComponent(oldFolder)
        var status = stat()
        guard lstat(dist.path, &status) == 0 else { return nil }
        guard let manifest = try? ExtensionManifest.load(from: directory.appendingPathComponent("package.json")),
            ExtensionBuilder.holdsOnlyABuild(directory, manifest: manifest)
        else { return nil }
        guard status.st_mode & S_IFMT == S_IFDIR else { return .leftAlone(.notAFolder) }

        let commands = Set(manifest.commands.map { file(for: $0.name) })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dist.path) else {
            return .leftAlone(.unreadable)
        }
        let known = names.allSatisfy { name in
            var item = stat()
            return commands.contains(name) && lstat(dist.appendingPathComponent(name).path, &item) == 0
                && item.st_mode & S_IFMT == S_IFREG
        }
        guard known else { return .leftAlone(.unknownItem) }

        for name in names.sorted() {
            let from = dist.appendingPathComponent(name).path
            let to = directory.appendingPathComponent(name).path
            // RENAME_EXCL: a file already at the root is never replaced.
            if renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 {
                switch errno {
                case ENOENT: continue  // Moved meanwhile, by another load.
                case EEXIST: return .leftAlone(.inBothPlaces)
                case let code: return .leftAlone(.failed(code))
                }
            }
        }
        // rmdir removes only an empty folder, so a file that came into dist/ meanwhile keeps it.
        if rmdir(dist.path) != 0, errno != ENOENT { return .leftAlone(.failed(errno)) }
        return .moved
    }
}
