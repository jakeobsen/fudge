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
        run(.command(command), frames: &frames)
    }

    /// A custom position (SPEC-094 §1): `position` in the window's screen's visible frame, with every rule of the
    /// commands above, Restore and full screen included.
    public func run(position: WindowFractions, frames: inout WindowFrames) -> WindowCommandResult {
        run(.position(position), frames: &frames)
    }

    /// What a window command does: one of Fudge's commands, or a custom position.
    private enum Move {
        case command(WindowCommand)
        case position(WindowFractions)
    }

    private func run(_ move: Move, frames: inout WindowFrames) -> WindowCommandResult {
        var command: WindowCommand?
        if case .command(let named) = move { command = named }
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
        switch (move, command) {
        case (.position(let position), _):
            target = position.frame(in: visible)
        case (_, .restore):
            guard let saved = frames.frame(of: listed.number) else { return .done }
            target = saved
        case (_, .nextDisplay), (_, .previousDisplay):
            let ordered = WindowLayout.displayOrder(reading.screens) { $0.visibleBounds }
            guard ordered.count > 1, let index = ordered.firstIndex(of: screen) else { return .oneDisplay }
            let next = ordered[
                WindowLayout.neighbour(of: index, among: ordered.count, forward: command == .nextDisplay)]
            target = WindowLayout.moved(current, from: visible, to: next.visibleBounds)
            visible = next.visibleBounds
        case (.command(let command), _):
            guard let frame = WindowLayout.frame(for: command, in: visible, current: current) else { return .done }
            target = frame
        }

        let result = place(ax, at: target, current: current, in: visible)
        guard result == .done else { return result }
        if command == .restore {
            frames.forget(listed.number)
        } else {
            frames.remember(current, of: listed.number)
        }
        return .done
    }

    /// Puts the window at `target` in `visible`: the whole frame; its own size at the target's top-left corner, kept
    /// inside `visible`, when it can't be resized; only the size when it can't be moved; nothing when it can't be
    /// either (`cantMove`).
    func place(
        _ ax: AXWindow<System.Handle>, at target: CGRect, current: CGRect, in visible: CGRect
    ) -> WindowCommandResult {
        switch (ax.positionSettable, ax.sizeSettable) {
        case (true, true):
            return setFrame(target, of: ax.handle)
        case (true, false):
            let moved = WindowLayout.movedOnly(size: current.size, to: target, in: visible)
            return apply(.frame(position: moved.origin, size: nil), to: ax.handle)
        case (false, true):
            return apply(.frame(position: nil, size: target.size), to: ax.handle)
        case (false, false):
            return .cantMove
        }
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

extension BuiltInCommandGroup {
    /// Window Management: one command per `WindowCommand`, named by its raw value.
    public static let windowManagement = BuiltInCommandGroup(
        name: ":window-management", title: "Window Management",
        commands: WindowCommand.allCases.map { command in
            let (title, keywords, symbol) = command.presentation
            return BuiltInCommand(
                name: command.rawValue, title: title, keywords: keywords + ["window"], symbol: symbol)
        })
}

extension WindowCommand {
    /// The command's title, extra search words and SF Symbol.
    var presentation: (String, [String], String) {
        switch self {
        case .leftHalf: ("Left Half", ["half", "split"], "rectangle.lefthalf.inset.filled")
        case .rightHalf: ("Right Half", ["half", "split"], "rectangle.righthalf.inset.filled")
        case .topHalf: ("Top Half", ["half", "split"], "rectangle.tophalf.inset.filled")
        case .bottomHalf: ("Bottom Half", ["half", "split"], "rectangle.bottomhalf.inset.filled")
        case .topLeftQuarter: ("Top Left Quarter", ["quarter", "corner"], "rectangle.inset.topleft.filled")
        case .topRightQuarter: ("Top Right Quarter", ["quarter", "corner"], "rectangle.inset.topright.filled")
        case .bottomLeftQuarter: ("Bottom Left Quarter", ["quarter", "corner"], "rectangle.inset.bottomleft.filled")
        case .bottomRightQuarter:
            ("Bottom Right Quarter", ["quarter", "corner"], "rectangle.inset.bottomright.filled")
        case .firstThird: ("First Third", ["third", "left"], "rectangle.leadingthird.inset.filled")
        case .centerThird: ("Center Third", ["third", "middle"], "rectangle.center.inset.filled")
        case .lastThird: ("Last Third", ["third", "right"], "rectangle.trailingthird.inset.filled")
        case .firstTwoThirds: ("First Two Thirds", ["thirds", "left"], "rectangle.split.3x1")
        case .lastTwoThirds: ("Last Two Thirds", ["thirds", "right"], "rectangle.split.3x1")
        case .maximize: ("Maximize", ["fill", "zoom"], "rectangle.inset.filled")
        case .almostMaximize: ("Almost Maximize", ["fill", "zoom"], "inset.filled.center.rectangle")
        case .maximizeWidth: ("Maximize Width", ["wide", "stretch"], "arrow.left.and.right.square")
        case .maximizeHeight: ("Maximize Height", ["tall", "stretch"], "arrow.up.and.down.square")
        case .center: ("Center", ["middle"], "macwindow")
        case .reasonableSize: ("Reasonable Size", ["resize"], "rectangle.dashed")
        case .makeLarger: ("Make Larger", ["grow", "bigger", "resize"], "plus.rectangle")
        case .makeSmaller: ("Make Smaller", ["shrink", "smaller", "resize"], "minus.rectangle")
        case .restore: ("Restore", ["undo", "back"], "arrow.uturn.backward.square")
        case .nextDisplay: ("Next Display", ["screen", "monitor"], "arrow.right.square")
        case .previousDisplay: ("Previous Display", ["screen", "monitor"], "arrow.left.square")
        case .toggleFullScreen: ("Toggle Full Screen", ["fullscreen"], "arrow.up.left.and.arrow.down.right")
        }
    }
}
