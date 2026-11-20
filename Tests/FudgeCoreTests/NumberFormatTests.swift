import Foundation
import Testing

@testable import FudgeCore

private let enUS = Locale(identifier: "en_US")
private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!
private let now = Date(timeIntervalSince1970: 1_795_255_200)

private func card(_ query: String, _ format: NumberFormat, locale: Locale = enUS) -> CalculatorResult? {
    Calculator.evaluate(query, locale: locale, format: format, now: now, timeZone: copenhagen)
}

// MARK: - "1.234,5"

@Test(arguments: [
    ("1.000 + 1", "1.001"), ("1,5 + 1", "2,5"), ("1.234,5 * 2", "2.469"), ("12.345.678 / 2", "6.172.839"),
    (",5 + 1", "1,5"), ("1.000 kg to lb", "2.204,622622 lb"), ("1,5E3 + 1", "1.501"),
    ("12.345.678,9 - 0,9", "12.345.678"),
])
func commaDecimalCards(_ query: String, _ answer: String) throws {
    #expect(try #require(card(query, .commaDecimal)).answer == answer)
}

@Test(arguments: ["1.5 + 1", "3.14 * 2", "1.00 + 1", "1.000.00 + 1", ".5 + 1", "1,5,5 + 1", "1.0000 + 1", "1.5E3 + 1"])
func commaDecimalRefusesWhatIsNoNumberThere(_ query: String) {
    // A `.` that isn't a proper group is never read as something else: no card.
    #expect(card(query, .commaDecimal) == nil)
}

// MARK: - "1,234.5"

@Test(arguments: [
    ("1,000 + 1", "1,001"), ("1.5 + 1", "2.5"), ("1,234.5 * 2", "2,469"), (".5 + 1", "1.5"), ("1.5E3 + 1", "1,501"),
    ("1,000 kg to lb", "2,204.622622 lb"),
])
func dotDecimalCards(_ query: String, _ answer: String) throws {
    #expect(try #require(card(query, .dotDecimal)).answer == answer)
}

@Test(arguments: ["1,5 + 1", "13,5*2", "1,00 + 1", "1,000,00 + 1", ",5 + 1", "1,5E3 + 1"])
func dotDecimalRefusesWhatIsNoNumberThere(_ query: String) {
    #expect(card(query, .dotDecimal) == nil)
}

@Test func copiesUseTheDecimalSeparatorWithoutGrouping() throws {
    #expect(try #require(card("1.234,5 * 1", .commaDecimal)).copyText == "1234,5")
    #expect(try #require(card("1,234.5 * 1", .dotDecimal)).copyText == "1234.5")
    #expect(try #require(card("1.000 kg to g", .commaDecimal)).copyText == "1000000 g")
}

@Test func theFormatOverridesTheLocale() throws {
    // An American Mac set to "1.234,5", and a Danish one set to "1,234.5".
    #expect(try #require(card("1.000 + 1", .commaDecimal, locale: enUS)).answer == "1.001")
    #expect(try #require(card("1,000 + 1", .dotDecimal, locale: Locale(identifier: "da_DK"))).answer == "1,001")
}

// MARK: - "Same as macOS"

@Test func sameAsMacOSResolvesFromTheLocale() {
    #expect(NumberFormat.system(enUS) == .dotDecimal)
    #expect(NumberFormat.system(Locale(identifier: "da_DK")) == .commaDecimal)
    #expect(NumberFormat.system(Locale(identifier: "en_DK")) == .commaDecimal)
    // A decimal separator other than `.` or `,` (Arabic's ٫) gives "1,234.5".
    #expect(NumberFormat.system(Locale(identifier: "ar_SA")) == .dotDecimal)
    #expect(NumberFormatSetting.system.resolve(Locale(identifier: "da_DK")) == .commaDecimal)
    #expect(NumberFormatSetting.dotDecimal.resolve(Locale(identifier: "da_DK")) == .dotDecimal)
    #expect(NumberFormatSetting.commaDecimal.resolve(enUS) == .commaDecimal)
}

@Test func aSpaceGroupingIsShownButNeverRead() throws {
    let fr = Locale(identifier: "fr_FR")
    let format = NumberFormat.system(fr)
    #expect(format.decimal == ",")
    #expect(format.typedGrouping == nil, "a space separates tokens")
    let sum = try #require(card("1000,5 + 1", format, locale: fr))
    #expect(sum.answer == "1\u{202F}001,5", "fr_FR's own grouping on the card")
    #expect(sum.copyText == "1001,5")
    for space in [" ", "\u{202F}", "\u{A0}"] {
        let split = card("1\(space)000,5 + 1", format, locale: fr)
        #expect(split?.answer != "1\u{202F}001,5", "1\(space)000,5 isn't one number")
    }
}

@Test func anotherGroupingIsShownButNeverRead() throws {
    // de_CH groups with an apostrophe.
    let ch = Locale(identifier: "de_CH")
    let format = NumberFormat.system(ch)
    #expect(format.decimal == ".")
    #expect(format.typedGrouping == nil)
    #expect(try #require(card("1234.5 * 1", format, locale: ch)).answer == "1\(ch.groupingSeparator!)234.5")
    #expect(card("1\(ch.groupingSeparator!)000 + 1", format, locale: ch) == nil)
    #expect(card("1,000 + 1", format, locale: ch) == nil, "`,` is neither its decimal nor a typed group")
}

// MARK: - Reading

@Test func numbersAreReadStrictly() {
    let comma = NumberFormat.commaDecimal
    #expect(comma.number("1.000") == 1000)
    #expect(comma.number("12.345.678,9") == 12_345_678.9)
    #expect(comma.number(",5") == 0.5)
    #expect(comma.number("-1.000,5") == -1000.5)
    #expect(comma.number("1,5E3") == 1500)
    #expect(comma.number("1.000e3") == 1e6)
    for bad in ["1.5", "3.14", "1.00", "1.000.00", ".5", "1,5,5", "1.000,5.5", "1.", "", "-", ",", "1,5e", "1’000"] {
        #expect(comma.number(bad) == nil, "\(bad)")
    }
    let dot = NumberFormat.dotDecimal
    #expect(dot.number("1,000") == 1000)
    #expect(dot.number("1,234,567.5") == 1_234_567.5)
    #expect(dot.number(".5") == 0.5)
    for bad in ["1,5", "1,00", "13,5", ",5", "1,000,00", "1,000.5.5"] {
        #expect(dot.number(bad) == nil, "\(bad)")
    }
}

// MARK: - The setting

@Test func theSettingIsStoredAndAnUnknownValueReadsAsTheMacs() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    #expect(FudgeSettings.load(from: file).numberFormat == .system)
    var settings = FudgeSettings()
    settings.numberFormat = .commaDecimal
    try settings.save(to: file)
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(saved["numberFormat"] as? String == "comma-decimal")
    #expect(FudgeSettings.load(from: file).numberFormat == .commaDecimal)

    settings.numberFormat = .system
    try settings.save(to: file)
    let reset = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(reset["numberFormat"] == nil, "the default isn't written")

    for junk in [#"{"numberFormat":"roman"}"#, #"{"numberFormat":5}"#, #"{"numberFormat":null}"#] {
        try Data(junk.utf8).write(to: file)
        #expect(FudgeSettings.load(from: file).numberFormat == .system, "\(junk)")
    }
    #expect(NumberFormatSetting(rawValue: "dot-decimal") == .dotDecimal)
}
