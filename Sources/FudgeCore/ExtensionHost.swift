import Foundation

/// The running extension host: a Node process speaking the line protocol in HostProtocol.swift.
///
/// Send with `send(_:)`; everything the host says arrives on `messages`, except commands' log lines when `log` is
/// given: those go to it on the thread that reads the host, never through the main actor, so a command printing in a
/// loop can't hold the launcher up (SPEC-124).
/// The host's stderr (its own diagnostics) goes to ours, and to `Fudge.log` as errors.
public final class ExtensionHost: Sendable {
    /// Takes a command's log line: its session, level, message, and the names the host added.
    public typealias LogHandler =
        @Sendable (_ session: String, _ level: LogLevel, _ message: String, LogSource?) -> Void

    public let messages: AsyncStream<HostMessage>
    private let process: Process
    private let input: FileHandle
    private let writeLock = NSLock()

    /// `nodeArguments` go before the script, such as `--use-system-ca` (`NodeTrust`).
    public init(
        node: URL, script: URL, nodeArguments: [String] = [], environment: [String: String] = [:],
        log: LogHandler? = nil
    ) throws {
        let process = Process()
        process.executableURL = node
        process.arguments = nodeArguments + [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr

        let (messages, continuation) = AsyncStream.makeStream(of: HostMessage.self)
        let lines = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in lines.append(data) {
                guard let message = try? HostMessage(line: line) else { continue }
                if let log, case .log(let session, let level, let text, let source) = message {
                    log(session, LogLevel(rawValue: level) ?? .error, text, source)
                } else {
                    continuation.yield(message)
                }
            }
        }
        let errorLines = LineSplitter()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in errorLines.append(data) {
                FudgeLog.error("extension host: \(String(decoding: line, as: UTF8.self))")
            }
        }
        process.terminationHandler = { _ in continuation.finish() }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.messages = messages
    }

    public var isRunning: Bool { process.isRunning }

    public func send(_ message: AppMessage) throws {
        var line = try JSONEncoder().encode(message)
        line.append(0x0A)
        try writeLock.withLock { try input.write(contentsOf: line) }
    }

    /// Closes the host's stdin, which makes it stop every command and exit.
    public func stop() {
        writeLock.withLock { try? input.close() }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

/// Splits a byte stream into lines. Used from one readability handler at a time.
///
/// Each byte is searched once. A big list's render can be a line of several megabytes arriving in 64 KB chunks, and
/// searching the whole buffer again on every chunk made reading it quadratic: 18 s for 10 MB.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    /// How many bytes at the start of `buffer` are known to hold no newline.
    private var scanned = 0

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = 0
        buffer.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var from = scanned
            while from < bytes.count, let found = memchr(base + from, 0x0A, bytes.count - from) {
                let newline = UnsafeRawPointer(found) - base
                if newline > start { lines.append(Data(bytes[start..<newline])) }
                start = newline + 1
                from = start
            }
        }
        if start > 0 { buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + start) }
        scanned = buffer.count
        return lines
    }
}

/// Fudge's own Node.js (SPEC-115): the official build `make app` puts in the bundle, pinned and checked there.
/// It's the only Node.js Fudge runs, for the extension host, `fudge build` and `fudge scan`, so every extension runs
/// on the one Fudge was built and tested with.
public struct BundledNode: Sendable, Equatable {
    /// `Contents/Helpers/node`.
    public var node: URL
    /// npm, from Node.js's own distribution (`Contents/Resources/node/npm/bin/npm-cli.js`), which `node` runs.
    public var npm: URL

    public init(node: URL, npm: URL) {
        self.node = node
        self.npm = npm
    }

    /// The command that runs npm with `arguments`: `node npm-cli.js …`, with the helpers folder first on `PATH`, so a
    /// script npm starts gets this Node.js too, never one the user has installed.
    public func npm(_ arguments: [String], environment: [String: String])
        -> (executable: URL, arguments: [String], environment: [String: String])
    {
        var environment = environment
        let helpers = node.deletingLastPathComponent().path
        environment["PATH"] = [helpers, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        return (node, [npm.path] + arguments, environment)
    }
}

/// Finds the programs the app needs to run extensions.
public enum Runtime {
    /// The app's `Contents/Helpers`.
    public static var appHelpers: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// Fudge's own Node.js, beside `helpers`: the app's `Contents/Helpers`, or the folder the `fudge` tool really is
    /// in (its path with links resolved, so a link to it on `PATH` finds the bundle's). Nothing else is looked for,
    /// neither a variable, Homebrew nor `PATH`. Nil when it isn't there or can't run, as in a damaged app.
    public static func locateNode(helpers: URL? = appHelpers) -> BundledNode? {
        guard let helpers else { return nil }
        let node = helpers.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { return nil }
        let npm = helpers.deletingLastPathComponent().appendingPathComponent("Resources/node/npm/bin/npm-cli.js")
        return BundledNode(node: node, npm: npm)
    }

    /// What a missing or broken bundled Node.js says: it comes with Fudge, so only a damaged app is without it.
    public static let nodeMissing = "Fudge's own Node.js is missing or can't run. Reinstall Fudge."

    /// The host script: `$FUDGE_RUNTIME`, else `runtime/host.js` in the app's resources.
    public static func locateHostScript(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resources: URL? = Bundle.main.resourceURL
    ) -> URL? {
        if let override = environment["FUDGE_RUNTIME"], !override.isEmpty { return URL(fileURLWithPath: override) }
        guard let script = resources?.appendingPathComponent("runtime/host.js"),
            FileManager.default.fileExists(atPath: script.path)
        else { return nil }
        return script
    }
}
