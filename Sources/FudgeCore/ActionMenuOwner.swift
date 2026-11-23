import Foundation

/// What a command's actions menu (⌘K) belongs to: the command (`session`), its view (`depth`) and the List or Grid
/// item whose actions it shows, or no item for the view's own actions (a Form's, a Detail's, an empty List's).
///
/// The menu closes, with any submenu, search or picker in it, once that changes: the selection moves to another item
/// (a render or a click), the selected item goes, the items go, or the first items come to a menu that showed the
/// view's own actions. A render that keeps the selection leaves it open. Raycast's docs don't say what an open Action
/// Panel does when the selection or the items change, so this is Fudge's choice: the one root search already makes
/// when its selection moves.
public struct ActionMenuOwner: Sendable, Equatable {
    public var session: String
    public var depth: Int
    /// The item whose actions the menu shows, by node id; nil for the view's own actions. A node, not only the item's
    /// `id` prop: an item made again under the same `id` has new action nodes, which the menu's highlight can't name.
    public var item: Int?
    /// The item's `id` prop, if it has one. With index keys a row inserted above reuses the selected node for another
    /// item, and only the `id` tells them apart.
    public var itemId: String?

    public init(session: String, depth: Int, item: Int?, itemId: String? = nil) {
        self.session = session
        self.depth = depth
        self.item = item
        self.itemId = itemId
    }

    /// Whether a menu that opened on `self` stays open with `now` on screen: only for the same command, view and
    /// item, by node and `id`. A `now` of nil (root search, a failure) closes it.
    public func stays(with now: ActionMenuOwner?) -> Bool {
        guard let now else { return false }
        return now.session == session && now.depth == depth && now.item == item && now.itemId == itemId
    }
}
