import AppKit
import os

/// Diagnostics for the launcher's keyboard and hiding (SPEC-068 v2), in the unified log: subsystem
/// `io.github.jakeobsen.fudge`, category `launcher`. Read with
/// `/usr/bin/log show --last 2m --predicate 'subsystem == "io.github.jakeobsen.fudge"' --info` (in zsh, a bare `log` is a
/// builtin). Only public facts: window
/// classes and levels, bundle ids, decisions and reasons; never paths, titles or what was typed.
enum LauncherLog {
    private static let logger = Logger(subsystem: "io.github.jakeobsen.fudge", category: "launcher")
    /// Numbers the lines, so a run's sequence reads in order even when the log interleaves other lines.
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    static func note(_ message: String) {
        let number = counter.withLock { count in
            count += 1
            return count
        }
        logger.notice("#\(number, privacy: .public) \(message, privacy: .public)")
    }

    /// A window as the log names it: its class and level.
    @MainActor static func name(_ window: NSWindow?) -> String {
        window.map { "\(type(of: $0)) level \($0.level.rawValue)" } ?? "none"
    }

    /// The window with the keyboard, whether Fudge is active, and the frontmost app, as one line.
    @MainActor static var keyboard: String {
        let key = name(NSApp.keyWindow)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        return "keyWindow=\(key) fudgeActive=\(NSApp.isActive) frontmost=\(front)"
    }
}
