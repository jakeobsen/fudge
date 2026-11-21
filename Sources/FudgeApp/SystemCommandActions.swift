import AppKit
import Carbon.HIToolbox
import FudgeCore
import IOKit.pwr_mgt

// The system side of the System commands (SPEC-087): public APIs only. The decisions are `SystemCommandRunner`'s in
// FudgeCore. Nothing here that can wait on another app, or on a disk, runs on the main thread.

@MainActor
final class MacSystemActions: SystemActions {
    func mayPostKeys() -> Bool {
        SystemCalls.mayPostKeysForUser()
    }

    /// ⌃⌘Q, the system's Lock Screen shortcut, posted at the HID level as if typed, so the system sees it whatever
    /// app is frontmost. The panel has just hidden; a moment lets the keyboard go back to that app first.
    func lockScreen() async throws {
        try await Task.sleep(for: .milliseconds(100))
        let key = CGKeyCode(LockScreenKey.keyCode(translate: SystemCopyKey.charactersWithCommand))
        // A private source with explicit flags: modifiers still held from the hotkey don't merge in.
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
                throw AppleEventError(status: Int(errAEEventFailed))
            }
            event.flags = [.maskControl, .maskCommand]
            event.post(tap: .cghidEventTap)
        }
    }

    func sleep() async throws {
        try await offMain {
            let port = IOPMFindPowerManagement(kIOMainPortDefault)
            guard port != 0 else { throw IOKitError(result: kIOReturnNotFound) }
            defer { IOServiceClose(port) }
            let result = IOPMSleepSystem(port)
            guard result == kIOReturnSuccess else { throw IOKitError(result: result) }
        }
    }

    func automation(of target: AutomationTarget) async -> Int32 {
        // AEDeterminePermissionToAutomateTarget needs the app running, and System Events quits when idle.
        if target == .systemEvents { await Self.launchSystemEvents() }
        return await withCheckedContinuation { continuation in
            // Blocks while macOS shows its consent dialog, so it gets a thread of its own and no timeout.
            DispatchQueue.global(qos: .userInitiated).async {
                let status = AEDeterminePermissionToAutomateTarget(
                    Self.address(of: target).aeDesc, Self.code("core"), Self.code("getd"), true)
                continuation.resume(returning: status)
            }
        }
    }

    /// Restart, Shut Down or Log Out, as Apple's QA1134 sends them to `loginwindow`. No reply is awaited: the
    /// system is on its way down, and apps with unsaved work ask about it themselves.
    func send(_ event: LoginWindowEvent) async throws {
        try await offMain {
            let appleEvent = Self.event("aevt", event.rawValue, to: .loginWindow)
            try Self.send(appleEvent, options: [.noReply], timeout: 10)
        }
    }

    /// Finder's `count every item of trash`: every volume's Trash, which listing `~/.Trash` would miss, and without
    /// Full Disk Access, which listing it would need.
    func trashCount() async throws -> Int {
        try await offMain {
            let event = Self.event("core", "cnte", to: .finder)
            event.setParam(Self.every("cobj", of: Self.property("trsh", of: .null())), forKeyword: Self.code("----"))
            event.setParam(NSAppleEventDescriptor(typeCode: Self.code("cobj")), forKeyword: Self.code("kocl"))
            let reply = try Self.send(event, options: [.waitForReply, .neverInteract], timeout: 15)
            guard let count = reply.paramDescriptor(forKeyword: Self.code("----")) else {
                throw AppleEventError(status: Int(errAECoercionFail))
            }
            return Int(count.int32Value)
        }
    }

    /// Finder's `empty trash`. Finder empties it in its own time, which can be long, so no reply is awaited.
    func emptyTrash() async throws {
        try await offMain {
            let event = Self.event("fndr", "empt", to: .finder)
            event.setParam(Self.property("trsh", of: .null()), forKeyword: Self.code("----"))
            try Self.send(event, options: [.noReply], timeout: 15)
        }
    }

    /// System Events' `dark mode of appearance preferences`.
    func darkMode() async throws -> Bool {
        try await offMain {
            let event = Self.event("core", "getd", to: .systemEvents)
            event.setParam(Self.darkModeProperty(), forKeyword: Self.code("----"))
            let reply = try Self.send(event, options: [.waitForReply, .neverInteract], timeout: 10)
            guard let value = reply.paramDescriptor(forKeyword: Self.code("----")) else {
                throw AppleEventError(status: Int(errAECoercionFail))
            }
            return value.booleanValue
        }
    }

    func setDarkMode(_ on: Bool) async throws {
        try await offMain {
            let event = Self.event("core", "setd", to: .systemEvents)
            event.setParam(Self.darkModeProperty(), forKeyword: Self.code("----"))
            event.setParam(NSAppleEventDescriptor(boolean: on), forKeyword: Self.code("data"))
            try Self.send(event, options: [.waitForReply, .neverInteract], timeout: 10)
        }
    }

    func mountedVolumes() async -> [MountedVolume] {
        (try? await offMain {
            let keys: [URLResourceKey] = [
                .volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
                .volumeIsRootFileSystemKey,
            ]
            let urls =
                FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: .skipHiddenVolumes)
                ?? []
            return urls.compactMap { url -> MountedVolume? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return MountedVolume(
                    url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                    isEjectable: values.volumeIsEjectable ?? false, isRemovable: values.volumeIsRemovable ?? false,
                    isLocal: values.volumeIsLocal ?? true, isRootFileSystem: values.volumeIsRootFileSystem ?? false)
            }
        }) ?? []
    }

    /// Unmounting waits on the disk, and on apps that hold files open there.
    func eject(_ volume: MountedVolume) async throws {
        let url = volume.url
        try await offMain { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
    }

    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(
                pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                isRegular: $0.activationPolicy == .regular)
        }
    }

    func hide(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.hide()
    }

    /// Asks the app to quit, as ⌘Q does, so one with unsaved work asks about it.
    func quit(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
    }

    // MARK: - Apple Events

    nonisolated private static let systemEventsID = "com.apple.systemevents"

    private static func launchSystemEvents() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsID).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEventsID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Who an event goes to. `loginwindow` is addressed as QA1134 does, as the system process.
    nonisolated private static func address(of target: AutomationTarget) -> NSAppleEventDescriptor {
        switch target {
        case .finder:
            return NSAppleEventDescriptor(bundleIdentifier: RunningApp.finder)
        case .systemEvents:
            return NSAppleEventDescriptor(bundleIdentifier: systemEventsID)
        case .loginWindow:
            var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
            return NSAppleEventDescriptor(
                descriptorType: DescType(typeProcessSerialNumber), bytes: &process,
                length: MemoryLayout<ProcessSerialNumber>.size)!
        }
    }

    nonisolated private static func event(_ eventClass: String, _ id: String, to target: AutomationTarget)
        -> NSAppleEventDescriptor
    {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(id), targetDescriptor: address(of: target),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends `event`; a failure, or an error in the reply, is an `AppleEventError` with its OSStatus.
    @discardableResult
    nonisolated private static func send(
        _ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions, timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: options, timeout: timeout)
        } catch {
            throw AppleEventError(status: (error as NSError).code)
        }
        if let status = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, status != 0 {
            throw AppleEventError(status: Int(status))
        }
        return reply
    }

    /// The property `name` of `container` (`.null()` for the application).
    nonisolated private static func property(_ name: String, of container: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        specifier(
            want: "prop", form: NSAppleEventDescriptor(enumCode: code("prop")),
            key: NSAppleEventDescriptor(typeCode: code(name)), from: container)
    }

    /// Every element of class `elementClass` in `container`.
    nonisolated private static func every(_ elementClass: String, of container: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        var all = code("all ")
        let ordinal = NSAppleEventDescriptor(
            descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size)!
        return specifier(
            want: elementClass, form: NSAppleEventDescriptor(enumCode: code("indx")), key: ordinal, from: container)
    }

    /// System Events' `dark mode` (`thme`) of its `appearance preferences` (`aprp`).
    nonisolated private static func darkModeProperty() -> NSAppleEventDescriptor {
        property("thme", of: property("aprp", of: .null()))
    }

    nonisolated private static func specifier(
        want: String, form: NSAppleEventDescriptor, key: NSAppleEventDescriptor, from container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        specifier.setDescriptor(form, forKeyword: code("form"))
        specifier.setDescriptor(key, forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier
    }

    nonisolated private static func code(_ text: String) -> FourCharCode {
        FinderEvents.code(text)
    }

    /// Runs `work` on a thread of its own and waits for it.
    private func offMain<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// An IOKit call that failed, with its `IOReturn`.
struct IOKitError: Error, LocalizedError {
    var result: IOReturn

    var errorDescription: String? { "IOKit error \(String(format: "0x%08x", UInt32(bitPattern: result)))" }
}
