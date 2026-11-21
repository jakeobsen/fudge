import CoreGraphics
import Foundation

/// Fudge's window management commands (SPEC-066 §2), by the name they have in settings (`:window-management/<name>`).
public enum WindowCommand: String, CaseIterable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds"
    case lastTwoThirds = "last-two-thirds"
    case maximize
    case almostMaximize = "almost-maximize"
    case maximizeWidth = "maximize-width"
    case maximizeHeight = "maximize-height"
    case center
    case reasonableSize = "reasonable-size"
    case makeLarger = "make-larger"
    case makeSmaller = "make-smaller"
    case restore
    case nextDisplay = "next-display"
    case previousDisplay = "previous-display"
    case toggleFullScreen = "toggle-full-screen"
}

/// Where a window management command puts a window: pure geometry on frames in the Accessibility API's coordinates
/// (top-left origin, y growing down, across every screen). Edges are rounded to whole points, so two halves or three
/// thirds meet without a gap.
public enum WindowLayout {
    /// The frame `command` gives a window at `current` on a screen whose visible frame is `visible`. Nil for the
    /// commands that aren't a frame on the window's own screen: Restore, Next and Previous Display, and Toggle Full
    /// Screen.
    public static func frame(for command: WindowCommand, in visible: CGRect, current: CGRect) -> CGRect? {
        let landscape = visible.width >= visible.height
        switch command {
        case .leftHalf: return part(visible, x: (0, 1 / 2), y: (0, 1))
        case .rightHalf: return part(visible, x: (1 / 2, 1), y: (0, 1))
        case .topHalf: return part(visible, x: (0, 1), y: (0, 1 / 2))
        case .bottomHalf: return part(visible, x: (0, 1), y: (1 / 2, 1))
        case .topLeftQuarter: return part(visible, x: (0, 1 / 2), y: (0, 1 / 2))
        case .topRightQuarter: return part(visible, x: (1 / 2, 1), y: (0, 1 / 2))
        case .bottomLeftQuarter: return part(visible, x: (0, 1 / 2), y: (1 / 2, 1))
        case .bottomRightQuarter: return part(visible, x: (1 / 2, 1), y: (1 / 2, 1))
        case .firstThird: return thirds(visible, landscape: landscape, from: 0, to: 1)
        case .centerThird: return thirds(visible, landscape: landscape, from: 1, to: 2)
        case .lastThird: return thirds(visible, landscape: landscape, from: 2, to: 3)
        case .firstTwoThirds: return thirds(visible, landscape: landscape, from: 0, to: 2)
        case .lastTwoThirds: return thirds(visible, landscape: landscape, from: 1, to: 3)
        case .maximize: return part(visible, x: (0, 1), y: (0, 1))
        case .almostMaximize: return centered(width: visible.width * 0.9, height: visible.height * 0.9, in: visible)
        case .reasonableSize: return centered(width: visible.width * 0.6, height: visible.height * 0.6, in: visible)
        case .center: return centered(width: current.width, height: current.height, in: visible)
        case .maximizeWidth:
            let height = min(current.height, visible.height)
            return rounded(
                CGRect(
                    x: visible.minX, y: clamp(current.minY, visible.minY, visible.maxY - height),
                    width: visible.width, height: height))
        case .maximizeHeight:
            let width = min(current.width, visible.width)
            return rounded(
                CGRect(
                    x: clamp(current.minX, visible.minX, visible.maxX - width), y: visible.minY, width: width,
                    height: visible.height))
        case .makeLarger, .makeSmaller:
            return resized(current, larger: command == .makeLarger, in: visible)
        case .restore, .nextDisplay, .previousDisplay, .toggleFullScreen:
            return nil
        }
    }

    /// `current` moved from the screen whose visible frame is `from` to the one whose visible frame is `to`: the same
    /// place and size relative to each, then kept inside `to`.
    public static func moved(_ current: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let scaleX = to.width / from.width
        let scaleY = to.height / from.height
        let width = min(current.width * scaleX, to.width)
        let height = min(current.height * scaleY, to.height)
        let x = to.minX + (current.minX - from.minX) * scaleX
        let y = to.minY + (current.minY - from.minY) * scaleY
        return rounded(
            CGRect(
                x: clamp(x, to.minX, to.maxX - width), y: clamp(y, to.minY, to.maxY - height), width: width,
                height: height))
    }

    /// Screens in the order Next and Previous Display go through: left to right, then top to bottom, by `frame`.
    public static func displayOrder<Screen>(_ screens: [Screen], by frame: (Screen) -> CGRect) -> [Screen] {
        screens.sorted { (frame($0).minX, frame($0).minY) < (frame($1).minX, frame($1).minY) }
    }

    /// The screen after (or, `forward` false, before) the one at `index` in `displayOrder`, wrapping around.
    public static func neighbour(of index: Int, among count: Int, forward: Bool) -> Int {
        (index + (forward ? 1 : count - 1)) % count
    }

    /// Where a window that can't be resized goes for `target`: its own size, at the target's top-left corner, kept
    /// inside the visible frame.
    public static func movedOnly(size: CGSize, to target: CGRect, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return rounded(
            CGRect(
                x: clamp(target.minX, visible.minX, visible.maxX - width),
                y: clamp(target.minY, visible.minY, visible.maxY - height), width: size.width, height: size.height))
    }

    // MARK: - Pieces

    /// The part of `visible` between the given fractions of its width and height.
    private static func part(_ visible: CGRect, x: (CGFloat, CGFloat), y: (CGFloat, CGFloat)) -> CGRect {
        edges(
            left: visible.minX + visible.width * x.0, right: visible.minX + visible.width * x.1,
            top: visible.minY + visible.height * y.0, bottom: visible.minY + visible.height * y.1)
    }

    /// Thirds across a landscape screen, or down a portrait one.
    private static func thirds(_ visible: CGRect, landscape: Bool, from: CGFloat, to: CGFloat) -> CGRect {
        landscape ? part(visible, x: (from / 3, to / 3), y: (0, 1)) : part(visible, x: (0, 1), y: (from / 3, to / 3))
    }

    private static func centered(width: CGFloat, height: CGFloat, in visible: CGRect) -> CGRect {
        let width = min(width, visible.width)
        let height = min(height, visible.height)
        return rounded(
            CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height))
    }

    /// Grown or shrunk by 5% of the screen's width and height on each side, about its center, inside `visible`, and
    /// never below 20% of either.
    private static func resized(_ current: CGRect, larger: Bool, in visible: CGRect) -> CGRect {
        let step = larger ? 1.0 : -1.0
        let width = clamp(current.width + step * 2 * visible.width * 0.05, visible.width * 0.2, visible.width)
        let height = clamp(current.height + step * 2 * visible.height * 0.05, visible.height * 0.2, visible.height)
        let x = clamp(current.midX - width / 2, visible.minX, visible.maxX - width)
        let y = clamp(current.midY - height / 2, visible.minY, visible.maxY - height)
        return rounded(CGRect(x: x, y: y, width: width, height: height))
    }

    /// A frame from its edges, each rounded to a whole point, so neighbouring parts share their edge.
    private static func edges(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) -> CGRect {
        let left = left.rounded()
        let top = top.rounded()
        return CGRect(x: left, y: top, width: right.rounded() - left, height: bottom.rounded() - top)
    }

    private static func rounded(_ frame: CGRect) -> CGRect {
        edges(left: frame.minX, right: frame.maxX, top: frame.minY, bottom: frame.maxY)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
