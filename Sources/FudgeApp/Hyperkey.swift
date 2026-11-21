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
    /// Fudge's entry is in the key mapping, as far as this run knows: added, and not removed since.
    private var mapped = false
    private var permissionCheck: Timer?

    init(paths: FudgePaths, mapping: any KeyMappingSystem = HidutilKeyMapping()) {
        self.paths = paths
        self.mapping = mapping
    }

    /// Follows `settings.json`: at launch, after an import, and when Quick press changes. Starts Hyperkey when it's
    /// on and Accessibility is allowed, and stops it otherwise. Nothing runs while it's off and was never on.
    func update() {
        let settings = FudgeSettings.load(from: paths.settingsFile)
        guard settings.hyperkey else {
            if tap != nil || mapped { turnOff() }
            return
        }
        tap?.setQuickPress(settings.hyperkeyQuickPress)
        checkPermission()
        followPermission()
    }

    /// Accessibility can be turned off in System Settings at any time; Hyperkey goes with it, and Caps Lock is Caps
    /// Lock again until it's back.
    private func checkPermission() {
        guard permissionCheck == nil else { return }
        permissionCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPermission() }
        }
    }

    /// The switch, or onboarding's step, turning it on: the tap first, then Fudge's entry. `done` gets the problem,
    /// if any, and Hyperkey is off again then; the caller saves the setting only when there's none. It isn't called
    /// when Hyperkey was switched off before the mapping was in.
    func turnOn(quickPress: Bool, done: @escaping @MainActor (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            done(Self.needsAccessibility)
            return
        }
        guard startTap(quickPress: quickPress) else {
            done(Self.tapRefused)
            return
        }
        addMapping { [weak self] problem in
            guard let self else { return }
            if problem == nil {
                checkPermission()
            } else {
                stopTap()
            }
            self.problem = problem
            done(problem)
        }
    }

    /// The switch turning it off: the tap stops, and Fudge's entry is removed, always, whatever this run knows.
    func turnOff() {
        permissionCheck?.invalidate()
        permissionCheck = nil
        stopTap()
        mapped = false
        let mapping = self.mapping
        queue.async { try? HyperkeyMapping.remove(mapping) }
        problem = nil
    }

    /// Fudge is quitting: Caps Lock goes back to Caps Lock before it exits.
    func quit() {
        guard tap != nil || mapped else { return }
        stopTap()
        let mapping = self.mapping
        queue.sync { try? HyperkeyMapping.remove(mapping) }
        mapped = false
    }

    private func followPermission() {
        if !AXIsProcessTrusted() {
            if tap != nil || mapped {
                stopTap()
                mapped = false
                let mapping = self.mapping
                queue.async { try? HyperkeyMapping.remove(mapping) }
            }
            problem = Self.needsAccessibility
            return
        }
        guard tap == nil else { return }
        let settings = FudgeSettings.load(from: paths.settingsFile)
        guard settings.hyperkey else { return }
        guard startTap(quickPress: settings.hyperkeyQuickPress) else {
            problem = Self.tapRefused
            return
        }
        addMapping { [weak self] problem in
            guard let self else { return }
            if problem != nil {
                stopTap()
                // Not again every 2 s: the next launch or change of the switch tries again.
                permissionCheck?.invalidate()
                permissionCheck = nil
            }
            self.problem = problem
        }
    }

    private func startTap(quickPress: Bool) -> Bool {
        if let tap {
            tap.setQuickPress(quickPress)
            return true
        }
        let thread = HyperTapThread(quickPress: quickPress)
        guard thread.begin() else { return false }
        tap = thread
        return true
    }

    private func stopTap() {
        tap?.end()
        tap = nil
    }

    private func addMapping(_ done: @escaping @MainActor (String?) -> Void) {
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
                    // Switched off meanwhile: `turnOff` has queued the removal after this, and nothing is saved.
                    guard self.tap != nil else { return }
                    if problem == nil { self.mapped = true }
                    done(problem)
                }
            }
        }
    }
}

/// `/usr/bin/hidutil`, macOS's documented tool for the per-user key mapping.
struct HidutilKeyMapping: KeyMappingSystem {
    struct Failed: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "hidutil ended with status \(status)" }
    }

    func readMapping() throws -> String {
        try run(["property", "--get", "UserKeyMapping"])
    }

    func readKeyboardMappings() throws -> String {
        try run(["property", "--matching", "keyboard", "--get", "UserKeyMapping"])
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
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return }
        defer { IOServiceClose(connection) }
        var on = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else { return }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !on)
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
            return runLoop
        }
        if let loop { CFRunLoopStop(loop) }
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
        CFRunLoopRun()
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
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, time: event.timestamp)
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
