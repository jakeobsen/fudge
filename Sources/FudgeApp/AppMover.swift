import AppKit
import FudgeCore

/// The offer to move Fudge to Applications at launch (SPEC-114 §1), when it runs from its disk image or from a
/// translocated copy of a download (`AppLocation`, core). Snapshot runs leave launch before it, and tests never run
/// the app.
@MainActor
enum AppMover {
    /// Where the running app is: its bundle's path, and whether its volume is read-only.
    static func location(of bundle: URL = Bundle.main.bundleURL) -> AppLocation {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return AppLocation(bundlePath: bundle.path, isOnReadOnlyVolume: readOnly)
    }

    /// Asks once, at launch. Not Now keeps this copy running and doesn't ask again this run. A copy opened right after
    /// a move that still runs from a read-only place says so once instead, so the offer never loops. Returns true
    /// when the app has been moved and this copy is quitting, so the moved one opens in its place.
    static func offer(_ location: AppLocation) -> Bool {
        switch location.launchStep(arguments: CommandLine.arguments) {
        case .nothing:
            return false
        case .stillNotMoved:
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Fudge is still running from a temporary copy"
            alert.informativeText = AppLocation.stillNotMovedMessage
            alert.runModal()
            return false
        case .offer:
            break
        }
        let files = FileManager.default
        let destination = AppLocation.destination(
            for: Bundle.main.bundleURL, applicationsWritable: files.isWritableFile(atPath: "/Applications"),
            home: files.homeDirectoryForCurrentUser)
        guard let message = location.moveMessage(destination: destination) else { return false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = AppLocation.moveTitle
        alert.informativeText = message
        alert.addButton(withTitle: "Move to Applications")  // the first button is ↵
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return move(Bundle.main.bundleURL, to: destination)
    }

    /// Copies the app to `destination`, asking first when a copy is there already, then opens the new one once
    /// this one has quit. Any failure says so and keeps this copy running.
    private static func move(_ source: URL, to destination: URL) -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard askToReplace() else { return false }
            guard quitCopy(at: destination) else {
                fail("The Fudge in Applications is still running. Quit it from its menu bar icon, then try again.")
                return false
            }
        }
        // A standard account's own Applications folder may not exist yet.
        try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copied beside it under a hidden name first, so a failed copy never leaves half an app in Applications.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.copyItem(at: source, to: staging)
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.moveItem(at: staging, to: destination)
        } catch {
            try? files.removeItem(at: staging)
            fail(error.localizedDescription)
            return false
        }
        // This copy already passed Gatekeeper's check, and the new one is the same files. Left quarantined, a copy
        // that wasn't moved by Finder is translocated again, and the offer would come back at every launch.
        clearQuarantine(destination)
        do {
            try reopen(destination, after: ProcessInfo.processInfo.processIdentifier)
        } catch {
            fail("Fudge is in Applications now. Open it from there. (\(error.localizedDescription))")
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    private static func askToReplace() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the Fudge in Applications?"
        alert.informativeText =
            "Applications already has a copy of Fudge. It goes to the Trash, and this one takes its place."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks a Fudge running from `bundle` to quit and waits for it, up to 5 s. True when none is running there.
    private static func quitCopy(at bundle: URL) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return running.allSatisfy(\.isTerminated)
    }

    private static func clearQuarantine(_ bundle: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(bundle.path, attribute, XATTR_NOFOLLOW)
        guard let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files { removexattr(file.path, attribute, XATTR_NOFOLLOW) }
    }

    /// Opens `bundle` once process `pid` has ended: a shell that outlives this app waits for it, then runs `open`.
    /// The paths go in as arguments, never into the script.
    private static func reopen(_ bundle: URL, after pid: Int32) throws {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2" --args "$3""#,
            "fudge-move", String(pid), bundle.path, AppLocation.movedArgument,
        ]
        try waiter.run()
    }

    private static func fail(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move Fudge to Applications"
        alert.informativeText = reason
        alert.runModal()
    }
}
