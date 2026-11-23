import AppKit
import FudgeCore

// Fudge Links (SPEC-140, D-107): the only part of Fudge that declares `raycast:` and `com.raycast:`
// (`App/Links/Info.plist`). It lives in Fudge.app's `Contents/Helpers`, where only the user turning on
// "Fudge opens Raycast links" (or onboarding's button) registers it, so no build, launch or copy of Fudge makes it the
// app that opens Raycast's links. macOS opens it with such a link; it hands the link to Fudge as a get-URL Apple Event
// without bringing anything forward, then quits. It shows nothing, and logs nothing: no link or query reaches stderr,
// the unified log or Fudge.log.

@MainActor
final class LinksDelegate: NSObject, NSApplicationDelegate {
    /// Links still being handed on.
    private var handingOn = 0
    private var gotLink = false

    /// The handler goes in before launch finishes, so the link that launched it isn't missed.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openLink(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    /// Launched without a link: nothing to do.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + RaycastLinksHelper.idleQuitSeconds) {
            MainActor.assumeIsolated {
                if !self.gotLink { exit(0) }
            }
        }
    }

    @objc private func openLink(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        gotLink = true
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            RaycastLinksHelper.handsOn(text), let link = URL(string: text)
        else { return quitWhenDone() }
        let holder = RaycastLinksHelper.holder(of: Bundle.main.bundleURL)
        let targets = RaycastLinksHelper.targets(
            running: NSRunningApplication.runningApplications(withBundleIdentifier: FudgeVersion.bundleIdentifier)
                .compactMap(\.bundleURL),
            holder: holder, holderIsFudge: Bundle(url: holder)?.bundleIdentifier == FudgeVersion.bundleIdentifier)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        for target in targets {
            handingOn += 1
            NSWorkspace.shared.open([link], withApplicationAt: target, configuration: configuration) { _, _ in
                Task { @MainActor in
                    self.handingOn -= 1
                    self.quitWhenDone()
                }
            }
        }
        quitWhenDone()
    }

    private func quitWhenDone() {
        if handingOn == 0 { exit(0) }
    }
}

let delegate = LinksDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
