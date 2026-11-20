import Foundation
import Testing

@testable import FudgeCore

private let enUS = Locale(identifier: "en_US")
private let daDK = Locale(identifier: "da_DK")
private let enDK = Locale(identifier: "en_DK")
private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!

/// 10:00 UTC on a day of 2026.
private func day(_ month: Int, _ day: Int) -> Date {
    var components = DateComponents(year: 2026, month: month, day: day, hour: 10)
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}

private func calculate(_ query: String, _ locale: Locale = enUS, now: Date = day(1, 15)) -> CalculatorResult? {
    Calculator.evaluate(query, locale: locale, now: now, timeZone: copenhagen)
}

// MARK: - Arithmetic

@Test(arguments: [
    ("2+3*4", 14.0), ("5+5/10*39", 24.5), ("(1+2)^3", 27), ("15% of 200", 30), ("200 + 10%", 220),
    ("sqrt(16)", 4), ("pi*2", 2 * Double.pi), ("2pi", 2 * Double.pi), ("3(4+5)", 27), ("5!", 120),
    ("log(1000)", 3), ("ln(e)", 1), ("sin(0)", 0), ("2 × 3 ÷ 4", 1.5),
])
func arithmeticValues(_ query: String, _ value: Double) throws {
    let result = try #require(Arithmetic.evaluate(query))
    #expect(Swift.abs(result - value) < 1e-9)
}

@Test func trigTakesRadians() throws {
    let result = try #require(Arithmetic.evaluate("cos(pi)"))
    #expect(Swift.abs(result + 1) < 1e-12)
}

@Test func arithmeticCardInEachLocale() throws {
    let us = try #require(calculate("5+5/10*39", enUS))
    #expect(us.kind == .arithmetic)
    #expect(us.question == "5+5/10*39")
    #expect(us.questionLabel == "Expression")
    #expect(us.answer == "24.5")
    #expect(us.answerLabel == "Twenty-Four Point Five")
    #expect(try #require(calculate("5+5/10*39", daDK)).answer == "24,5")
    #expect(try #require(calculate("5+5/10*39", enDK)).answer == "24,5")
}

@Test func answersUseGroupingButTheCopyDoesNot() throws {
    let us = try #require(calculate("1234*1000", enUS))
    #expect(us.answer == "1,234,000")
    #expect(us.copyText == "1234000")
    let da = try #require(calculate("1234,5*1000", daDK))
    #expect(da.answer == "1.234.500")
    #expect(da.copyText == "1234500")
    #expect(try #require(calculate("10/4", daDK)).copyText == "2,5", "the locale's decimal separator")
    #expect(da.questionAndAnswer == "1234,5*1000 = 1.234.500")
}

@Test func hugeAnswersAreNotSpelledOut() throws {
    // Spelling out tops out near 2^54: past 1e15 the words would name a different number.
    #expect(try #require(calculate("10^14", enUS)).answerLabel == "One Hundred Trillion")
    #expect(try #require(calculate("10^17", enUS)).answerLabel == "Result")
    #expect(try #require(calculate("10^20", enUS)).answerLabel == "Result")
    #expect(try #require(calculate("-10^20", enUS)).answerLabel == "Result")
}

@Test func tenSignificantDigitsAndScientificOutsideTheRange() throws {
    #expect(try #require(calculate("1/3", enUS)).answer == "0.3333333333")
    #expect(try #require(calculate("10^15", enUS)).answer.contains("E"), "1e15 is scientific")
    #expect(try #require(calculate("10^14", enUS)).answer == "100,000,000,000,000")
    #expect(try #require(calculate("1/10^7", enUS)).answer.contains("E"), "below 1e-6 is scientific")
    #expect(try #require(calculate("1/10^6", enUS)).answer == "0.000001")
}

@Test func theCardNeverRoundsTheIntegerPartAndTheCopyKeepsFifteenDigits() throws {
    let us = try #require(calculate("123456789012.5*1", enUS))
    #expect(us.answer == "123,456,789,013", "12 digits: the integer part, rounded in the fraction")
    #expect(us.copyText == "123456789012.5")
    #expect(us.answerLabel.hasSuffix("Seven Hundred Eighty-Nine Thousand Thirteen"), "spelled as shown")
    #expect(us.questionAndAnswer == "123456789012.5*1 = 123,456,789,013")
    let dk = try #require(calculate("123456789012,5*1", enDK))
    #expect(dk.answer == "123.456.789.013")
    #expect(dk.copyText == "123456789012,5", "the copy uses the locale's decimal separator")
}

@Test func theCardShowsBetweenTenAndFifteenSignificantDigits() {
    #expect(Calculator.cardDigits(for: 0.5) == 10)
    #expect(Calculator.cardDigits(for: 1_234_567_890.5) == 10)
    #expect(Calculator.cardDigits(for: -12_345_678_901.5) == 11)
    #expect(Calculator.cardDigits(for: 123_456_789_012_345.5) == 15)
    #expect(Calculator.cardDigits(for: 999_999_999_999_999) == 15)
    #expect(Calculator.cardDigits(for: 1e15) == 10, "scientific notation")
    #expect(Calculator.cardDigits(for: 1e20) == 10)
    #expect(Calculator.cardDigits(for: 3e-8) == 10)
    #expect(Calculator.cardDigits(for: .infinity) == 10)
}

@Test func copiesKeepFifteenSignificantDigits() throws {
    let us = try #require(calculate("1/3", enUS))
    #expect(us.answer == "0.3333333333")
    #expect(us.copyText == "0.333333333333333")
    let dk = try #require(calculate("1/3", enDK))
    #expect(dk.answer == "0,3333333333")
    #expect(dk.copyText == "0,333333333333333")
}

@Test(arguments: [("0.1+0.2", "0.3", "0,3"), ("1.1*3", "3.3", "3,3")])
func floatingPointNoiseDoesNotShow(_ query: String, _ us: String, _ dk: String) throws {
    let american = try #require(calculate(query, enUS))
    #expect(american.answer == us)
    #expect(american.copyText == us)
    let danish = try #require(calculate(query.replacingOccurrences(of: ".", with: ","), enDK))
    #expect(danish.answer == dk)
    #expect(danish.copyText == dk)
}

@Test func scientificAnswersAtBothPrecisions() throws {
    let huge = try #require(calculate("2^60", enUS))
    #expect(huge.answer == "1.152921505E18", "the card keeps 10 digits in scientific notation")
    #expect(huge.copyText == "1.15292150460685E18")
    #expect(try #require(calculate("2^60", enDK)).answer == "1,152921505E18")
    let tiny = try #require(calculate("1/(3*10^7)", enUS))
    #expect(tiny.answer == "3.333333333E-8")
    #expect(tiny.copyText == "3.33333333333333E-8")
    #expect(try #require(calculate("1/(3*10^7)", enDK)).copyText == "3,33333333333333E-8")
}

// MARK: - Scientific notation

@Test func aNumberWithAnExponentIsOneToken() {
    // As the card writes it, in each locale.
    #expect(Arithmetic.tokenize("1.152921505E18", format: .dotDecimal) == [.number(1.152921505e18)])
    #expect(Arithmetic.tokenize("1,152921505E18", format: .commaDecimal) == [.number(1.152921505e18)])
    #expect(Arithmetic.tokenize("3.333333333E-8", format: .dotDecimal) == [.number(3.333333333e-8)])
    #expect(Arithmetic.tokenize("1e-7") == [.number(1e-7)])
    #expect(Arithmetic.tokenize("6.02e+23") == [.number(6.02e23)])
    #expect(Arithmetic.tokenize("2e+1") == [.number(20)], "a digit after the sign: an exponent, as in code")
    #expect(Arithmetic.tokenize("1,000e3", format: .dotDecimal) == [.number(1e6)], "grouping before the exponent")
    // No digit straight after the e (and sign), or a space inside: the constant e.
    #expect(Arithmetic.tokenize("2e") == [.number(2), .name("e")])
    #expect(Arithmetic.tokenize("2e + 1") == [.number(2), .name("e"), .symbol("+"), .number(1)])
    #expect(Arithmetic.tokenize("2e+ 1") == [.number(2), .name("e"), .symbol("+"), .number(1)])
    #expect(Arithmetic.tokenize("2 e3") == [.number(2), .name("e"), .number(3)])
    #expect(Arithmetic.tokenize("1e3e") == [.number(1000), .name("e")], "an exponent's e isn't read again")
    #expect(Arithmetic.tokenize("2exp(0)") == [.number(2), .name("exp"), .symbol("("), .number(0), .symbol(")")])
}

@Test(arguments: [
    ("1e-7*3", 3e-7, "3E-7", "3E-7"),
    ("2.5E3 + 1", 2501, "2,501", "2.501"),
    ("6.02e+23 / 2", 3.01e23, "3.01E23", "3,01E23"),
    ("2e", 2 * M_E, "5.436563657", "5,436563657"),
    ("2e + 1", 2 * M_E + 1, "6.436563657", "6,436563657"),
    ("2e+1 * 2", 40, "40", "40"),
    ("1e3e", 1000 * M_E, "2,718.281828", "2.718,281828"),
    ("e^2", M_E * M_E, "7.389056099", "7,389056099"),
    ("-1e2^2", -10000, "-10,000", "-10.000"),
    ("1.152921505E18 * 2", 2.30584301e18, "2.30584301E18", "2,30584301E18"),
])
func scientificNotationInEachLocale(_ query: String, _ value: Double, _ us: String, _ dk: String) throws {
    let american = try #require(calculate(query, enUS))
    #expect(american.kind == .arithmetic)
    #expect(american.answer == us)
    let result = try #require(Arithmetic.evaluate(query, format: .dotDecimal))
    #expect(Swift.abs(result - value) <= Swift.abs(value) * 1e-12)
    // en_DK's decimal separator is `,`.
    #expect(try #require(calculate(query.replacingOccurrences(of: ".", with: ","), enDK)).answer == dk)
}

@Test(arguments: [
    "2.5E3", "1e-7", "2e+1", "-1e2", "1.152921505E18", "1e400", "1e400 + 1", "1e308*10", "-1e400*1",
])
func scientificNotationWithoutACard(_ query: String) {
    // A lone number, with or without an exponent, isn't a calculation; nor is a result that overflows.
    #expect(calculate(query, enUS) == nil)
    #expect(calculate(query, enDK) == nil)
}

@Test func theCardsOwnAnswerCanBeCalculatedWith() throws {
    let huge = try #require(calculate("2^60", enUS))
    let again = try #require(calculate(huge.answer + " * 2", enUS))
    #expect(again.answer == "2.30584301E18")
    let copied = try #require(calculate(huge.copyText + " / 2^60", enUS))
    #expect(copied.answer == "1")
    let dk = try #require(calculate("2^60", enDK))
    #expect(try #require(calculate(dk.answer + " * 2", enDK)).answer == "2,30584301E18")
}

@Test func conversionsReadAnExponent() throws {
    #expect(try #require(calculate("1e3 kg to lb", enUS)).answer == "2,204.622622 lb")
    #expect(try #require(calculate("1e3 kg to lb", enDK)).answer == "2.204,622622 lb")
    #expect(try #require(calculate("1,5E3 kg to lb", enDK)).answer == "3.306,933933 lb")
    #expect(try #require(calculate("2.5e-3 km to m", enUS)).answer == "2.5 m")
}

@Test func readingCommasDependsOnTheLocale() throws {
    #expect(try #require(calculate("1,000+1", enUS)).answer == "1,001", "grouping where `.` is the decimal")
    #expect(try #require(calculate("1,234,567.5+0.5", enUS)).copyText == "1234568")
    #expect(calculate("13,5*2", enUS) == nil, "any other comma: no card, never a decimal point")
    #expect(try #require(calculate("1,5+1", daDK)).answer == "2,5", "the decimal point in da_DK")
    #expect(calculate("1,5+1.5", daDK) == nil, "`.` groups in da_DK, so `1.5` is no number")
}

@Test(arguments: [
    "42", "3,5", "e", "pi", "-5", "1/0", "kg to km", "safari", "", "   ", "2026-11-20", "1999-01-31", "e e",
    "pi pi", "π π", "tau e pi",
])
func noCard(_ query: String) {
    #expect(calculate(query, enUS) == nil)
    #expect(calculate(query, daDK) == nil)
}

@Test(arguments: [
    ("-2^2", -4.0), ("(-2)^2", 4), ("2^-1", 0.5), ("-2^-2", -0.25), ("2^3^2", 512), ("-10^20", -1e20), ("-3!", -6),
    ("-10% of 50", -5), ("2pi^2", 2 * Double.pi * Double.pi), ("2 -3", -1), ("2*-3", -6), ("-(2)^2", -4),
    ("100 - 10%", 90), ("50% of 2^2", 2),
])
func aSignBindsLooserThanAPower(_ query: String, _ value: Double) throws {
    let result = try #require(Arithmetic.evaluate(query))
    #expect(Swift.abs(result - value) <= Swift.abs(value) * 1e-12)
}

@Test func datesAreNotCalculationsButDateLikeArithmeticIs() throws {
    #expect(Arithmetic.evaluate("2026-11-20") == nil)
    #expect(Arithmetic.evaluate(" 2026-11-20 ") == nil)
    #expect(Arithmetic.evaluate("2026-11-20 + 1") == 1996)
    #expect(Arithmetic.evaluate("2026-13-20") == 1993, "month 13 isn't a date")
    #expect(Arithmetic.evaluate("2026-11-32") == 1983, "day 32 isn't a date")
    #expect(try #require(calculate("2026-11-20 + 1", enUS)).answer == "1,996")
}

@Test func constantsAloneAreNotCalculationsButWithAnOperationTheyAre() throws {
    #expect(Arithmetic.evaluate("e e") == nil)
    #expect(Arithmetic.evaluate("pi pi") == nil)
    #expect(try #require(Arithmetic.evaluate("2 pi")) == 2 * Double.pi)
    #expect(try #require(Arithmetic.evaluate("e^2")) == M_E * M_E)
}

@Test func longQueriesAreNotEvaluated() {
    let long = Array(repeating: "1+", count: 100).joined() + "1"
    #expect(long.count == 201)
    #expect(calculate(long) == nil)
    #expect(calculate(String(long.dropFirst(2))) != nil, "200 characters still count")
}

@Test func aWorstCaseQueryIsFast() {
    let query = String((Array(repeating: "(9.5*8+", count: 28).joined() + "1").prefix(200))
    let start = Date()
    _ = calculate(query)
    _ = calculate(query, daDK)
    #expect(Date().timeIntervalSince(start) < 0.1, "two evaluations within 50 ms each")
}

// MARK: - Units

@Test func unitConversionCard() throws {
    let dk = try #require(calculate("13kg to lbs", enDK))
    #expect(dk.kind == .units)
    #expect(dk.question == "13kg to lbs")
    #expect(dk.questionLabel == "Kilograms")
    #expect(dk.answer == "28,66009408 lb")
    #expect(dk.answerLabel == "Pounds")
    #expect(try #require(calculate("13kg to lbs", daDK)).answer == "28,66009408 lb")
    #expect(try #require(calculate("13kg to lbs", enUS)).answer == "28.66009408 lb")
}

@Test func unitAnswersUseBothPrecisions() throws {
    let dk = try #require(calculate("13kg to lbs", enDK))
    #expect(dk.answer == "28,66009408 lb")
    #expect(dk.copyText == "28,6600940840341 lb")
    let us = try #require(calculate("13kg to lbs", enUS))
    #expect(us.copyText == "28.6600940840341 lb")
}

@Test func unitExamples() throws {
    #expect(try #require(calculate("100f to c", enUS)).answer == "37.77777778 °C")
    #expect(try #require(calculate("100f to c", enUS)).answerLabel == "Celsius")
    #expect(try #require(calculate("5 km in miles", enUS)).answer == "3.106855961 mi")
    let gigabytes = try #require(calculate("2 gb in mb", enUS))
    #expect(gigabytes.answer == "2,000 MB", "SI, as Foundation gives")
    #expect(gigabytes.copyText == "2000 MB")
    #expect(try #require(calculate("2 gib in mib", enUS)).answer == "2,048 MiB")
    #expect(try #require(calculate("13,5 kg = g", daDK)).answer == "13.500 g")
    #expect(try #require(calculate("5 in to cm", enUS)).answer == "12.7 cm", "`in` as inches")
    #expect(try #require(calculate("1 h in min", enUS)).answer == "60 min")
    #expect(try #require(calculate("1 day in hours", enUS)).answer == "24 h")
    #expect(try #require(calculate("1 atm in hpa", enUS)).answer == "1,013.25 hPa")
    #expect(try #require(calculate("100 kmh to mph", enUS)).answerLabel == "Miles per Hour")
}

// MARK: - Time zones

@Test(arguments: [(1, 15, "07.00", "EST"), (7, 15, "07.00", "EDT"), (3, 20, "08.00", "EDT"), (10, 28, "08.00", "EDT")])
func copenhagenToNewYork(_ month: Int, _ date: Int, _ time: String, _ zone: String) throws {
    let result = try #require(calculate("13.00 copenhagen time to new york time", enDK, now: day(month, date)))
    #expect(result.kind == .timeZone)
    #expect(result.question == "13.00 copenhagen time to new york time")
    #expect(result.questionLabel == "13.00, Copenhagen")
    #expect(result.answer.hasSuffix("at \(time)"))
    #expect(result.answerLabel == "New York, \(zone)")
    #expect(result.copyText == result.answer)
}

@Test func theAnswerIsTheTargetsLongDateAndShortTime() throws {
    let dk = try #require(calculate("13.00 copenhagen time to new york time", enDK, now: day(11, 20)))
    #expect(dk.answer == "20 November 2026 at 07.00")
    let da = try #require(calculate("13:00 copenhagen to new york", daDK, now: day(11, 20)))
    #expect(da.answer == "20. november 2026 kl. 07.00")
    let us = try #require(calculate("13:00 copenhagen to new york", enUS, now: day(11, 20)))
    // en_US puts a narrow no-break space before AM and PM.
    #expect(us.answer == "November 20, 2026 at 7:00\u{202F}AM")
    #expect(us.questionLabel == "1:00\u{202F}PM, Copenhagen")
}

@Test func crossingMidnightShowsTheOtherDate() throws {
    let result = try #require(calculate("23:00 new york time in tokyo", enDK))
    #expect(result.answer == "16 January 2026 at 13.00")
    #expect(result.questionLabel == "23.00, New York")
}

@Test func abbreviations() throws {
    let pst = try #require(calculate("3pm cet in pst", enDK))
    #expect(pst.answer == "15 January 2026 at 06.00")
    #expect(pst.questionLabel == "15.00, CET")
    #expect(pst.answerLabel == "PST")
    #expect(try #require(calculate("13:00 cet in pst", enDK)).answer.hasSuffix("04.00"))
    #expect(try #require(calculate("12:00 cst in utc", enDK)).answer.hasSuffix("18.00"), "CST is US Central")
    #expect(try #require(calculate("12:00 utc in ist", enDK)).answer.hasSuffix("17.30"), "IST is India's")
    #expect(try #require(calculate("3 pm cet in pst", enDK)).answer.hasSuffix("06.00"))
}

@Test func abbreviationsFollowSummerTime() throws {
    let summer = try #require(calculate("3pm cet in pst", enDK, now: day(7, 15)))
    #expect(summer.answer == "15 July 2026 at 06.00")
    #expect(summer.questionLabel == "15.00, CEST", "CET in summer is CEST")
    #expect(summer.answerLabel == "PDT", "PST in summer is PDT")
    let london = try #require(calculate("12:00 london to utc", enDK, now: day(7, 15)))
    #expect(london.answer.hasSuffix("11.00"))
    #expect(try #require(calculate("time in london", enDK)).answerLabel == "London, GMT")
    #expect(try #require(calculate("time in london", enDK, now: day(7, 15))).answerLabel == "London, BST")
}

@Test func familiarAbbreviationsForZonesFoundationOnlyHasOffsetsFor() throws {
    #expect(try #require(calculate("time in copenhagen", enDK)).answerLabel == "Copenhagen, CET")
    #expect(try #require(calculate("time in copenhagen", enDK, now: day(7, 15))).answerLabel == "Copenhagen, CEST")
    #expect(try #require(calculate("time in phoenix", enDK, now: day(7, 15))).answerLabel == "Phoenix, MST")
    #expect(try #require(calculate("time in auckland", enDK)).answerLabel == "Auckland, NZDT")
    #expect(try #require(calculate("time in shanghai", enDK)).answerLabel == "Shanghai, GMT+8", "never CST")
    for identifier in ["Europe/Kyiv", "Europe/Kiev"] {
        let zone = try #require(TimeZone(identifier: identifier))
        #expect(TimeZoneConversion.abbreviation(of: zone, at: day(1, 15)) == "EET", "\(identifier)")
        #expect(TimeZoneConversion.abbreviation(of: zone, at: day(7, 15)) == "EEST", "\(identifier)")
    }
    #expect(TimeZoneConversion.place("cest")?.zone.identifier == "Europe/Berlin", "typed input is unchanged")
    #expect(TimeZoneConversion.place("kst") == nil, "display only")
}

@Test func nowInAPlace() throws {
    let tokyo = try #require(calculate("time in tokyo", enDK))
    #expect(tokyo.questionLabel == "now, Copenhagen")
    #expect(tokyo.answer == "15 January 2026 at 19.00")
    #expect(tokyo.answerLabel == "Tokyo, JST")
    #expect(try #require(calculate("now in london", enDK)).answer == "15 January 2026 at 10.00")
    #expect(try #require(calculate("Time in San Francisco", enDK)).answerLabel.hasPrefix("San Francisco"))
}

@Test(arguments: ["copenhagen to new york", "london", "time in atlantis", "25:00 cet in pst", "13pm cet in pst"])
func notATimeConversion(_ query: String) {
    #expect(calculate(query, enDK)?.kind != .timeZone)
}
