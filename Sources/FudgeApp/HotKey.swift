import Carbon.HIToolbox
import FudgeCore

/// System-wide keyboard shortcuts through Carbon, which needs no Accessibility permission. One event handler serves
/// every registration; each has an id, and `onPress` gets the id of the one pressed. `HotKeyRegistry` (core) decides
/// what's registered. Carbon delivers hotkey events on the main thread, and nothing else touches this object, so
/// handing it to the main actor from the C callback is safe.
final class CarbonHotKeys: HotKeyRegistering, @unchecked Sendable {
    var onPress: (UInt32) -> Void = { _ in }
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let hotKeys = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKeys.onPress(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    func register(_ spec: HotKeySpec, id: UInt32) -> Bool {
        unregister(id: id)
        var modifiers: UInt32 = 0
        if spec.command { modifiers |= UInt32(cmdKey) }
        if spec.option { modifiers |= UInt32(optionKey) }
        if spec.control { modifiers |= UInt32(controlKey) }
        if spec.shift { modifiers |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4644_4745), id: id)  // "FDGE"
        guard RegisterEventHotKey(spec.keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
            let ref
        else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}
