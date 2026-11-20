import Foundation

/// The European Central Bank's euro reference rates, as fudge keeps them in `exchange-rates.json`.
public struct ExchangeRates: Sendable, Equatable, Codable {
    /// The ECB's reference date, `yyyy-MM-dd`.
    public var date: String
    /// When fudge downloaded them.
    public var fetchedAt: Date
    /// Units of each currency per euro.
    public var rates: [String: Double]

    public init(date: String, fetchedAt: Date, rates: [String: Double]) {
        self.date = date
        self.fetchedAt = fetchedAt
        self.rates = rates
    }

    /// Units of `code` per euro; the euro itself is 1.
    public func rate(_ code: String) -> Double? {
        code == "EUR" ? 1 : rates[code]
    }

    public enum ParseError: Error, Equatable {
        case notTheDailyFile
    }

    /// Reads `eurofxref-daily.xml`: one `Cube` with a `time`, holding a `Cube` per currency with its `rate`.
    /// Anything else, such as an error page, is rejected.
    public static func parseECB(_ data: Data, fetchedAt: Date) throws -> ExchangeRates {
        let reader = CubeReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let date = reader.date, date.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil,
            !reader.rates.isEmpty
        else { throw ParseError.notTheDailyFile }
        return ExchangeRates(date: date, fetchedAt: fetchedAt, rates: reader.rates)
    }

    /// The cached rates, or nil when there are none or the file can't be read.
    public static func load(from file: URL) -> ExchangeRates? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExchangeRates.self, from: data)
    }

    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// The reference date as a date at noon UTC, for comparing and showing.
    public var referenceDate: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH"
        return formatter.date(from: "\(date) 12")
    }

    /// The small line under the card's arrow: "Updated 3 hours ago", or "Rates from 14 Nov 2026" when the ECB's
    /// own date is more than 3 days old (its file stopped changing, or downloads keep failing).
    public func freshness(now: Date, locale: Locale) -> String {
        if let reference = referenceDate, now.timeIntervalSince(reference) > ExchangeRatePolicy.staleAfter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return "Rates from \(formatter.string(from: reference))"
        }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "en_US")
        relative.dateTimeStyle = .named
        return "Updated \(relative.localizedString(for: min(fetchedAt, now), relativeTo: now))"
    }
}

/// Collects the ECB file's `Cube` elements.
private final class CubeReader: NSObject, XMLParserDelegate {
    var date: String?
    var rates: [String: Double] = [:]

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard element == "Cube" else { return }
        if let time = attributes["time"] { date = time }
        if let currency = attributes["currency"], currency.wholeMatch(of: /[A-Z]{3}/) != nil,
            let text = attributes["rate"], let rate = Double(text), rate.isFinite, rate > 0
        {
            rates[currency] = rate
        }
    }
}

/// When fudge downloads the rates.
public enum ExchangeRatePolicy {
    /// Rates older than this are downloaded again.
    public static let maximumAge: TimeInterval = 24 * 3600
    /// No more than one download per this long, failed ones included, unless the user asks.
    public static let minimumInterval: TimeInterval = 12 * 3600
    /// Rates whose ECB date is older than this show that date.
    public static let staleAfter: TimeInterval = 3 * 24 * 3600

    /// Whether to download now. Never while the setting is off. `explicit` is the user asking (↵ on the failed
    /// card), which skips the 12-hour limit.
    public static func shouldFetch(
        enabled: Bool, cached: ExchangeRates?, lastAttempt: Date?, now: Date, explicit: Bool = false
    ) -> Bool {
        guard enabled else { return false }
        if explicit { return true }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        guard let cached else { return true }
        return now.timeIntervalSince(cached.fetchedAt) >= maximumAge
    }
}

/// Downloads the ECB's daily file. The app's fetcher uses its own `URLSession`; tests use a fake.
public protocol RatesFetcher: Sendable {
    func fetchRates() async throws -> Data
}

/// What the calculator knows about the rates.
public struct CurrencyState: Sendable, Equatable {
    /// The setting: download rates from the ECB.
    public var enabled: Bool
    public var rates: ExchangeRates?
    public var downloading: Bool
    /// Why the last download failed, if it did.
    public var failure: String?

    public init(enabled: Bool, rates: ExchangeRates? = nil, downloading: Bool = false, failure: String? = nil) {
        self.enabled = enabled
        self.rates = rates
        self.downloading = downloading
        self.failure = failure
    }

    public static let off = CurrencyState(enabled: false)
}

/// Keeps the rates current: loads the cache, downloads when `ExchangeRatePolicy` says so, one download at a time,
/// and keeps the previous rates when a download fails.
@MainActor
public final class ExchangeRateUpdater {
    public private(set) var state: CurrencyState
    /// Called whenever `state` changes.
    public var onChange: () -> Void = {}

    private let fetcher: any RatesFetcher
    private let cacheFile: URL
    private var lastAttempt: Date?

    public init(fetcher: any RatesFetcher, cacheFile: URL, enabled: Bool) {
        self.fetcher = fetcher
        self.cacheFile = cacheFile
        state = CurrencyState(enabled: enabled, rates: ExchangeRates.load(from: cacheFile))
    }

    /// Turns downloading on or off. The cached rates are kept either way, and used only while it's on.
    public func setEnabled(_ enabled: Bool, now: Date) async {
        guard enabled != state.enabled else { return }
        state.enabled = enabled
        if !enabled { state.failure = nil }
        onChange()
        await updateIfNeeded(now: now)
    }

    /// Downloads when the rules say so, or at once when `explicit`. Does nothing while a download runs.
    public func updateIfNeeded(now: Date, explicit: Bool = false) async {
        guard !state.downloading,
            ExchangeRatePolicy.shouldFetch(
                enabled: state.enabled, cached: state.rates, lastAttempt: lastAttempt, now: now, explicit: explicit)
        else { return }
        lastAttempt = now
        state.downloading = true
        state.failure = nil
        onChange()
        do {
            let rates = try ExchangeRates.parseECB(try await fetcher.fetchRates(), fetchedAt: now)
            try? rates.save(to: cacheFile)
            state.rates = rates
        } catch ExchangeRates.ParseError.notTheDailyFile {
            state.failure = "The ECB sent something else"
        } catch {
            state.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        state.downloading = false
        onChange()
    }
}
