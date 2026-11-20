import AppKit
import FudgeCore

extension NSApplication {
    /// Brings fudge to the front for something the user just asked for. fudge's panel never activates fudge, so
    /// another app is frontmost, and since macOS 14 the plain `activate()` is a request that app may decline; the
    /// window then stays behind it. `activate(ignoringOtherApps:)` is deprecated but still brings an accessory app
    /// forward. Every caller passes the origin of what it's doing (SPEC-045), and a background one is a bug: it would
    /// pull the user out of the app they're in.
    func activateFromUserAction(origin: CallOrigin) {
        assert(origin.mayComeForward, "a background call tried to bring Fudge forward")
        guard origin.mayComeForward else { return }
        activate(ignoringOtherApps: true)
    }
}
