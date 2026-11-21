import Foundation

/// Which List or Grid items' held-back `actions` and `detail` (`ItemSlots`) the app asks the host for, and when.
///
/// The host sends a render with every item's slots only for the first item and the items of the app's last
/// request, and it keeps doing so in every render until the next request (`Deferral` in the runtime's
/// `serialize.ts`). So a request always names the whole window around the selected item, the selected item
/// included, even when those items came in full. A new one goes out when the selection comes near the edge of the
/// last one, or when an item near the selection is still held back with no answer on its way.
public struct SlotRequests: Sendable, Equatable {
    /// The window a request names: this many items before the selected one, and after it. A Grid row has at most 8
    /// cells, so ↑ and ↓ stay inside it.
    public static let before = 8
    public static let after = 10
    /// The part of the window around the selection that must be inside the last request. Past it, a new request
    /// goes out, so the items the selection moves to next are already on their way.
    public static let nearBefore = 3
    public static let nearAfter = 5

    /// The ids of the last request: every render since carries those items in full.
    public private(set) var wanted: Set<Int> = []
    /// Ids asked for whose answer hasn't come.
    public private(set) var pending: Set<Int> = []

    public init() {}

    /// The ids to ask for now, in list order, or nil when nothing needs asking. `answered` says whether the app holds
    /// the host's answer for an item since the last render.
    public mutating func request(
        items: [ListContent.Item], selected: Int?, answered: (Int) -> Bool
    ) -> [Int]? {
        guard !items.isEmpty else { return nil }
        let index = items.firstIndex { $0.id == selected } ?? 0
        let near = items[max(0, index - Self.nearBefore)...min(items.count - 1, index + Self.nearAfter)]
        let leftTheLast = near.contains { !wanted.contains($0.id) }
        let stillHeld = near.contains { !$0.deferred.isEmpty && !answered($0.id) && !pending.contains($0.id) }
        guard leftTheLast || stillHeld else { return nil }
        let ids = items[max(0, index - Self.before)...min(items.count - 1, index + Self.after)].map(\.id)
        wanted = Set(ids)
        pending.formUnion(ids)
        return ids
    }

    /// The host answered for `ids`.
    public mutating func answered(_ ids: some Sequence<Int>) {
        pending.subtract(ids)
    }
}
