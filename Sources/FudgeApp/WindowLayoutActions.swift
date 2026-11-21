import Foundation
import FudgeCore

/// What the user's own window commands (SPEC-094) do to the system: read the windows for Save Layout…, and move the
/// frontmost window or a layout's windows. The app uses `system`; a snapshot run uses `inert`, which reads only the
/// made-up windows it's given and moves nothing.
@MainActor
struct WindowLayoutActions {
    /// The windows to save; nil without Accessibility permission.
    var capture: () async -> [SavedWindow]?
    /// Moves the frontmost window to a custom position; the HUD's message, if any.
    var position: (WindowFractions) async -> String?
    /// Applies a layout; the HUD's message.
    var apply: (SavedWindowLayout) async -> String

    static let system = WindowLayoutActions(
        capture: { await SystemCalls.captureLayout() },
        position: { await SystemCalls.windowPosition($0) },
        apply: { await SystemCalls.applyLayout($0) })

    /// For snapshot runs: Save Layout… gets `windows`, and nothing is moved.
    static func inert(windows: [SavedWindow]) -> WindowLayoutActions {
        WindowLayoutActions(
            capture: { windows },
            position: { _ in nil },
            apply: { LayoutPlacement(placed: 0, skipped: $0.windows.count).message })
    }
}
