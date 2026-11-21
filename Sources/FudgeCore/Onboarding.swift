import Foundation

/// One screen of onboarding, with one decision. The cases, in order, are the one list of steps: adding a step is
/// adding its case (and drawing it), and an existing user then sees just that step and Done.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome
    case hotkey
    case accessibility
    case openAtLogin
    case currency
    case done
}

/// Which onboarding steps the user has answered (`onboarding.json`). Onboarding opens at every launch until it's
/// complete: every step answered, and Done clicked. A step is answered when the user leaves it with Get Started,
/// Continue or Not now.
public struct Onboarding: Sendable, Equatable {
    /// Step ids, in the order they were answered. Ids that aren't a step any more are kept.
    public private(set) var answered: [String]

    public init(answered: [String] = []) {
        var seen = Set<String>()
        self.answered = answered.filter { seen.insert($0).inserted }
    }

    /// The steps to show: the unanswered ones, in order, then Done. Empty when onboarding is complete. Once it has
    /// been completed, Welcome isn't shown again; "Something new to decide" (`hasSomethingNew`) takes its place.
    public var pending: [OnboardingStep] {
        let completedBefore = answered.contains(OnboardingStep.done.rawValue)
        let missing = OnboardingStep.allCases.filter {
            $0 != .done && !answered.contains($0.rawValue) && !(completedBefore && $0 == .welcome)
        }
        if missing.isEmpty && completedBefore { return [] }
        return missing + [.done]
    }

    public var isComplete: Bool { pending.isEmpty }

    /// It was completed before, and a step added since hasn't been answered.
    public var hasSomethingNew: Bool {
        answered.contains(OnboardingStep.done.rawValue) && !pending.isEmpty
    }

    public mutating func answer(_ step: OnboardingStep) {
        if !answered.contains(step.rawValue) { answered.append(step.rawValue) }
    }

    /// Show Onboarding Again: every step, from Welcome.
    public mutating func restart() {
        answered = []
    }

    /// Reads the file tolerantly: a missing file, or one that isn't a JSON object with an `answered` list, has
    /// nothing answered, so onboarding shows. Only strings count.
    public static func load(from file: URL) -> Onboarding {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answered = object["answered"] as? [Any]
        else { return Onboarding() }
        return Onboarding(answered: answered.compactMap { $0 as? String })
    }

    /// Writes the file atomically. A broken file is replaced: it holds nothing but the answers, which `load` read as
    /// none.
    public func save(to file: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["answered": answered], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// Accessibility on onboarding's step and on Settings → Permissions.
public enum AccessibilityPermission {
    /// Why fudge asks for it.
    public static let reason =
        "Some extensions read the text you've selected, paste into the app you were using, or move your windows. macOS "
        + "asks you to allow that under Privacy & Security → Accessibility."

    /// What Open Accessibility Settings does.
    public enum Request: Equatable, Sendable {
        /// macOS's own prompt, which also puts fudge in the pane's list. It has its own Open System Settings button.
        case prompt
        /// The Accessibility pane.
        case openPane
    }

    /// The prompt first; once it has been shown this run, the pane. One click never does both, so macOS's alert
    /// and the pane don't stack. macOS shows the prompt only while fudge isn't in the list yet, which is why a later
    /// click opens the pane itself.
    public static func request(promptShown: Bool) -> Request {
        promptShown ? .openPane : .prompt
    }
}
