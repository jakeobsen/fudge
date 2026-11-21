import Foundation
import Testing

@testable import FudgeCore

/// Hands out the values it's given, for a session id with known bits.
private struct FixedGenerator: RandomNumberGenerator {
    var values: [UInt64]
    mutating func next() -> UInt64 { values.removeFirst() }
}

@Test func aSessionIdIsSDashAnd32LowercaseHexDigits() throws {
    let pattern = try Regex("^s-[0-9a-f]{32}$")
    let ids = (0..<10_000).map { _ in SessionID.make() }
    #expect(ids.allSatisfy { $0.wholeMatch(of: pattern) != nil })
    #expect(Set(ids).count == ids.count, "10,000 ids are distinct")
    var generator = FixedGenerator(values: [1, 0xABC])
    #expect(SessionID.make(using: &generator) == "s-00000000000000010000000000000abc", "both halves keep 16 digits")
}

@Test func onlyARunningSessionsMessagesAreHandled() {
    var sessions = HostSessions()
    let running = SessionID.make()
    sessions.started(running)
    #expect(sessions.admit(.render(session: running, view: nil, depth: 1)) == .handle)
    #expect(sessions.admit(.rpc(session: running, id: 1, method: "toast.show", params: .null)) == .handle)

    let guessed = SessionID.make()
    #expect(sessions.admit(.rpc(session: guessed, id: 1, method: "clipboard.copy", params: .null)) == .drop(log: true))
    #expect(sessions.admit(.render(session: guessed, view: nil, depth: 1)) == .drop(log: false), "logged once per id")
    #expect(sessions.admit(.pong(id: 3)) == .handle, "a message naming no session")
    #expect(sessions.admit(.protocolError(message: "bad line")) == .handle)
}

@Test func theCreateQuicklinkFormsSessionNeverTakesHostMessages() {
    var sessions = HostSessions()
    sessions.started(SessionID.make())
    #expect(sessions.admit(.render(session: QuicklinkForm.session, view: nil, depth: 1)) == .drop(log: true))
    #expect(sessions.admit(.exit(session: QuicklinkForm.session, reason: "finished")) == .drop(log: false))
}

@Test func aSessionEndsAtItsExitAndWithTheHost() {
    var sessions = HostSessions()
    let first = SessionID.make()
    sessions.started(first)
    #expect(sessions.admit(.exit(session: first, reason: "finished")) == .handle, "the exit itself is handled")
    #expect(sessions.admit(.log(session: first, level: "info", message: "late")) == .drop(log: true))
    #expect(sessions.admit(.exit(session: first, reason: "finished")) == .drop(log: false), "quietly after that")

    let failed = SessionID.make()
    sessions.started(failed)
    sessions.ended(failed)
    #expect(sessions.admit(.log(session: failed, level: "info", message: "x")) == .drop(log: true))

    let a = SessionID.make()
    let b = SessionID.make()
    sessions.started(a)
    sessions.started(b)
    sessions.endAll()
    #expect(sessions.live.isEmpty)
    #expect(sessions.admit(.eventSettled(session: a)) == .drop(log: true))
}

@Test func droppedMessagesAreLoggedForAtMostAHundredIds() {
    var sessions = HostSessions()
    let logged = (0..<(HostSessions.loggedLimit + 20)).filter { _ in
        sessions.admit(.log(session: SessionID.make(), level: "info", message: "x")) == .drop(log: true)
    }
    #expect(logged.count == HostSessions.loggedLimit)
}
