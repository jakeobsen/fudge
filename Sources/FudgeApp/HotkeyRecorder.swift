import AppKit
import FudgeCore
import SwiftUI

/// "Press a shortcut…", shown while a hotkey is being recorded. Meanwhile it takes every key press in the app
/// (fudge's own hotkeys are suspended) and hands it on as a `HotKeyRecording`. The Commands page's and the General
/// page's recorders both use it, so they follow the same rules.
struct HotkeyRecordingPrompt: View {
    let pressed: @MainActor (HotKeyRecording) -> Void
    @State private var monitor: Any?

    var body: some View {
        Text("Press a shortcut…")
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
            .onAppear(perform: startMonitor)
            .onDisappear(perform: stopMonitor)
    }

    private func startMonitor() {
        let pressed = pressed
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                pressed(
                    HotKeyRecording(
                        keyCode: UInt32(event.keyCode), command: flags.contains(.command),
                        option: flags.contains(.option), control: flags.contains(.control),
                        shift: flags.contains(.shift)))
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
