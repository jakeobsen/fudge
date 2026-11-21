import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// Reads one line from `descriptor`, without waiting for the end of the stream.
private func firstLine(of descriptor: Int32) -> String {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while read(descriptor, &byte, 1) == 1, byte != UInt8(ascii: "\n") { bytes.append(byte) }
    return String(decoding: bytes, as: UTF8.self)
}

private func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

/// A ceiling that only catches a hang. A CI runner can stall for seconds, so nothing here bounds real time tightly;
/// the behaviour is checked by what happened (the signal that ended a child), and by lower bounds a stall can't break.
private let noHang: Duration = .seconds(30)

/// Waits for a child on a thread of its own, started at once: `waitpid` blocks, and on a busy machine Swift's shared
/// pool of threads can take seconds to free one, which would make a timing check fail for nothing.
private final class Waiter: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var status: Int32 = 0

    init(_ children: ChildProcesses, _ pid: pid_t) {
        Thread { [self] in
            status = children.wait(pid)
            done.signal()
        }.start()
    }

    /// The child's status, once it has exited.
    var result: Int32 {
        done.wait()
        return status
    }
}

@Test func aChildsExitStatusComesBackAndASignalCountsAs128Plus() throws {
    let children = ChildProcesses()
    let sh = URL(fileURLWithPath: "/bin/sh")
    #expect(children.wait(try children.spawn(sh, ["-c", "exit 3"], environment: [:])) == 3)
    #expect(children.wait(try children.spawn(sh, ["-c", "kill -TERM $$"], environment: [:])) == 128 + SIGTERM)
}

@Test func aChildLeadsItsOwnProcessGroup() throws {
    let children = ChildProcesses()
    var pipe: [Int32] = [0, 0]
    #expect(Darwin.pipe(&pipe) == 0)
    defer { close(pipe[0]) }
    let pid = try children.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ $(ps -o pgid= -p $$)"], environment: [:], output: pipe[1])
    close(pipe[1])
    let words = firstLine(of: pipe[0]).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    #expect(children.wait(pid) == 0)
    #expect(words.count == 2 && words[0] == String(pid) && words[1] == String(pid), "its group is its own pid")
}

@Test func endingTheChildrenEndsTheirWholeProcessGroupWithinASecond() async throws {
    let children = ChildProcesses()
    var pipe: [Int32] = [0, 0]
    #expect(Darwin.pipe(&pipe) == 0)
    defer { close(pipe[0]) }
    // A child that never exits, with a grandchild of its own, as npm and node have.
    let pid = try children.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "/bin/sleep 600 & echo $!; wait"], environment: [:],
        output: pipe[1])
    close(pipe[1])
    let grandchild = try #require(pid_t(firstLine(of: pipe[0])))
    #expect(!isGone(grandchild))

    let started = ContinuousClock.now
    let waiter = Waiter(children, pid)
    children.endAll(grace: .seconds(1))
    #expect(waiter.result == 128 + SIGTERM, "SIGTERM was enough")
    #expect(ContinuousClock.now - started < noHang)
    let ending = ContinuousClock.now
    while !isGone(grandchild), ContinuousClock.now - ending < noHang {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(isGone(grandchild), "the grandchild went with its group")
    #expect(throws: ChildProcesses.SpawnError.self, "nothing starts once they're being ended") {
        try children.spawn(URL(fileURLWithPath: "/usr/bin/true"), [], environment: [:])
    }
}

@Test func aChildThatIgnoresSIGTERMIsKilledAfterTheGrace() async throws {
    let children = ChildProcesses()
    var pipe: [Int32] = [0, 0]
    #expect(Darwin.pipe(&pipe) == 0)
    defer { close(pipe[0]) }
    let pid = try children.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"],
        environment: [:], output: pipe[1])
    close(pipe[1])
    #expect(firstLine(of: pipe[0]) == "ready")
    let started = ContinuousClock.now
    let waiter = Waiter(children, pid)
    children.endAll(grace: .milliseconds(300))
    #expect(waiter.result == 128 + SIGKILL)
    let waited = ContinuousClock.now - started
    #expect(waited >= .milliseconds(300), "it was given the grace first")
    #expect(waited < noHang)
}

@Test func shellRunsInItsOwnGroupAndStillReturnsItsOutput() throws {
    let result = try Shell.run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2"], children: ChildProcesses())
    #expect(result.status == 0 && result.output == "out\nerr\n")
    #expect(throws: ShellError.self) {
        try Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 4"], children: ChildProcesses())
    }
}

@Test func aSignalDeletesWhatWasNamedAndNotTakenBack() throws {
    let children = ChildProcesses()
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let scratch = folder.appendingPathComponent("fudge-build-x")
    let staging = folder.appendingPathComponent(".staging-greeter-x")
    let moved = folder.appendingPathComponent(".staging-moved-x")
    for url in [scratch, staging, moved] {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("inside"), withIntermediateDirectories: true)
        children.deleteOnSignal(url)
    }
    children.forget(moved)
    children.deleteLeftovers()
    #expect(!FileManager.default.fileExists(atPath: scratch.path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(FileManager.default.fileExists(atPath: moved.path), "a folder taken back stays")
}
