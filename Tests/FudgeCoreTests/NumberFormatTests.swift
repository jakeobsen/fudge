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

@Test(arguments: [
    ("0.1234 + 1", "1.235"), ("1000+1+0.1234", "2.235"), ("1.5 + 1", "16"), ("3.14 * 2", "628"), ("1.00 + 1", "101"),
    ("1.000.00 + 1", "100.001"), ("1.0000 + 1", "10.001"), ("1.5E3 + 1", "15.001"), ("1.000e3 + 1", "1.000.001"),
])
func commaDecimalDropsTheGroupingSeparator(_ query: String, _ answer: String) throws {
    // "1.234,5": `.` is only for the eye, so it's dropped wherever it stands between two digits.
    #expect(try #require(card(query, .commaDecimal)).answer == answer)
}

@Test(arguments: [".5 + 1", "5. + 1", "1..2 + 1", "1,5,5 + 1", "1.,5 + 1"])
func commaDecimalRefusesWhatIsNoNumberThere(_ query: String) {
    // A grouping separator that isn't between two digits, or a second decimal separator: no card.
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

@Test(arguments: [
    ("1,5 + 1", "16"), ("13,5*2", "270"), ("1,00 + 1", "101"), ("1,000,00 + 1", "100,001"), ("1,5E3 + 1", "15,001"),
])
func dotDecimalDropsTheGroupingSeparator(_ query: String, _ answer: String) throws {
    #expect(try #require(card(query, .dotDecimal)).answer == answer)
}

@Test(arguments: [",5 + 1", "5, + 1", "1,,2 + 1", "1.5.5 + 1"])
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
    #expect(format.typedGrouping.isEmpty, "a space separates tokens")
    let sum = try #require(card("1000,5 + 1", format, locale: fr))
    #expect(sum.answer == "1\u{202F}001,5", "fr_FR's own grouping on the card")
    #expect(sum.copyText == "1001,5")
    for space in [" ", "\u{202F}", "\u{A0}"] {
        let split = card("1\(space)000,5 + 1", format, locale: fr)
        #expect(split?.answer != "1\u{202F}001,5", "1\(space)000,5 isn't one number")
    }
}

@Test func anApostropheGroupingIsDroppedToo() throws {
    // de_CH groups with an apostrophe; a typed one may be straight or curly.
    let ch = Locale(identifier: "de_CH")
    let format = NumberFormat.system(ch)
    #expect(format.decimal == ".")
    #expect(format.typedGrouping == ["'", "\u{2019}"])
    let grouping = ch.groupingSeparator!
    #expect(try #require(card("1234.5 * 1", format, locale: ch)).answer == "1\(grouping)234.5")
    #expect(try #require(card("1'000 + 1", format, locale: ch)).answer == "1\(grouping)001")
    #expect(try #require(card("1\u{2019}000 + 1", format, locale: ch)).answer == "1\(grouping)001")
    #expect(try #require(card("1'000 kg to lb", format, locale: ch)).answer == "2\(grouping)204.622622 lb")
    #expect(card("1,000 + 1", format, locale: ch) == nil, "`,` is neither its decimal nor its grouping")
    #expect(card("1'000 + 1", .commaDecimal) == nil, "an apostrophe means nothing in another format")
}

// MARK: - Reading

@Test func theGroupingSeparatorIsDroppedBetweenDigits() {
    let comma = NumberFormat.commaDecimal
    for (literal, value) in [
        ("1.000", 1000.0), ("12.345.678,9", 12_345_678.9), (",5", 0.5), ("-1.000,5", -1000.5), ("1,5E3", 1500),
        ("1.000e3", 1e6), ("0.1234", 1234), ("1.5", 15), ("3.14", 314), ("1.00", 100), ("1.000.00", 100_000),
        ("1,2.3", 1.23), ("1.", nil), ("1", 1),
    ] as [(String, Double?)] {
        #expect(comma.number(literal) == value, "\(literal)")
    }
    for bad in [".5", "5.", "1..2", "1,5,5", "1.000,5,5", "", "-", ",", "1,5e", "1'000", "1.,5", "1,.5"] {
        #expect(comma.number(bad) == nil, "\(bad)")
    }
    let dot = NumberFormat.dotDecimal
    for (literal, value) in [("1,000", 1000.0), ("1,234,567.5", 1_234_567.5), (".5", 0.5), ("1,5", 15), ("13,5", 135)] {
        #expect(dot.number(literal) == value, "\(literal)")
    }
    for bad in [",5", "5,", "1,,2", "1.5.5", "1,000.5.5"] {
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
