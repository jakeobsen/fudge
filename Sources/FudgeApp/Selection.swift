import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FudgeCore

// The system side of `getSelectedText()` and `getSelectedFinderItems()`. The logic is `SelectedText` and
// `FinderSelection` in FudgeCore. Nothing here that can wait on another app runs on the main thread.

/// The Accessibility API.
@MainActor
final class SystemAccessibility: AccessibilityAccess {
    func isTrusted(prompt: Bool) -> Bool {
        // The key is `kAXTrustedCheckOptionPrompt`.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    func selectedText(pid: Int32) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.focusedSelectedText(pid: pid))
            }
        }
    }

    /// The app's focused element, then its selected text (`kAXFocusedUIElementAttribute`, `kAXSelectedTextAttribute`).
    nonisolated private static func focusedSelectedText(pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // A hung app would otherwise hold the call for the system default of 6 s.
        AXUIElementSetMessagingTimeout(app, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXSelectedText" as CFString, &text) == .success
        else { return nil }
        return text as? String
    }
}

/// Posts ⌘C and ⌘V to an app.
@MainActor
final class SystemCopyKey: CopyKeyPoster, PasteKeyPoster {
    func postCopy(to pid: Int32) {
        post(CGKeyCode(CopyKey.keyCode(translate: Self.charactersWithCommand)), to: pid)
    }

    func postPaste(to pid: Int32) {
        post(CGKeyCode(PasteKey.keyCode(translate: Self.charactersWithCommand)), to: pid)
    }

    private func post(_ key: CGKeyCode, to pid: Int32) {
        // A private source with explicit flags: modifiers the user is still holding (⌥ from ⌥Space, ⇧ from a ⌘⇧
        // shortcut) don't merge in and turn it into ⌥⌘C or ⇧⌘V.
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }

    /// What `code` types with ⌘ held in the current keyboard layout.
    private static func charactersWithCommand(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
        }
    }
}

/// The general pasteboard.
@MainActor
final class SystemPasteboard: PasteboardAccess {
    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }

    func contents() -> PasteboardContents {
        PasteboardContents(
            items: (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in
                    item.data(forType: type).map { PasteboardContents.Representation(type: type.rawValue, data: $0) }
                }
            })
    }

    func replace(with contents: PasteboardContents) {
        pasteboard.clearContents()
        let items = contents.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    func plainText() -> String? {
        pasteboard.string(forType: .string)
    }
}

/// Permission to send Apple Events (Automation).
@MainActor
final class SystemAutomationPermission: AutomationPermission {
    func determine(bundleIdentifier: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            // Blocks while macOS shows its consent dialog, so it gets a thread of its own and no timeout.
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, FinderEvents.code("core"), FinderEvents.code("getd"), true)
                continuation.resume(returning: status)
            }
        }
    }
}

/// Asks Finder for its selection with an Apple Event: AppleScript's `get selection as alias list`.
@MainActor
final class FinderEvents: FinderSelectionSource {
    func selection(timeout: Duration) async throws -> [URL] {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) * 1e-18
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.send(timeout: seconds) })
            }
        }
    }

    nonisolated private static func send(timeout: TimeInterval) throws -> [URL] {
        let finder = NSAppleEventDescriptor(bundleIdentifier: FinderSelection.bundleIdentifier)
        // `core/getd` (kAECoreSuite, kAEGetData).
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"), eventID: code("getd"), targetDescriptor: finder,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        // The application's `selection` property: an object specifier with no container.
        guard let selection = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj ")) else {
            throw AppleEventError(status: Int(errAECoercionFail))
        }
        selection.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        selection.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        selection.setDescriptor(NSAppleEventDescriptor(typeCode: code("sele")), forKeyword: code("seld"))
        selection.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        event.setParam(selection, forKeyword: code("----"))
        // `as alias list`: Finder's `alst` type.
        event.setParam(NSAppleEventDescriptor(typeCode: code("alst")), forKeyword: code("rtyp"))

        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            throw AppleEventError(status: (error as NSError).code)
        }
        if let status = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, status != 0 {
            throw AppleEventError(status: Int(status))
        }
        guard let result = reply.paramDescriptor(forKeyword: code("----")) else { return [] }
        let items =
            result.descriptorType == code("list")
            ? (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1) } : [result]
        return items.compactMap { $0.coerce(toDescriptorType: code("furl"))?.fileURLValue }
    }

    /// A four-character Apple Event code, e.g. "core".
    nonisolated static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
