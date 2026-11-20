import AppKit

extension NSApplication {
    /// Brings fudge to the front for something the user just asked for. fudge's panel never activates fudge, so
    /// another app is frontmost, and since macOS 14 the plain `activate()` is a request that app may decline; the
    /// window then stays behind it. `activate(ignoringOtherApps:)` is deprecated but still brings an accessory app
    /// forward. Never call this from a background path.
    func activateFromUserAction() {
        activate(ignoringOtherApps: true)
    }
}
