import Foundation

/// The running extension host: a Node process speaking the line protocol in HostProtocol.swift.
///
/// Send with `send(_:)`; everything the host says arrives on `messages`.
/// The host's stderr (its own diagnostics) is passed through to ours.
public final class ExtensionHost: Sendable {
    public let messages: AsyncStream<HostMessage>
    private let process: Process
    private let input: FileHandle
    private let writeLock = NSLock()

    /// `nodeArguments` go before the script, such as `--use-system-ca` (`NodeTrust`).
    public init(node: URL, script: URL, nodeArguments: [String] = [], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = node
        process.arguments = nodeArguments + [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError

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
                if let message = try? HostMessage(line: line) { continuation.yield(message) }
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

/// Finds the programs the app needs to run extensions.
public enum Runtime {
    /// Node: `$FUDGE_NODE`, then one next to the app's helpers, then the usual install locations, then `$PATH`.
    /// Apps opened from Finder don't get the shell's `PATH`, hence the fixed locations.
    public static func locateNode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        helpers: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    ) -> URL? {
        let files = FileManager.default
        if let override = environment["FUDGE_NODE"], !override.isEmpty { return URL(fileURLWithPath: override) }
        var candidates: [URL] = []
        if let helpers { candidates.append(helpers.appendingPathComponent("node")) }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map(URL.init(fileURLWithPath:))
        candidates += (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("node")
        }
        return candidates.first { files.isExecutableFile(atPath: $0.path) }
    }

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
