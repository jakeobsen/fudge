import Testing

@testable import FudgeCore

struct ActionMenuOwnerTests {
    /// A menu opened in command `s`, its first view, on item 5 (`id` prop "a").
    let owner = ActionMenuOwner(session: "s", depth: 1, item: 5, itemId: "a")

    @Test func aCommandsActionMenuStaysOnTheItemItOpenedOn() {
        #expect(owner.stays(with: owner))
        // A render that kept the selection.
        #expect(owner.stays(with: ActionMenuOwner(session: "s", depth: 1, item: 5, itemId: "a")))
    }

    @Test func itClosesWhenTheSelectionMovesToAnotherItem() {
        #expect(!owner.stays(with: ActionMenuOwner(session: "s", depth: 1, item: 7, itemId: "b")))
        // The same `id` on a new node: an item made again, with new action nodes.
        #expect(!owner.stays(with: ActionMenuOwner(session: "s", depth: 1, item: 7, itemId: "a")))
        // The same node for another item: index keys, a row inserted above.
        #expect(!owner.stays(with: ActionMenuOwner(session: "s", depth: 1, item: 5, itemId: "t")))
        // The items went, so the view's own actions show.
        #expect(!owner.stays(with: ActionMenuOwner(session: "s", depth: 1, item: nil)))
    }

    @Test func aMenuOnTheViewsOwnActionsClosesWhenItemsCome() {
        let ownActions = ActionMenuOwner(session: "s", depth: 1, item: nil)
        #expect(ownActions.stays(with: ActionMenuOwner(session: "s", depth: 1, item: nil)))
        #expect(!ownActions.stays(with: ActionMenuOwner(session: "s", depth: 1, item: 3, itemId: "a")))
    }

    @Test func itClosesWithAnotherViewOrCommandOrNone() {
        #expect(!owner.stays(with: ActionMenuOwner(session: "s", depth: 2, item: 5, itemId: "a")))
        #expect(!owner.stays(with: ActionMenuOwner(session: "t", depth: 1, item: 5, itemId: "a")))
        // Root search or a failure screen.
        #expect(!owner.stays(with: nil))
    }
}
