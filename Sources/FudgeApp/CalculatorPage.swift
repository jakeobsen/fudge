import FudgeCore
import SwiftUI

/// The Settings window's Calculator page, under Extensions: whether the calculator downloads exchange rates, whether it
/// looks up other places with Apple Maps, and the number format it reads and writes. The "Currency conversion is off"
/// card's ↵ opens it.
struct CalculatorPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // Both controls save to settings.json, which refuses a change while it's broken; this says why.
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Section {
                CurrencyRatesToggle(model: model)
                AppleMapsPlacesToggle(model: model)
                Picker(
                    selection: Binding(get: { model.numberFormat }, set: { model.setNumberFormat($0) })
                ) {
                    Text("Same as macOS (\(Calculator.format(1234.5, locale: .current, for: .card)))")
                        .tag(NumberFormatSetting.system)
                    Text("1,234.5").tag(NumberFormatSetting.dotDecimal)
                    Text("1.234,5").tag(NumberFormatSetting.commaDecimal)
                } label: {
                    Text("Number format")
                    Text("How the calculator reads the numbers you type, and writes its answers.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The calculator's currency conversion switch, saying what it downloads and from where. Onboarding's Currency step
/// uses it too.
struct CurrencyRatesToggle: View {
    let model: SettingsModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.currencyRates }, set: { model.setCurrencyRates($0) })) {
            Text("Currency conversion")
            Text("Fudge downloads exchange rates from the European Central Bank once a day.")
        }
        .toggleStyle(.switch)
    }
}

/// The calculator's Apple Maps switch (SPEC-162 B). Onboarding's Apple Maps step uses it too.
struct AppleMapsPlacesToggle: View {
    let model: SettingsModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.appleMapsPlaces }, set: { model.setAppleMapsPlaces($0) })) {
            Text("Look up other places with Apple Maps")
            Text("For time zones of places the calculator doesn't know, such as small towns.")
        }
        .toggleStyle(.switch)
    }
}
