import Foundation

/// A finished child process.
public struct ShellResult: Sendable {
    public var status: Int32
    /// stdout and stderr, interleaved.
    public var output: String
}

public struct ShellError: Error, CustomStringConvertible {
    public var command: String
    public var status: Int32
    public var output: String

    public var description: String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (exit \(status))" + (trimmed.isEmpty ? "" : ":\n\(trimmed)")
    }
}

public enum Shell {
    /// Runs `executable` and waits. Throws `ShellError` when it exits non-zero.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Read before waiting: a full pipe would block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        guard result.status == 0 else {
            let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw ShellError(command: command, status: result.status, output: result.output)
        }
        return result
    }
}
