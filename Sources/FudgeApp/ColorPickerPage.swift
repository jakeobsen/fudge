import AppKit
import FudgeCore
import SwiftUI

/// Pick Color's loupe: macOS's own (`NSColorSampler`), which needs no Screen Recording permission. It gives the color
/// in the display's color space, which `PickedColor(cgColor:)` converts to sRGB.
struct ScreenColorSampler: ColorSampling {
    @MainActor func sample() async -> PickedColor? {
        guard let color = await NSColorSampler().sample() else { return nil }
        return PickedColor(cgColor: color.cgColor)
    }
}

/// The Settings window's Color Picker page: the Copy Format that Pick Color and ↵ in Recent Colors use.
struct ColorPickerPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Section {
                SettingsPopupRow(
                    "Copy Format",
                    selection: Binding(get: { model.colorFormat }, set: { model.setColorFormat($0) }),
                    options: ColorFormat.allCases.map { ($0, $0.title) },
                    help: "How Pick Color copies the color you pick, and ↵ in Recent Colors copies one. ⌘K in Recent "
                        + "Colors offers every format."
                )
            }
        }
        .formStyle(.grouped)
    }
}
