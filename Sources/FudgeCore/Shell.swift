import Darwin
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
    /// Runs `executable` and waits. Throws `ShellError` when it exits non-zero. It runs in a process group of its
    /// own (`ChildProcesses`), so a signal that ends this process ends it and what it started too.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        children: ChildProcesses = .shared
    ) throws -> ShellResult {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else {
            throw ChildProcesses.SpawnError(description: "couldn't make a pipe: \(String(cString: strerror(errno)))")
        }
        let reading = FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true)
        let pid: pid_t
        do {
            pid = try children.spawn(
                executable, arguments,
                environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new },
                in: directory, output: pipe[1])
        } catch {
            close(pipe[1])
            throw error
        }
        close(pipe[1])
        // Read before waiting: a full pipe would block the child forever.
        let data = reading.readDataToEndOfFile()
        let status = children.wait(pid)

        let result = ShellResult(status: status, output: String(decoding: data, as: UTF8.self))
        guard result.status == 0 else {
            let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw ShellError(command: command, status: result.status, output: result.output)
        }
        return result
    }
}
