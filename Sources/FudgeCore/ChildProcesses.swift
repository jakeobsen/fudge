import Darwin
import Foundation

/// The programs the `fudge` tool runs (node, esbuild, npm), each in a process group of its own, so that ending the
/// tool ends them and everything they started. The Extension Store stops a `fudge scan` or `fudge build` that runs
/// too long with SIGTERM; without this, node or npm would go on running, holding the store's pipe open.
public final class ChildProcesses: @unchecked Sendable {
    /// The children of this process.
    public static let shared = ChildProcesses()

    public init() {}

    private let lock = NSLock()
    /// Each running child's process group, which the child leads, so its id is the child's.
    private var groups: Set<pid_t> = []
    /// Set once `endAll` has started: no new child may start after it.
    private var ending = false
    /// Set when a signal is ending this process (`endChildrenOnSignals`): the signal's handler exits, so `spawn` and
    /// `wait` never return, and a build that fails because its child was ended can't exit first with its own status.
    private var exiting = false

    /// What the signal's handler deletes before this process exits, since `defer` doesn't run then: `fudge build`'s
    /// scratch and staging folders, while they exist (`deleteOnSignal`, `forget`).
    private var leftovers: Set<URL> = []

    /// Blocks the calling thread for good, while the signal's handler ends the process.
    private func waitForExit() -> Never {
        while true { sleep(60) }
    }

    /// Has a signal that ends this process (`endChildrenOnSignals`) delete `url` first, until `forget(_:)`.
    public func deleteOnSignal(_ url: URL) {
        lock.withLock { _ = leftovers.insert(url) }
    }

    /// Takes `url` back from `deleteOnSignal`, before it's moved into place or once it's deleted. Once a signal is
    /// ending this process, it never returns, so nothing moves `url` while the signal's handler deletes it.
    public func forget(_ url: URL) {
        if lock.withLock({
            if !exiting { leftovers.remove(url) }
            return exiting
        }) {
            waitForExit()
        }
    }

    /// Deletes what `deleteOnSignal` named and `forget` didn't take back. The signal's handler calls it once every
    /// child has ended (`endAll`), so nothing is still writing there.
    func deleteLeftovers() {
        for url in lock.withLock({ leftovers }) { try? FileManager.default.removeItem(at: url) }
    }

    public struct SpawnError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Starts `executable` in a new process group, with `environment` as its whole environment and stdin from
    /// `/dev/null`. Its stdout and stderr go to `output`, a file descriptor, or are this process's own when it's nil;
    /// with `errors` too, stderr goes there instead.
    /// Signals are back to their defaults in the child, and no other descriptor is passed on.
    public func spawn(
        _ executable: URL, _ arguments: [String], environment: [String: String], in directory: URL? = nil,
        output: Int32? = nil, errors: Int32? = nil
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let output {
            posix_spawn_file_actions_adddup2(&actions, output, 1)
            posix_spawn_file_actions_adddup2(&actions, errors ?? output, 2)
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, 1)
            posix_spawn_file_actions_addinherit_np(&actions, 2)
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for string in argv + envp { free(string) }
        }

        // Under the lock, so `endAll` either sees this child or stops it from starting.
        lock.lock()
        defer { lock.unlock() }
        if exiting { waitForExit() }
        guard !ending else { throw SpawnError(description: "fudge is stopping") }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw SpawnError(description: "couldn't run \(executable.path): \(String(cString: strerror(status)))")
        }
        groups.insert(pid)
        return pid
    }

    /// Waits for the child `pid` to exit and returns its exit status, or 128 + the signal that ended it.
    public func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        if lock.withLock({
            groups.remove(pid)
            return exiting
        }) {
            waitForExit()
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Ends every child's process group: SIGTERM, then SIGKILL for whatever is still there after `grace`. Returns
    /// once every group is gone, or after `grace` and half a second more. No child starts after this. `exiting`
    /// says the caller exits next, so `spawn` and `wait` stop returning.
    public func endAll(grace: Duration = .seconds(1), exiting: Bool = false) {
        let running = lock.withLock {
            ending = true
            if exiting { self.exiting = true }
            return groups
        }
        func remaining() -> [pid_t] { running.filter { kill(-$0, 0) == 0 } }
        func waitUntilGone(_ limit: Duration) {
            let deadline = ContinuousClock.now + limit
            while !remaining().isEmpty, ContinuousClock.now < deadline { usleep(20_000) }
        }
        for group in running { kill(-group, SIGTERM) }
        waitUntilGone(grace)
        for group in remaining() { kill(-group, SIGKILL) }
        waitUntilGone(.milliseconds(500))
    }

    /// The signal sources `endChildrenOnSignals` installs, kept for the life of the process.
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// Makes SIGTERM, SIGINT and SIGHUP end the children first (`endAll`) and delete what `deleteOnSignal` named,
    /// then this process, with 128 + the signal as its status. For the tool's long-running commands, `scan` and
    /// `build`.
    public static func endChildrenOnSignals() {
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler {
                shared.endAll(exiting: true)
                shared.deleteLeftovers()
                exit(128 + signal)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
