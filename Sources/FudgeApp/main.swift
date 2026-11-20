import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A snapshot run may never become active, so it can't take anyone's keyboard.
app.setActivationPolicy(Snapshot.isRequested(CommandLine.arguments) ? .prohibited : .accessory)
app.run()
