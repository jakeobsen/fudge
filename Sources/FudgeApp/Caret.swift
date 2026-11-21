import ApplicationServices
import Carbon.HIToolbox
import FudgeCore

/// The focused text field of an app through the Accessibility API, and ← presses, for placing a snippet's caret
/// (SPEC-101). Only the field's length and selection are read, never its value. `CaretPlacer` calls it off the main
/// actor, and each element gets FUD-93's 2 s timeout, so a hung app holds a background thread, never Fudge.
struct SystemCaret: CaretSystem {
    func state(of pid: Int32) -> TextFieldState? {
        guard let field = Self.focusedElement(of: pid) else { return nil }
        var count: Int?
        if let value = Self.value(field, kAXNumberOfCharactersAttribute) as? Int { count = value }
        var selection: FieldRange?
        if let value = Self.value(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                selection = FieldRange(location: range.location, length: range.length)
            }
        }
        guard count != nil || selection != nil else { return nil }
        return TextFieldState(count: count, selection: selection)
    }

    func setCaret(_ location: Int, of pid: Int32) -> Bool {
        guard let field = Self.focusedElement(of: pid) else { return false }
        var settable: DarwinBoolean = false
        guard
            AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func postLeftArrows(_ count: Int, to pid: Int32) {
        // ← is the same key in every layout (kVK_LeftArrow), and carries the function-key and numeric-pad flags, as
        // a typed one does. A private source with only those flags: modifiers the user is still holding don't merge
        // in and turn ← into ⇧← selecting text.
        // Each carries Fudge's marker, as every key Fudge posts does, so snippet expansion never reads it as typing.
        let source = CGEventSource(stateID: .privateState)
        source?.userData = SnippetExpander.marker
        for _ in 0..<count {
            for down in [true, false] {
                guard
                    let event = CGEvent(
                        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: down)
                else { continue }
                event.flags = [.maskSecondaryFn, .maskNumericPad]
                event.setIntegerValueField(.eventSourceUserData, value: SnippetExpander.marker)
                event.postToPid(pid)
            }
        }
    }

    private static func focusedElement(of pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, SystemWindows.timeout)
        guard let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, SystemWindows.timeout)
        return element
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
