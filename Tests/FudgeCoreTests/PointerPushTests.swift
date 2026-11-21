import Testing

@testable import FudgeCore

struct PointerPushTests {
    @Test func inAndOutPushAndPopOnce() {
        var pointer = PointerPush()
        #expect(pointer.hover(true) == .push)
        #expect(pointer.hover(true) == nil, "already pushed")
        #expect(pointer.isPushed)
        #expect(pointer.hover(false) == .pop)
        #expect(pointer.hover(false) == nil, "nothing left to pop")
        #expect(!pointer.isPushed)
    }

    /// SPEC-065 §5: the panel hides (Esc, the hotkey, a click elsewhere) with the pointer resting on the link.
    @Test func hidingThePanelPopsItOnceAndTheWayOutPopsNothing() {
        var pointer = PointerPush()
        #expect(pointer.hover(true) == .push)
        let poppedOnHide = pointer.release()
        #expect(poppedOnHide, "the hide pops it")
        #expect(!pointer.isPushed)
        let poppedAgain = pointer.release()
        #expect(!poppedAgain, "a second release pops nothing")
        // The pointer leaves later, or the link goes: still nothing more to pop.
        #expect(pointer.hover(false) == nil)
        let poppedLater = pointer.release()
        #expect(!poppedLater)
        // Back over the link once the panel shows again: pushed afresh.
        #expect(pointer.hover(true) == .push)
        #expect(pointer.hover(false) == .pop)
    }

    @Test func releasingWithNothingPushedPopsNothing() {
        var pointer = PointerPush()
        let popped = pointer.release()
        #expect(!popped)
        #expect(pointer.hover(false) == nil)
    }
}
