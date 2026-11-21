import Foundation

/// Typing in a List or Grid that filters itself (`filtering={false}`, or an `onSearchTextChange`) selects the first
/// item of the results the extension sends for the new text, as in Raycast (FUD-107).
///
/// The app selects the first item it has as soon as the user types; this is about the renders that follow. Only a
/// render the extension sent after it was told the new text counts: a `throttle`d search tells it 250 ms later,
/// and a render that comes before that (the last text's results arriving late, a loading render) is left alone.
/// After the text went out, the first render whose items differ from those on screen then (other items, or the
/// same in another order) selects its first item, once. Renders with the same items (the extension marking itself
/// loading, an accessory updating) don't, and stay waiting for the results.
///
/// The user moving the selection or asking for the next page (`onLoadMore`) ends the wait, so a page appended
/// later never moves the selection. The extension's `selectedItemId` still wins (`ListContent.selection`).
public struct TypingSelection: Sendable, Equatable {
    private enum Phase: Sendable, Equatable {
        case idle
        /// The user typed; the extension hasn't been told yet.
        case waiting
        /// The extension was told, with these items (node ids, in order) on screen.
        case told(items: [Int])
    }

    private var phase = Phase.idle

    public init() {}

    /// The user typed. Typing again before the results come starts over.
    public mutating func typed() {
        phase = .waiting
    }

    /// The new text went to the extension, with `items` on screen.
    public mutating func told(items: [Int]) {
        guard phase != .idle else { return }
        phase = .told(items: items)
    }

    /// A render arrived with `items`: whether to select its first item.
    public mutating func rendered(items: [Int]) -> Bool {
        guard case .told(let before) = phase, items != before else { return false }
        phase = .idle
        return true
    }

    /// The user moved the selection or asked for the next page: what's selected stays.
    public mutating func cancel() {
        phase = .idle
    }

    /// Whether a render may still move the selection to the first item.
    public var isWaiting: Bool { phase != .idle }
}
