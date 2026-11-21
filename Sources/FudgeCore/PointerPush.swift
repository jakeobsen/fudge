import Foundation

/// The pointing hand a link shows while the pointer is over it, pushed onto AppKit's cursor stack and popped exactly
/// once: on the way out, or when it's released (a click that hides the panel, the panel hiding, the link going), since
/// a hidden window's pointer never leaves the link. A pop with nothing pushed would pop someone else's cursor, so a
/// way out after a release pops nothing.
public struct PointerPush: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case push, pop
    }

    /// Whether the hand is pushed now.
    public private(set) var isPushed = false

    public init() {}

    /// The pointer went into (`true`) or out of the link: what to do with the cursor stack, if anything.
    public mutating func hover(_ inside: Bool) -> Change? {
        guard inside != isPushed else { return nil }
        isPushed = inside
        return inside ? .push : .pop
    }

    /// The link stops showing the hand, wherever the pointer is: whether to pop it.
    public mutating func release() -> Bool {
        defer { isPushed = false }
        return isPushed
    }
}
