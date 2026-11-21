import CoreGraphics
import Foundation

/// The frames windows had before Fudge's window commands last moved them, for Restore: by window number (the window
/// list's id, which a window keeps while it's open), in memory, for this run. Windows that are gone are dropped.
public struct WindowFrames: Sendable, Equatable {
    private var frames: [Int: CGRect] = [:]

    public init() {}

    public func frame(of window: Int) -> CGRect? { frames[window] }

    mutating func remember(_ frame: CGRect, of window: Int) { frames[window] = frame }

    mutating func forget(_ window: Int) { frames[window] = nil }

    /// Keeps only the windows still listed.
    mutating func keep(only windows: Set<Int>) { frames = frames.filter { windows.contains($0.key) } }
}

/// What a window command did: its work, or a message for the HUD.
public enum WindowCommandResult: Equatable, Sendable {
    case done
    case message(String)

    public static let noWindow = WindowCommandResult.message("There's no window to move.")
    public static let fullScreen = WindowCommandResult.message("Exit full screen first.")
    public static let cantMove = WindowCommandResult.message("This window can't be moved.")
    public static let cantFullScreen = WindowCommandResult.message("This window can't go full screen.")
    public static let oneDisplay = WindowCommandResult.message("There's only one display.")
}

extension WindowManager {
    /// Runs one of Fudge's window commands (SPEC-066) on the frontmost app's focused window, found as
    /// `getActiveWindow` finds it. The window's screen is the one holding most of it, and frames come from
    /// `WindowLayout` in that screen's visible frame.
    ///
    /// A full-screen window takes only Toggle Full Screen. One that can't be resized moves to the target's top-left
    /// corner, kept inside the visible frame; one that can't be moved either is left as it is. A frame is set as
    /// position, then size, then position again (`WindowSystem.apply` sets the size around the move, and a second
    /// move follows), so a window crossing a screen edge lands where it should; an app that refuses part of it keeps
    /// what it accepted. Every move but Restore remembers the frame before it, and Restore forgets it.
    public func run(_ command: WindowCommand, frames: inout WindowFrames) -> WindowCommandResult {
        let reading = Reading(self)
        frames.keep(only: Set(reading.windows.map(\.number)))
        guard let listed = reading.activeWindow(), let ax = reading.ax(for: listed),
            let screen = reading.screen(of: listed)
        else { return .noWindow }
        let current = ax.frame ?? listed.bounds

        if command == .toggleFullScreen {
            guard ax.fullScreenSettable else { return .cantFullScreen }
            return apply(ax.fullScreen ? .exitFullScreen : .fullScreen, to: ax.handle)
        }
        guard !ax.fullScreen else { return .fullScreen }

        var visible = screen.visibleBounds
        let target: CGRect
        switch command {
        case .restore:
            guard let saved = frames.frame(of: listed.number) else { return .done }
            target = saved
        case .nextDisplay, .previousDisplay:
            let ordered = WindowLayout.displayOrder(reading.screens) { $0.visibleBounds }
            guard ordered.count > 1, let index = ordered.firstIndex(of: screen) else { return .oneDisplay }
            let next = ordered[
                WindowLayout.neighbour(of: index, among: ordered.count, forward: command == .nextDisplay)]
            target = WindowLayout.moved(current, from: visible, to: next.visibleBounds)
            visible = next.visibleBounds
        default:
            guard let frame = WindowLayout.frame(for: command, in: visible, current: current) else { return .done }
            target = frame
        }

        let result: WindowCommandResult
        switch (ax.positionSettable, ax.sizeSettable) {
        case (true, true):
            result = setFrame(target, of: ax.handle)
        case (true, false):
            let moved = WindowLayout.movedOnly(size: current.size, to: target, in: visible)
            result = apply(.frame(position: moved.origin, size: nil), to: ax.handle)
        case (false, true):
            result = apply(.frame(position: nil, size: target.size), to: ax.handle)
        case (false, false):
            return .cantMove
        }
        guard result == .done else { return result }
        if command == .restore {
            frames.forget(listed.number)
        } else {
            frames.remember(current, of: listed.number)
        }
        return .done
    }

    /// Position, size, then position again, through `apply`'s size, position, size.
    private func setFrame(_ frame: CGRect, of window: System.Handle) -> WindowCommandResult {
        let first = apply(.frame(position: frame.origin, size: frame.size), to: window)
        guard first == .done else { return first }
        return apply(.frame(position: frame.origin, size: nil), to: window)
    }

    private func apply(_ change: WindowChange, to window: System.Handle) -> WindowCommandResult {
        do {
            try system.apply(change, to: window)
            return .done
        } catch {
            return .message(String(describing: error))
        }
    }
}
