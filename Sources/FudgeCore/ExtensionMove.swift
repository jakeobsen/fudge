import Foundation

/// The move into the layout (FUD-183): every install from before, at the extensions folder's top level, is filed in
/// Raycast's folder, `raycast/extensions/<manifest name>`, whether or not the Extension Store installed it, so it keeps
/// its name as its id, and with it its settings, data and sign-ins. Nothing outside the extensions folder moves.
extension ExtensionLayout {
    /// The move's lock file, at the extensions folder's top: the app at launch and `fudge build` never move at once.
    public static let moveLockName = ".move.lock"
    /// Where a legacy install named `raycast` waits while `raycast/extensions/` is made, since it would otherwise land
    /// inside itself. Every move finishes one it finds first, so a stop between the two renames loses nothing.
    static let waitingRaycastName = ".move-raycast"
    /// How long the app waits at launch for another Fudge's move before loading the extensions as they are: launch runs
    /// on the main thread, so the wait is bounded.
    public static let launchMoveWait: Duration = .seconds(5)
    /// How long `fudge build` waits for another Fudge's move before it stops.
    public static let buildMoveWait: Duration = .seconds(60)
    /// How often a wait tries the lock again.
    public static let moveLockInterval: Duration = .milliseconds(100)

    /// What a move did.
    public struct MoveReport: Equatable, Sendable {
        /// The top-level folders it moved, by name.
        public var moved: [String] = []
        /// One line for `Fudge.log` per folder it left where it is, naming it.
        public var left: [String] = []

        public init(moved: [String] = [], left: [String] = []) {
            self.moved = moved
            self.left = left
        }
    }

    /// Why a move didn't run.
    public enum MoveLockFailure: Error, Equatable, Sendable {
        /// Another move held `.move.lock` for the whole wait.
        case timedOut(path: String)
        /// `.move.lock` couldn't be opened or locked, for a reason other than another move holding it.
        case cantLock(path: String, reason: String)
    }

    /// Takes `.move.lock`, trying every 100 ms for at most `bound`, moves every install at the top level into Raycast's
    /// folder, then gives the lock back. A missing extensions folder has nothing to move.
    public static func moveIntoRepositories(
        extensions: URL, waitingAtMost bound: Duration, every interval: Duration = moveLockInterval
    ) throws(MoveLockFailure) -> MoveReport {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: extensions.path, isDirectory: &isFolder), isFolder.boolValue else {
            return MoveReport()
        }
        return try moveLocked(extensions: extensions, waitingAtMost: bound, every: interval)
    }

    /// The move with the lock taken and given back around it; `rename` is the move's (`moveIntoRepositories`).
    static func moveLocked(
        extensions: URL, waitingAtMost bound: Duration, every interval: Duration = moveLockInterval,
        rename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    ) throws(MoveLockFailure) -> MoveReport {
        let lock = try lockMove(in: extensions, waitingAtMost: bound, every: interval)
        defer { unlockMove(lock) }
        return moveIntoRepositories(extensions: extensions, rename: rename)
    }

    /// The app's move at launch, before the extensions first load and before the watcher starts: what was left where
    /// it is goes to `Fudge.log`, one line each. When another Fudge holds the lock past `bound`, or the lock can't be
    /// taken, nothing moves, one line says so, and the extensions load as they are; nil then.
    @discardableResult
    public static func moveAtLaunch(
        extensions: URL, waitingAtMost bound: Duration = launchMoveWait,
        log: (LogLevel, String) -> Void = { FudgeLog.write($0, $1) }
    ) -> MoveReport? {
        do throws(MoveLockFailure) {
            let report = try moveIntoRepositories(extensions: extensions, waitingAtMost: bound)
            if !report.moved.isEmpty {
                let count = report.moved.count
                log(
                    .info,
                    "moved \(count) installed extension\(count == 1 ? "" : "s") into \(ExtensionRepositoryFolder.raycast)"
                )
            }
            for line in report.left { log(.warning, line) }
            return report
        } catch {
            switch error {
            case .timedOut:
                log(
                    .warning,
                    "didn't move the installed extensions into their repositories' folders: another Fudge was still moving them, so they load as they are"
                )
            case .cantLock(let path, let reason):
                log(
                    .warning,
                    "didn't move the installed extensions into their repositories' folders: couldn't lock \(path): \(reason)"
                )
            }
        }
        return nil
    }

    /// The move itself, with the lock held. `rename` is `renamex_np` with `RENAME_EXCL` (0, or -1 with `errno` set); a
    /// test passes one that fails on purpose.
    ///
    /// Each top-level folder, not hidden and not a link, that holds `package.json` itself goes to
    /// `raycast/extensions/<manifest name>` by one rename, so it's whole in one place or the other and keeps its inode
    /// and creation time. A folder whose manifest can't be read, or whose name isn't valid, stays; so does one whose
    /// target is there already, which is never replaced. No store record is read.
    static func moveIntoRepositories(
        extensions: URL, rename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    ) -> MoveReport {
        var report = MoveReport()
        var raycastFolder: Result<URL, MoveFolderProblem>?
        /// `raycast/extensions/`, made once, when the first install needs it.
        func folder() -> Result<URL, MoveFolderProblem> {
            if let raycastFolder { return raycastFolder }
            let made = makeRaycastFolder(in: extensions)
            raycastFolder = made
            return made
        }
        /// Files `from` (named `shown` in the report, and `where` in a line about leaving it) as
        /// `raycast/extensions/<name>`.
        func file(_ from: URL, shown: String, as name: String, where place: String = "where it is") {
            switch folder() {
            case .failure(let problem):
                report.left.append("left \(shown) \(place): \(problem.description)")
            case .success(let raycast):
                if rename(from.path, raycast.appendingPathComponent(name).path) == 0 {
                    report.moved.append(shown)
                    return
                }
                switch errno {
                case ENOENT: return  // Moved meanwhile.
                case EEXIST, ENOTEMPTY:
                    report.left.append(
                        "left \(shown) \(place): \(ExtensionRepositoryFolder.raycast)/\(name) is there already")
                case let code:
                    report.left.append(
                        "left \(shown) \(place): moving it into \(ExtensionRepositoryFolder.raycast) failed: \(String(cString: strerror(code)))"
                    )
                }
            }
        }
        /// The manifest name of the install at the top level named `name`, or nil with a line saying why it stays.
        func manifestName(of name: String) -> String? {
            let from = extensions.appendingPathComponent(name, isDirectory: true)
            guard let manifest = try? ExtensionManifest.load(from: from.appendingPathComponent("package.json")) else {
                report.left.append("left \(name) where it is: its package.json can't be read")
                return nil
            }
            guard ExtensionManifest.isValidName(manifest.name) else {
                report.left.append("left \(name) where it is: its extension's name isn't valid")
                return nil
            }
            return manifest.name
        }

        // First, a legacy install named `raycast` that a stop left under its hidden name.
        let waiting = extensions.appendingPathComponent(waitingRaycastName, isDirectory: true)
        var info = stat()
        if lstat(waiting.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            let name = (try? ExtensionManifest.load(from: waiting.appendingPathComponent("package.json")))
                .map(\.name).flatMap { ExtensionManifest.isValidName($0) ? $0 : nil }
            file(waiting, shown: waitingRaycastName, as: name ?? "raycast")
        }

        let installs = ExtensionWalk.entries(of: extensions).filter {
            $0.kind == .folder && ExtensionWalk.holdsManifest(extensions.appendingPathComponent($0.name))
        }.map(\.name)
        // Then a legacy install named `raycast` (in any letter case, since the Mac's disk usually ignores case), before
        // any other install makes `raycast/extensions/`, which would be inside it: it's renamed out of the way to
        // `.move-raycast`, and filed from there.
        let isRaycast = { (name: String) in ExtensionRepositoryFolder.lowercased(name) == "raycast" }
        for name in installs where isRaycast(name) {
            guard let manifestName = manifestName(of: name) else { continue }
            guard rename(extensions.appendingPathComponent(name, isDirectory: true).path, waiting.path) == 0 else {
                let code = errno
                report.left.append(
                    code == EEXIST || code == ENOTEMPTY
                        ? "left \(name) where it is: \(waitingRaycastName) is there already"
                        : "left \(name) where it is: renaming it failed: \(String(cString: strerror(code)))")
                continue
            }
            file(waiting, shown: name, as: manifestName, where: "as \(waitingRaycastName)")
        }

        // Then every other install.
        for name in installs where !isRaycast(name) {
            guard let manifestName = manifestName(of: name) else { continue }
            file(extensions.appendingPathComponent(name, isDirectory: true), shown: name, as: manifestName)
        }
        return report
    }

    /// Why `raycast/extensions/` can't take the moved installs.
    enum MoveFolderProblem: Error, Equatable, CustomStringConvertible {
        /// It, or `raycast/`, couldn't be made, with this `errno`.
        case cantMake(String, Int32)
        /// It, or `raycast/`, is a link or a file, or holds `package.json`: an install's folder, not Raycast's.
        case notAFolder(String)

        var description: String {
            switch self {
            case .cantMake(let path, let code): "\(path) can't be made: \(String(cString: strerror(code)))"
            case .notAFolder(let path): "\(path) isn't a folder Fudge can move installs into"
            }
        }
    }

    /// Makes `raycast/` and `raycast/extensions/` (0755) when they're missing, and checks that each is a folder, not a
    /// link, holding no `package.json`.
    static func makeRaycastFolder(in extensions: URL) -> Result<URL, MoveFolderProblem> {
        var folder = extensions
        var shown: [String] = []
        for part in ExtensionRepositoryFolder.raycast.split(separator: "/").map(String.init) {
            folder = folder.appendingPathComponent(part, isDirectory: true)
            shown.append(part)
            if mkdir(folder.path, 0o755) != 0, errno != EEXIST {
                return .failure(.cantMake(shown.joined(separator: "/"), errno))
            }
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                !ExtensionWalk.holdsManifest(folder)
            else { return .failure(.notAFolder(shown.joined(separator: "/"))) }
        }
        return .success(folder)
    }

    /// Takes the move's lock (`flock`, `LOCK_EX | LOCK_NB`), trying every `interval` for at most `bound`, and returns its
    /// descriptor, which `unlockMove` gives back. A wait never blocks in `flock`, so the app's launch, on the main
    /// thread, waits at most `bound`.
    static func lockMove(
        in extensions: URL, waitingAtMost bound: Duration, every interval: Duration
    ) throws(MoveLockFailure) -> Int32 {
        let file = extensions.appendingPathComponent(moveLockName).path
        let descriptor = open(file, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw .cantLock(path: file, reason: String(cString: strerror(errno))) }
        let clock = ContinuousClock()
        let deadline = clock.now + bound
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                close(descriptor)
                throw .cantLock(path: file, reason: String(cString: strerror(error)))
            }
            let left = deadline - clock.now
            guard left > .zero else {
                close(descriptor)
                throw .timedOut(path: file)
            }
            Thread.sleep(forTimeInterval: seconds(min(interval, left)))
        }
        return descriptor
    }

    /// Gives back the lock `lockMove` took, with `LOCK_UN` and then `close`, as `ExtensionBuilder.unlockBuild` does,
    /// so a program another thread is starting can't keep it.
    static func unlockMove(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
