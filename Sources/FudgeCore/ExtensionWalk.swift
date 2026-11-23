import Foundation

/// The extensions folder's layout as Fudge reads it (FUD-183): Raycast's installs in `raycast/extensions/<name>`, the
/// development builds in `fudgeapp/development/<name>`, a GitHub repository's in `<owner>/<repository>/<name>`, and a
/// repository's on another server in `<host>/<path…>/<name>`. An install still at the top level is one the move
/// (`ExtensionLayout.moveIntoRepositories`) hasn't filed with Raycast's yet.
///
/// The walk only looks: it lists folders and checks for `package.json`, and reads no manifest. At every level, entries
/// starting with `.` and links are skipped, and nothing is followed (`lstat`).
public struct ExtensionWalk: Equatable, Sendable {
    /// A folder holding `package.json`, where an install can be.
    public struct Found: Equatable, Sendable {
        /// Its path relative to the extensions folder.
        public let path: String
        /// The repository folder it's in, or nil for one at the top level, which hasn't been moved yet.
        public let repositoryFolder: String?
    }

    /// The folders holding `package.json`, in the order found: by folder, then by name.
    public private(set) var found: [Found] = []
    /// Every folder the walk listed, relative to the extensions folder (`""` is the folder itself): the top, each
    /// owner's and repository's folder, and each host's folders down to the installs. These are the folders an install
    /// can land in.
    public private(set) var folders: [String] = []
    /// Links at the top level, which are neither moved nor loaded.
    public private(set) var links: [String] = []
    /// What the walk passed over that looks like an install in the wrong place, one line each, for `Fudge.log`.
    public private(set) var skipped: [String] = []

    /// How far below a host's folder an install can be: six path segments (`ExtensionRepositoryFolder`), then the
    /// extension's own folder.
    static let hostDepth = 7

    /// Walks `extensionsDirectory`. A folder that can't be listed counts as empty.
    public init(_ extensionsDirectory: URL) {
        let root = extensionsDirectory.standardizedFileURL
        folders.append("")
        for (name, kind) in Self.entries(of: root) {
            switch kind {
            case .link: links.append(name)
            case .folder:
                if Self.holdsManifest(root.appendingPathComponent(name)) {
                    found.append(Found(path: name, repositoryFolder: nil))
                } else if name.contains(".") {
                    walkHost(name, depth: 0, in: root)
                } else {
                    walkOwner(name, in: root)
                }
            case .other: continue
            }
        }
    }

    /// A GitHub owner's folder (`raycast` and `fudgeapp` included): each folder in it is a repository's.
    private mutating func walkOwner(_ owner: String, in root: URL) {
        folders.append(owner)
        for (name, kind) in Self.entries(of: root.appendingPathComponent(owner)) where kind == .folder {
            let repository = "\(owner)/\(name)"
            if Self.holdsManifest(root.appendingPathComponent(repository)) {
                skipped.append("skipped \(repository): an extension there isn't in a repository's folder")
                continue
            }
            folders.append(repository)
            for (install, kind) in Self.entries(of: root.appendingPathComponent(repository)) where kind == .folder {
                let path = "\(repository)/\(install)"
                if Self.holdsManifest(root.appendingPathComponent(path)) {
                    found.append(Found(path: path, repositoryFolder: repository))
                }
            }
        }
    }

    /// A folder `depth` folders below a host's (the host's own is 0): the first folder holding `package.json` on each
    /// path is an install, at most `hostDepth` below the host's folder.
    private mutating func walkHost(_ path: String, depth: Int, in root: URL) {
        folders.append(path)
        for (name, kind) in Self.entries(of: root.appendingPathComponent(path)) where kind == .folder {
            let child = "\(path)/\(name)"
            if Self.holdsManifest(root.appendingPathComponent(child)) {
                found.append(Found(path: child, repositoryFolder: path))
            } else if depth + 1 < Self.hostDepth {
                walkHost(child, depth: depth + 1, in: root)
            }
        }
    }

    enum Kind { case folder, link, other }

    /// The entries of `folder` that don't start with `.`, sorted by name, each as `lstat` sees it.
    static func entries(of folder: URL) -> [(name: String, kind: Kind)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { return (name, .other) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return (name, .folder)
            case S_IFLNK: return (name, .link)
            default: return (name, .other)
            }
        }
    }

    /// Whether `folder` holds a `package.json` itself, whatever it is.
    static func holdsManifest(_ folder: URL) -> Bool {
        var info = stat()
        return lstat(folder.appendingPathComponent("package.json").path, &info) == 0
    }
}

/// What loading the extensions folder found (`InstalledExtension.load(walking:)`).
public struct ExtensionsFolderLoad: Sendable {
    /// The installs, sorted by title.
    public var installed: [InstalledExtension]
    /// One line for `Fudge.log` per folder that wasn't loaded, and per link at the top level, each naming the folder
    /// relative to the extensions folder.
    public var skipped: [String]
}

extension InstalledExtension {
    /// Every install the walk (`ExtensionWalk`) finds, each under its id, and a line for each folder skipped.
    ///
    /// An install in a repository's folder loads only when its folder's name is its manifest's name and, outside
    /// Raycast's, its repository folder passes `ExtensionRepositoryFolder.isValid` (`fudgeapp/development` does), so
    /// each id is well defined and found once. An install at the top level, one the move hasn't filed yet, loads as
    /// Raycast's with its name as its id, unless Raycast's folder has one of that id, which wins.
    public static func load(walking extensionsDirectory: URL) -> ExtensionsFolderLoad {
        let walk = ExtensionWalk(extensionsDirectory)
        var skipped = walk.skipped + walk.links.map { "skipped \($0): it's a link, so it's neither moved nor loaded" }
        var installed: [InstalledExtension] = []
        var ids: Set<ExtensionID> = []
        func add(_ install: InstalledExtension) {
            ids.insert(install.id)
            installed.append(install)
        }

        for found in walk.found {
            guard let folder = found.repositoryFolder else { continue }
            let directory = extensionsDirectory.appendingPathComponent(found.path, isDirectory: true)
            guard folder == ExtensionRepositoryFolder.raycast || ExtensionRepositoryFolder.isValid(folder),
                let repository = Repository(folder: folder)
            else {
                skipped.append("skipped \(found.path): \(folder) isn't a repository's folder")
                continue
            }
            guard let manifest = try? ExtensionManifest.load(from: directory.appendingPathComponent("package.json"))
            else {
                skipped.append("skipped \(found.path): its package.json can't be read")
                continue
            }
            guard manifest.name == directory.lastPathComponent else {
                skipped.append("skipped \(found.path): its folder isn't named after its extension, \(manifest.name)")
                continue
            }
            guard let id = ExtensionID(name: manifest.name, repositoryFolder: folder) else {
                skipped.append("skipped \(found.path): its name can't be an extension's id")
                continue
            }
            guard !ids.contains(id) else {
                skipped.append("skipped \(found.path): another install has its id, \(id.key)")
                continue
            }
            add(
                InstalledExtension(
                    manifest: manifest, directory: directory, id: id, repository: repository,
                    compatibility: CommandCompatibility.load(from: directory)))
        }

        for found in walk.found where found.repositoryFolder == nil {
            let directory = extensionsDirectory.appendingPathComponent(found.path, isDirectory: true)
            guard let install = try? loadUnmoved(from: directory) else {
                skipped.append("skipped \(found.path): its package.json can't be read, or its name isn't valid")
                continue
            }
            guard !ids.contains(install.id) else {
                skipped.append(
                    "skipped \(found.path): \(ExtensionRepositoryFolder.raycast)/\(install.manifest.name) is installed too, and that one loads"
                )
                continue
            }
            add(install)
        }

        return ExtensionsFolderLoad(
            installed: installed.sorted {
                $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending
            },
            skipped: skipped)
    }
}

/// Writes lines about the extensions folder to `Fudge.log`, each once per run, so a reload doesn't repeat them.
public final class ExtensionsFolderLog: @unchecked Sendable {
    /// The app's: every load of the extensions folder reports here.
    public static let shared = ExtensionsFolderLog { FudgeLog.warning($0) }

    private let lock = NSLock()
    private var said = OncePerRun()
    private let write: @Sendable (String) -> Void

    init(write: @escaping @Sendable (String) -> Void) { self.write = write }

    /// Writes each of `lines` not written before in this run.
    public func report(_ lines: [String]) {
        for line in lines where lock.withLock({ said.first(line) }) { write(line) }
    }
}
