import Foundation

/// The id the app gives each command it launches in the extension host: `s-` and 32 lowercase hex digits, 128 random
/// bits. That stops only blind guessing: extensions share the host process, so a running one can read the protocol
/// channel and learn the ids it carries (D-65).
public enum SessionID {
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    public static func make<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        "s-" + hex(generator.next()) + hex(generator.next())
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// The sessions a host message may name: those the app started in the running host and hasn't seen exit. A message
/// naming any other session, one that never ran, one that has exited, or an app-owned pseudo-session such as the
/// Create Quicklink form's (`QuicklinkForm.session`), which is never started, is dropped (SPEC-067).
public struct HostSessions: Sendable {
    /// The sessions running now.
    public private(set) var live: Set<String> = []
    /// The ids a dropped message has been logged for, so each is logged once.
    private var logged: Set<String> = []
    /// At most this many ids are logged; messages naming more are dropped without a line.
    static let loggedLimit = 100

    public init() {}

    public enum Verdict: Equatable, Sendable {
        case handle
        /// `log` is true the first time a message naming this id is dropped.
        case drop(log: Bool)
    }

    public mutating func started(_ session: String) {
        live.insert(session)
    }

    /// The session's launch failed, or it's over some other way than an `exit` message.
    public mutating func ended(_ session: String) {
        live.remove(session)
    }

    /// The host stopped, and every session with it.
    public mutating func endAll() {
        live.removeAll()
    }

    /// Whether `message` may go to the host: one for a session that isn't running (it has exited, or never ran in
    /// this host) is never sent, so a pick in a date picker or a ⌘K action left open can't reach a command that has
    /// ended (FUD-135 §2). A launch's session is started before its `launch` is sent.
    public func mayReceive(_ message: AppMessage) -> Bool {
        guard let session = message.session else { return true }
        return live.contains(session)
    }

    /// What to do with `message` from the host. A message naming no session (`pong`, a protocol error) is handled. A
    /// session's `exit` is handled and ends it, so a late `log` or `exit` after it is dropped.
    public mutating func admit(_ message: HostMessage) -> Verdict {
        guard let session = message.session else { return .handle }
        guard live.contains(session) else {
            return .drop(log: logged.count < Self.loggedLimit && logged.insert(session).inserted)
        }
        if case .exit = message { live.remove(session) }
        return .handle
    }
}

/// When the panels over a command (⌘K's action panel, a dropdown's panel, a form's calendar) close because the command
/// ended (SPEC-107 §4), so nothing in them can be picked for a command that's gone. `send` already holds back anything
/// for an ended session (`HostSessions.mayReceive`); this is what the user sees.
public enum EndedCommand {
    public enum Event: Sendable, Equatable {
        /// A session exited, for `reason` ("unloaded" when Fudge unloaded it on purpose, to show something else).
        case exited(session: String, reason: String)
        /// The extension host stopped, ending every session in it.
        case hostStopped
    }

    /// Whether the panels close: the command on screen (`screenSession`, nil for root search) exited, unless Fudge
    /// unloaded it, or the host stopped under a command of the host's. Fudge's own views (`isBuiltIn`) need no host.
    public static func closesPanels(screenSession: String?, isBuiltIn: Bool, event: Event) -> Bool {
        guard let screenSession, !isBuiltIn else { return false }
        switch event {
        case .exited(let session, let reason): return session == screenSession && reason != "unloaded"
        case .hostStopped: return true
        }
    }
}
