import Foundation
import Testing

@testable import FudgeCore

private let enUS = Locale(identifier: "en_US")
private let daDK = Locale(identifier: "da_DK")
private let enDK = Locale(identifier: "en_DK")
private let svSE = Locale(identifier: "sv_SE")
private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!

/// 21 November 2026, 10:00 UTC: the day after the fixture's reference date.
private let now = Date(timeIntervalSince1970: 1_795_255_200)
private let hour: TimeInterval = 3600

private let fixture = try! Data(
    contentsOf: Fixtures.directory.appendingPathComponent("ecb/eurofxref-daily.xml"))

private func rates(fetchedAt: Date = now.addingTimeInterval(-3 * hour)) -> ExchangeRates {
    try! ExchangeRates.parseECB(fixture, fetchedAt: fetchedAt)
}

private func calculate(_ query: String, _ locale: Locale = enUS, _ currency: CurrencyState) -> CalculatorResult? {
    Calculator.evaluate(query, locale: locale, now: now, timeZone: copenhagen, currency: currency)
}

private let ready = CurrencyState(enabled: true, rates: rates())

// MARK: - The ECB file

@Test func parsesTheECBFile() throws {
    let parsed = rates()
    #expect(parsed.date == "2026-11-20")
    #expect(parsed.rates.count == 29)
    #expect(parsed.rates["USD"] == 1.0990)
    #expect(parsed.rates["JPY"] == 174.35)
    #expect(parsed.rate("EUR") == 1)
    #expect(Set(parsed.rates.keys).isSubset(of: CurrencyConversion.codes), "every ECB currency is on the static list")
}

@Test(arguments: [
    "<html><body>Service Unavailable</body></html>", "", "<Cube><Cube time='2026-11-20'/></Cube>", "not xml",
])
func rejectsAnythingElse(_ text: String) {
    #expect(throws: ExchangeRates.ParseError.notTheDailyFile) {
        try ExchangeRates.parseECB(Data(text.utf8), fetchedAt: now)
    }
}

@Test func theCacheRoundTrips() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/exchange-rates.json")
    let original = rates()
    try original.save(to: file)
    #expect(ExchangeRates.load(from: file) == original)
}

// MARK: - Conversions

@Test func usdToEur() throws {
    let result = try #require(calculate("100 usd to eur", enUS, ready))
    #expect(result.kind == .currency)
    #expect(result.question == "100 usd to eur")
    #expect(result.questionLabel == "US Dollars")
    #expect(result.answer == "€90.99")
    #expect(result.answerLabel == "Euros")
    #expect(result.copyText == "90.99")
    #expect(result.enter == .copy)
    let value = try #require(CurrencyConversion.convert(.init(amount: 100, from: "USD", to: "EUR"), rates: rates()))
    #expect(value == 100 / 1.0990)
}

@Test func crossRatesGoThroughTheEuro() throws {
    let value = try #require(CurrencyConversion.convert(.init(amount: 100, from: "USD", to: "DKK"), rates: rates()))
    #expect(Swift.abs(value - 100 / 1.0990 * 7.4746) < 1e-9)
    let result = try #require(calculate("100 usd to dkk", enUS, ready))
    #expect(result.copyText == "680.13")
    #expect(result.answerLabel == "Danish Kroner")
}

@Test func theYenHasNoDecimals() throws {
    let result = try #require(calculate("100 usd in jpy", enUS, ready))
    #expect(result.answer == "¥15,864")
    #expect(result.copyText == "15864")
    #expect(result.answerLabel == "Japanese Yen")
}

@Test(arguments: [
    // Danish puts a no-break space before the symbol.
    (enUS, "€90.99", "90.99"), (daDK, "90,99\u{A0}€", "90,99"), (enDK, "90,99\u{A0}€", "90,99"),
])
func answersFollowTheLocale(_ locale: Locale, _ answer: String, _ copy: String) throws {
    let result = try #require(calculate("100 usd to eur", locale, CurrencyState(enabled: true, rates: rates())))
    #expect(result.answer == answer)
    #expect(result.copyText == copy, "no symbol, no grouping, the locale's decimal separator")
}

@Test func groupingInTheAnswerButNotTheCopy() throws {
    let result = try #require(calculate("10000 eur to usd", enUS, ready))
    #expect(result.answer == "$10,990.00")
    #expect(result.copyText == "10990.00")
}

@Test(arguments: [
    ("100 usd to eur", enUS, "USD", "EUR"), ("100usd in dkk", enUS, "USD", "DKK"), ("€100 to usd", enUS, "EUR", "USD"),
    ("100 € in kr", daDK, "EUR", "DKK"), ("100 € in kr", svSE, "EUR", "SEK"), ("100 € in kr", enUS, "EUR", "DKK"),
    ("$5 = eur", enUS, "USD", "EUR"), ("£5 to €", enUS, "GBP", "EUR"), ("¥500 in usd", enUS, "JPY", "USD"),
    ("100 USD TO EUR", enUS, "USD", "EUR"), ("1,5 eur in usd", daDK, "EUR", "USD"),
])
func readsCodesSymbolsAndKr(_ query: String, _ locale: Locale, _ from: String, _ to: String) throws {
    let parsed = try #require(CurrencyConversion.parse(query, locale: locale))
    #expect(parsed.from == from)
    #expect(parsed.to == to)
}

@Test func amountsAreReadInTheLocale() throws {
    #expect(CurrencyConversion.parse("1,5 eur in usd", locale: daDK)?.amount == 1.5)
    #expect(CurrencyConversion.parse("1,500 eur in usd", locale: enUS)?.amount == 1500)
}

@Test func amountsAndAnswersFollowTheNumberFormat() throws {
    func card(_ query: String, _ format: NumberFormat) -> CalculatorResult? {
        Calculator.evaluate(query, locale: enUS, format: format, now: now, timeZone: copenhagen, currency: ready)
    }
    let dot = try #require(card("1,000 usd in eur", .dotDecimal))
    #expect(dot.answer == "€909.92")
    #expect(dot.copyText == "909.92")
    let comma = try #require(card("1.000 usd in eur", .commaDecimal))
    #expect(comma.answer == "€909,92", "the locale places the symbol, the format writes the number")
    #expect(comma.copyText == "909,92")
    #expect(try #require(card("10.000 eur in usd", .commaDecimal)).answer == "$10.990,00")
    #expect(try #require(card("1,5 usd in eur", .dotDecimal)).copyText == "13.65", "`1,5` is 15 with 1,234.5")
    #expect(try #require(card("1.5 usd in eur", .commaDecimal)).copyText == "13,65", "`1.5` is 15 with 1.234,5")
    #expect(try #require(card("1'000 chf in eur", .system(Locale(identifier: "de_CH")))).kind == .currency)
    #expect(CurrencyConversion.parse("1'000 chf in eur", locale: Locale(identifier: "de_CH"))?.amount == 1000)
}

@Test func amountsCanHaveAnExponent() throws {
    #expect(CurrencyConversion.parse("2.5e3 usd in eur", locale: enUS)?.amount == 2500)
    #expect(CurrencyConversion.parse("2,5E3 usd in eur", locale: enDK)?.amount == 2500)
    #expect(CurrencyConversion.parse("$1e-2 to eur", locale: enUS)?.amount == 0.01)
    #expect(try #require(calculate("2.5e3 usd in eur", enUS, ready)).answer == "€2,274.80")
    #expect(try #require(calculate("2,5e3 usd in eur", enDK, ready)).answer == "2.274,80\u{A0}€")
    #expect(CurrencyConversion.parse("2.5e3 usd in eur", locale: enDK)?.amount == 25_000, "`.` groups in en_DK")
}

@Test(arguments: [
    "100 xyz to eur", "usd to eur", "100 usd", "100 usd to", "100 usd eur to", "€ to usd", "100 € $ to eur",
])
func notACurrencyQuery(_ query: String) {
    #expect(CurrencyConversion.parse(query, locale: enUS) == nil)
    #expect(calculate(query, enUS, .off)?.kind != .currency)
}

// MARK: - Cards that can't convert

@Test func offRecognisesTheQueryAndOffersTheSetting() throws {
    let result = try #require(calculate("100 usd to eur", enUS, .off))
    #expect(result.kind == .currency)
    #expect(result.questionLabel == "US Dollars")
    #expect(result.answer == "Currency conversion is off")
    #expect(result.answerLabel == "Press ↵ to turn it on")
    #expect(result.enter == .turnOnCurrencyConversion)
    #expect(calculate("100 xyz to eur", enUS, .off) == nil, "an unknown code gets no card")
}

@Test func downloadingAndFailedCards() throws {
    let downloading = try #require(calculate("100 usd to eur", enUS, CurrencyState(enabled: true, downloading: true)))
    #expect(downloading.answer == "Downloading exchange rates…")
    #expect(downloading.enter == .nothing)
    let notYet = try #require(calculate("100 usd to eur", enUS, CurrencyState(enabled: true)))
    #expect(notYet.answer == "Downloading exchange rates…", "turned on, the first download about to start")
    let failed = try #require(
        calculate("100 usd to eur", enUS, CurrencyState(enabled: true, failure: "The ECB answered 503")))
    #expect(failed.answer == "Couldn't download exchange rates")
    #expect(failed.answerLabel == "The ECB answered 503")
    #expect(failed.enter == .retryExchangeRates)
}

@Test func aFailedUpdateKeepsConvertingWithTheOldRates() throws {
    let result = try #require(
        calculate("100 usd to eur", enUS, CurrencyState(enabled: true, rates: rates(), failure: "offline")))
    #expect(result.answer == "€90.99")
}

@Test func aCurrencyTheRatesLack() throws {
    var partial = rates()
    partial.rates["USD"] = nil
    let result = try #require(calculate("100 usd to eur", enUS, CurrencyState(enabled: true, rates: partial)))
    #expect(result.answer == "No rate for USD in the ECB data")
    #expect(result.enter == .nothing)
}

@Test func freshnessUnderTheArrow() throws {
    let result = try #require(calculate("100 usd to eur", enUS, ready))
    #expect(result.footnote == "Updated 3 hours ago")
    // The ECB's date more than 3 days back: say which day the rates are from.
    let stale = rates(fetchedAt: now).freshness(now: now.addingTimeInterval(4 * 24 * hour), locale: enUS)
    #expect(stale == "Rates from Nov 20, 2026")
}

@Test func theCardsActions() {
    #expect(
        RootActions.calculatorSections(for: .copy).flatMap(\.entries).map(\.title) == [
            "Copy Answer", "Copy Question and Answer",
        ])
    #expect(
        RootActions.calculatorSections(for: .turnOnCurrencyConversion).flatMap(\.entries).map(\.title) == [
            "Turn On Currency Conversion"
        ])
    #expect(
        RootActions.calculatorSections(for: .retryExchangeRates).flatMap(\.entries).map(\.title) == [
            "Download Exchange Rates"
        ])
    #expect(RootActions.calculatorSections(for: .nothing).isEmpty)
}

@Test func currencyComesBeforeUnitsAndArithmetic() throws {
    #expect(calculate("100 usd to eur", enUS, ready)?.kind == .currency)
    #expect(calculate("5 in to cm", enUS, ready)?.kind == .units, "units still work")
    #expect(calculate("13kg to lbs", enUS, ready)?.kind == .units)
    #expect(calculate("2+2", enUS, ready)?.kind == .arithmetic)
    #expect(calculate("3pm cet in pst", enUS, ready)?.kind == .timeZone)
}

// MARK: - When to download

@Test func whenToFetch() {
    let fresh = rates(fetchedAt: now.addingTimeInterval(-23 * hour))
    let old = rates(fetchedAt: now.addingTimeInterval(-25 * hour))
    #expect(!ExchangeRatePolicy.shouldFetch(enabled: false, cached: nil, lastAttempt: nil, now: now), "off: never")
    #expect(!ExchangeRatePolicy.shouldFetch(enabled: false, cached: old, lastAttempt: nil, now: now, explicit: true))
    #expect(ExchangeRatePolicy.shouldFetch(enabled: true, cached: nil, lastAttempt: nil, now: now), "no cache: now")
    #expect(!ExchangeRatePolicy.shouldFetch(enabled: true, cached: fresh, lastAttempt: nil, now: now), "23 h: no")
    #expect(ExchangeRatePolicy.shouldFetch(enabled: true, cached: old, lastAttempt: nil, now: now), "25 h: yes")
    let failedEarlier = now.addingTimeInterval(-11 * hour)
    #expect(!ExchangeRatePolicy.shouldFetch(enabled: true, cached: nil, lastAttempt: failedEarlier, now: now))
    #expect(!ExchangeRatePolicy.shouldFetch(enabled: true, cached: old, lastAttempt: failedEarlier, now: now))
    #expect(
        ExchangeRatePolicy.shouldFetch(enabled: true, cached: nil, lastAttempt: failedEarlier, now: now, explicit: true)
    )
    #expect(
        ExchangeRatePolicy.shouldFetch(
            enabled: true, cached: nil, lastAttempt: now.addingTimeInterval(-13 * hour), now: now))
}

/// Answers each download with the next result, and counts the downloads.
private actor FakeFetcher: RatesFetcher {
    private var results: [Result<Data, any Error>]
    private(set) var calls = 0

    init(_ results: [Result<Data, any Error>]) {
        self.results = results
    }

    func fetchRates() async throws -> Data {
        calls += 1
        return try results.removeFirst().get()
    }
}

/// Holds its one download until `open()`.
private actor GatedFetcher: RatesFetcher {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    func fetchRates() async throws -> Data {
        calls += 1
        await withCheckedContinuation { gate = $0 }
        return fixture
    }

    func open() {
        gate?.resume()
        gate = nil
    }
}

private struct Offline: Error {}

@MainActor @Test func theUpdaterDownloadsCachesAndReportsChanges() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("exchange-rates.json")
    let fetcher = FakeFetcher([.success(fixture)])
    let updater = ExchangeRateUpdater(fetcher: fetcher, cacheFile: file, enabled: false)
    var changes = 0
    updater.onChange = { changes += 1 }

    await updater.updateIfNeeded(now: now)
    #expect(await fetcher.calls == 0, "nothing while it's off")
    await updater.setEnabled(true, now: now)
    #expect(await fetcher.calls == 1, "turning it on downloads")
    #expect(updater.state.rates?.date == "2026-11-20")
    #expect(updater.state.rates?.fetchedAt == now)
    #expect(ExchangeRates.load(from: file) == updater.state.rates)
    #expect(changes >= 2)
    await updater.updateIfNeeded(now: now.addingTimeInterval(hour))
    #expect(await fetcher.calls == 1, "fresh rates aren't downloaded again")

    await updater.setEnabled(false, now: now)
    #expect(ExchangeRates.load(from: file) != nil, "the cache is kept")
    #expect(
        Calculator.evaluate("1 usd to eur", locale: enUS, now: now, timeZone: copenhagen, currency: updater.state)?
            .answer == "Currency conversion is off")
}

@MainActor @Test func aBadDownloadKeepsTheCache() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("exchange-rates.json")
    let cached = rates(fetchedAt: now.addingTimeInterval(-30 * hour))
    try cached.save(to: file)
    let fetcher = FakeFetcher([.success(Data("<html>maintenance</html>".utf8))])
    let updater = ExchangeRateUpdater(fetcher: fetcher, cacheFile: file, enabled: true)
    await updater.updateIfNeeded(now: now)
    #expect(await fetcher.calls == 1)
    #expect(updater.state.rates == cached)
    #expect(updater.state.failure != nil)
    #expect(ExchangeRates.load(from: file) == cached)
}

@MainActor @Test func retryingSkipsTheTwelveHourLimit() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("exchange-rates.json")
    let fetcher = FakeFetcher([.failure(Offline()), .success(fixture)])
    let updater = ExchangeRateUpdater(fetcher: fetcher, cacheFile: file, enabled: true)
    await updater.updateIfNeeded(now: now)
    #expect(updater.state.failure != nil)
    #expect(
        Calculator.evaluate("1 usd to eur", locale: enUS, now: now, timeZone: copenhagen, currency: updater.state)?
            .enter == .retryExchangeRates)

    await updater.updateIfNeeded(now: now.addingTimeInterval(hour))
    #expect(await fetcher.calls == 1, "within 12 hours of a failure: no")
    await updater.updateIfNeeded(now: now.addingTimeInterval(hour), explicit: true)
    #expect(await fetcher.calls == 2, "↵ on the failed card: at once")
    #expect(updater.state.rates != nil)
    #expect(updater.state.failure == nil)
}

@MainActor @Test func oneDownloadAtATime() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("exchange-rates.json")
    let fetcher = GatedFetcher()
    let updater = ExchangeRateUpdater(fetcher: fetcher, cacheFile: file, enabled: true)
    let first = Task { await updater.updateIfNeeded(now: now) }
    while await fetcher.calls == 0 { await Task.yield() }
    #expect(updater.state.downloading)
    await updater.updateIfNeeded(now: now, explicit: true)
    #expect(await fetcher.calls == 1, "a second request while one runs does nothing")
    await fetcher.open()
    await first.value
    #expect(!updater.state.downloading)
    #expect(updater.state.rates != nil)
}

// MARK: - The setting

@Test func theSettingIsStoredAndKeepsOtherKeys() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(#"{"hotkey": "option+space", "theme": "dark"}"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).currencyRates == false, "off by default")
    var settings = FudgeSettings.load(from: file)
    settings.currencyRates = true
    try settings.save(to: file)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["currencyRates"] as? Bool == true)
    #expect(object["theme"] as? String == "dark")
    #expect(FudgeSettings.load(from: file).currencyRates)
    settings.currencyRates = false
    try settings.save(to: file)
    let off = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(off["currencyRates"] == nil, "off is the default, so it isn't written")
}
