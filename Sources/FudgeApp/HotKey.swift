import Carbon.HIToolbox
import FudgeCore

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility permission.
@MainActor
final class HotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil when the shortcut can't be registered (usually: another app has it).
    init?(_ spec: HotKeySpec, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else { return nil }

        var modifiers: UInt32 = 0
        if spec.command { modifiers |= UInt32(cmdKey) }
        if spec.option { modifiers |= UInt32(optionKey) }
        if spec.control { modifiers |= UInt32(controlKey) }
        if spec.shift { modifiers |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x4644_4745), id: 1)  // "FDGE"
        let registered = RegisterEventHotKey(spec.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    /// Releases the shortcut. A HotKey normally lives as long as the app.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
