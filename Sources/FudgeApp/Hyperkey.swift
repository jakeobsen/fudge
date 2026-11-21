import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FudgeCore
import IOKit
import IOKit.hidsystem

/// Hyperkey's system side (SPEC-093): `hidutil` for Caps Lock → F18, an event tap on a thread of its own that turns
/// F18 into ⌘⌥⌃⇧, and Caps Lock's toggle. The decisions are `HyperkeyMapping` and `HyperTap` in core. Never in
/// snapshot runs or tests.
@MainActor
final class HyperkeyService {
    /// What's stopping Hyperkey, for the General page, or nil; called only when it changes.
    var problemChanged: (String?) -> Void = { _ in }
    private var problem: String? {
        didSet { if problem != oldValue { problemChanged(problem) } }
    }

    static let needsAccessibility =
        "Hyperkey needs Accessibility. Allow Fudge in System Settings → Privacy & Security → Accessibility."
    static let tapRefused = "Fudge couldn't watch the keyboard for Hyperkey."

    private let paths: FudgePaths
    private let mapping: any KeyMappingSystem
    /// `hidutil` runs here, in order, off the main thread.
    private let queue = DispatchQueue(label: "io.github.jakeobsen.fudge.hyperkey")
    private var tap: HyperTapThread?
    /// When it runs, and when its mapping goes (core, tested).
    private var lifecycle = HyperkeyLifecycle()
    private var permissionCheck: Timer?
    /// The switch's turn-on is under way: it isn't saved yet, so the 2 s check leaves it alone meanwhile.
    private var turningOn = false

    init(paths: FudgePaths, mapping: (any KeyMappingSystem)? = nil) {
        self.paths = paths
        self.mapping =
            mapping
            ?? HidutilKeyMapping(state: paths.supportDirectory.appendingPathComponent(HidutilKeyMapping.stateFile))
    }

    /// Follows `settings.json` and Accessibility: at launch, after an import, when Quick press changes, and every
    /// 2 s. At launch with Hyperkey off, or without Accessibility, a leftover entry of Fudge's is removed, once.
    func update() {
        let settings = FudgeSettings.load(from: paths.settingsFile)
        tap?.setQuickPress(settings.hyperkeyQuickPress)
        if settings.hyperkey, !settings.hyperkeyQuickPress { CapsLock.turnOff() }
        if permissionCheck == nil {
            permissionCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        check()
    }

    /// The switch, or onboarding's step, turning it on: the tap first, then Fudge's entry. `done` gets the problem,
    /// if any, and Hyperkey is off again then; the caller saves the setting only when there's none. It isn't called
    /// when Hyperkey was switched off before the mapping was in.
    func turnOn(quickPress: Bool, done: @escaping @MainActor (String?) -> Void) {
        let trusted = AXIsProcessTrusted()
        switch lifecycle.next(settingOn: true, trusted: trusted) {
        case .start:
            turningOn = true
            start(quickPress: quickPress) { [weak self] problem in
                self?.turningOn = false
                if problem == nil, !quickPress { CapsLock.turnOff() }
                done(problem)
            }
        case .stop:
            stop()
            done(trusted ? Self.tapRefused : Self.needsAccessibility)
        case .nothing:
            done(tap == nil ? Self.tapRefused : nil)
        }
    }

    /// The switch turning it off: the tap stops, and Fudge's entry is removed.
    func turnOff() {
        if lifecycle.next(settingOn: false, trusted: AXIsProcessTrusted()) == .stop { stop() }
        problem = nil
    }

    /// Fudge is quitting (or was asked to by SIGTERM): Caps Lock goes back to Caps Lock before it exits.
    func quit() {
        let running = tap != nil || lifecycle.running
        tap?.end()
        tap = nil
        let mapping = self.mapping
        // Always through the queue, so a removal (or an apply) queued a moment ago has run before Fudge exits.
        queue.sync { if running { try? HyperkeyMapping.remove(mapping) } }
    }

    private func check() {
        guard !turningOn else { return }
        let settings = FudgeSettings.load(from: paths.settingsFile)
        let trusted = AXIsProcessTrusted()
        switch lifecycle.next(settingOn: settings.hyperkey, trusted: trusted) {
        case .start:
            start(quickPress: settings.hyperkeyQuickPress) { [weak self] problem in self?.problem = problem }
        case .stop:
            stop()
            problem = settings.hyperkey && !trusted ? Self.needsAccessibility : problem
        case .nothing:
            // macOS can leave a tap turned off; it goes back on, starting over.
            tap?.ensureEnabled()
            if settings.hyperkey, !trusted { problem = Self.needsAccessibility }
            if !settings.hyperkey { problem = nil }
        }
    }

    /// The tap, then the mapping; a refusal of either stops Hyperkey and removes its entry (`startFailed`).
    private func start(quickPress: Bool, done: @escaping @MainActor (String?) -> Void) {
        let thread = HyperTapThread(quickPress: quickPress)
        guard thread.begin() else {
            if lifecycle.startFailed() == .stop { stop() }
            return done(Self.tapRefused)
        }
        tap = thread
        let started = ObjectIdentifier(thread)
        let mapping = self.mapping
        queue.async {
            var problem: String?
            do throws(HyperkeyMapping.Problem) {
                try HyperkeyMapping.apply(mapping)
            } catch {
                problem = error.message
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Switched off meanwhile: the removal is queued after this, and nothing is saved.
                    guard self.tap.map(ObjectIdentifier.init) == started else { return }
                    if problem != nil, self.lifecycle.startFailed() == .stop { self.stop() }
                    done(problem)
                }
            }
        }
    }

    private func stop() {
        tap?.end()
        tap = nil
        let mapping = self.mapping
        queue.async { try? HyperkeyMapping.remove(mapping) }
    }
}

/// `/usr/bin/hidutil`, macOS's documented tool for the per-user key mapping.
struct HidutilKeyMapping: KeyMappingSystem {
    struct Failed: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "hidutil ended with status \(status)" }
    }

    /// Where it remembers that Fudge's entry replaced a Caps Lock → Caps Lock one: this Mac's, never in a backup.
    static let stateFile = "hyperkey.json"
    /// `hyperkey.json` in the support folder.
    let state: URL

    func replacedCapsLock() -> Bool {
        guard let data = try? Data(contentsOf: state),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["replacedCapsLock"] as? Bool == true
    }

    func setReplacedCapsLock(_ replaced: Bool) throws {
        guard replaced else {
            if FileManager.default.fileExists(atPath: state.path) { try FileManager.default.removeItem(at: state) }
            return
        }
        try FileManager.default.createDirectory(
            at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["replacedCapsLock": true]).write(to: state, options: .atomic)
    }

    func readMapping() throws -> String {
        try run(["property", "--get", "UserKeyMapping"])
    }

    func readKeyboardMappings() throws -> String {
        try run(["property", "--matching", "keyboard", "--get", "UserKeyMapping"])
    }

    func readModifierKeys() throws -> String {
        try run(["property", "--matching", "keyboard", "--get", "HIDKeyboardModifierMappingPairs"])
    }

    func writeMapping(_ argument: String) throws {
        _ = try run(["property", "--set", argument])
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Caps Lock's own state, which a posted key event can't toggle.
enum CapsLock {
    static func toggle() {
        withLockState { connection, on in
            IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !on)
        }
    }

    /// With Hyperkey on and no quick press, the key can't turn caps off any more, so it's turned off for the user.
    static func turnOff() {
        withLockState { connection, on in
            if on { IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false) }
        }
    }

    private static func withLockState(_ body: (io_connect_t, Bool) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return }
        defer { IOServiceClose(connection) }
        var on = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else { return }
        body(connection, on)
    }
}

/// Hyperkey's event tap, on a thread and run loop of its own, so a busy main thread never slows typing or gets the
/// tap turned off. It reads each key event's code, flags and time, never what it types, and keeps, logs, stores and
/// sends nothing about it: `HyperTap` decides, and only F18's own press time is kept.
final class HyperTapThread: Thread, @unchecked Sendable {
    private let lock = NSLock()
    private var state: HyperTap
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var running = false
    /// Set by `end()`; the run loop checks it, so a stop asked for before it runs isn't lost.
    private var stopping = false
    private let ready = DispatchSemaphore(value: 0)

    init(quickPress: Bool) {
        state = HyperTap(quickPressTogglesCapsLock: quickPress)
        super.init()
        name = "Fudge Hyperkey"
        qualityOfService = .userInteractive
    }

    /// Starts the thread and waits for its tap: false when macOS refused one (without Accessibility).
    func begin() -> Bool {
        start()
        ready.wait()
        return lock.withLock { running }
    }

    /// Stops the tap and the thread, starting over.
    func end() {
        let loop = lock.withLock {
            state.reset(.switchedOff)
            stopping = true
            return runLoop
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// Turns the tap back on if macOS left it off, starting over (the 2 s check).
    func ensureEnabled() {
        let tap = lock.withLock { self.tap }
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        lock.withLock { state.reset(.tapDisabled) }
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock { state.reset(.tapEnabled) }
    }

    func setQuickPress(_ on: Bool) {
        lock.withLock { state.quickPressTogglesCapsLock = on }
    }

    override func main() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: hyperTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        lock.withLock {
            self.tap = tap
            runLoop = loop
            running = true
        }
        ready.signal()
        while !lock.withLock({ stopping }) {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.withLock {
            self.tap = nil
            runLoop = nil
            running = false
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let kind: HyperTapEvent.Kind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off (it was slow, or for secure input). It goes back on, starting over, so no
            // Hyper is left held from before.
            let tap = lock.withLock {
                state.reset(.tapDisabled)
                return self.tap
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.withLock { state.reset(.tapEnabled) }
            return Unmanaged.passUnretained(event)
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        // Only the keyboard's own keys: what Fudge or another app posts (a paste's ⌘V, Lock Screen's ⌃⌘Q) is left
        // as it was made.
        guard event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        else { return Unmanaged.passUnretained(event) }
        let facts = HyperTapEvent(
            kind: kind, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            // The time is read here, in nanoseconds of uptime: an event's own timestamp isn't nanoseconds everywhere.
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            time: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let f18Down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(Hyperkey.f18KeyCode))
        let secureInput = IsSecureEventInputEnabled()
        let decision = lock.withLock { state.handle(facts, f18Down: f18Down, secureInput: secureInput) }
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .addHyper:
            event.flags.formUnion([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .swallowAndToggleCapsLock:
            DispatchQueue.global(qos: .userInteractive).async { CapsLock.toggle() }
            return nil
        }
    }
}

private let hyperTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HyperTapThread>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
