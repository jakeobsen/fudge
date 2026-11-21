import Foundation

/// Apple Events the System commands send, built and read here so tests can pin their shape without sending anything
/// (`MacSystemActions` sends them).
public enum SystemAppleEvents {
    /// `errAECoercionFail`: a reply that isn't what was asked for.
    public static let coercionFailed = -1700

    /// A four-character code, as Apple Events name everything.
    public static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// The property `name` of `container` (`.null()` for the application): AppleScript's `trash`, for example.
    public static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier
    }

    /// Finder's `count items of trash` (`core/cnte`), as AppleScript sends it: the Trash (`trsh` of the application)
    /// as the direct parameter, and the class to count, `cobj` (item), as `kocl`. With `every item of trash` as the
    /// direct parameter instead, `kocl` would count what's inside each item.
    public static func countTrash(to target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = appleEvent("core", "cnte", to: target)
        event.setParam(property("trsh", of: .null()), forKeyword: code("----"))
        event.setParam(NSAppleEventDescriptor(typeCode: code("cobj")), forKeyword: code("kocl"))
        return event
    }

    /// The count in a reply: its direct parameter, only when it is, or coerces to, a 32-bit integer. Anything else, a
    /// list or nothing at all, throws `AppleEventError` rather than reading as 0.
    public static func count(in reply: NSAppleEventDescriptor) throws -> Int {
        guard let value = reply.paramDescriptor(forKeyword: code("----"))?.coerce(toDescriptorType: code("long"))
        else { throw AppleEventError(status: coercionFailed) }
        return Int(value.int32Value)
    }

    /// A yes or no in a reply, as strictly: its direct parameter must be, or coerce to, a boolean.
    public static func boolean(in reply: NSAppleEventDescriptor) throws -> Bool {
        guard let value = reply.paramDescriptor(forKeyword: code("----"))?.coerce(toDescriptorType: code("bool"))
        else { throw AppleEventError(status: coercionFailed) }
        return value.booleanValue
    }

    /// An event of `eventClass`/`id` to `target`, with a new return id.
    static func appleEvent(_ eventClass: String, _ id: String, to target: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(id), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
}
