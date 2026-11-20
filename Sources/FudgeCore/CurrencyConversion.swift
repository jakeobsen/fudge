import Foundation

/// Currency conversions written the way people type them: `100 usd to eur`, `100usd in dkk`, `€100 to usd`,
/// `100 € in kr`. Rates come from the European Central Bank (`ExchangeRates`), so the currencies are the ECB's.
public enum CurrencyConversion {
    /// The ECB's reference currencies and the euro. A query naming two of these is a currency conversion even
    /// before any rates are downloaded, so the calculator can say why it can't answer yet.
    public static let codes: Set<String> = [
        "EUR", "USD", "JPY", "CZK", "DKK", "GBP", "HUF", "PLN", "RON", "SEK", "CHF", "ISK", "NOK", "TRY", "AUD",
        "BRL", "CAD", "CNY", "HKD", "IDR", "ILS", "INR", "KRW", "MXN", "MYR", "NZD", "PHP", "SGD", "THB", "ZAR",
    ]

    static let symbols: [String: String] = ["€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY"]

    /// What a query asks for.
    public struct Query: Sendable, Equatable {
        public var amount: Double
        public var from: String
        public var to: String
    }

    // Lookarounds, so the spaces around a separator belong to both sides.
    nonisolated(unsafe) private static let separator = try! NSRegularExpression(
        pattern: #"(?<=\s)(?:to|in|=)(?=\s)"#)
    nonisolated(unsafe) private static let quantityPattern = try! NSRegularExpression(
        pattern: #"^([^\d\s.,-]*)\s*(-?[\d.,]*\d(?:[eE][+-]?\d+)?)\s*([^\d\s.,-]*)$"#)

    /// The conversion `text` asks for, or nil. The amount is read like the calculator's numbers, in `format` (by
    /// default the locale's); `locale` says which krone or krona `kr` is.
    public static func parse(_ text: String, locale: Locale, format: NumberFormat? = nil) -> Query? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        let format = format ?? .system(locale)
        let range = NSRange(lowered.startIndex..., in: lowered)
        for match in separator.matches(in: lowered, range: range) {
            guard let split = Range(match.range, in: lowered),
                let (amount, from) = quantity(
                    lowered[..<split.lowerBound].trimmingCharacters(in: .whitespaces), locale: locale, format: format),
                let to = currency(lowered[split.upperBound...].trimmingCharacters(in: .whitespaces), locale: locale)
            else { continue }
            return Query(amount: amount, from: from, to: to)
        }
        return nil
    }

    /// `100 usd`, `100usd`, `€100`, `100 €`: a number with one currency before or after it.
    private static func quantity(_ text: String, locale: Locale, format: NumberFormat) -> (Double, String)? {
        guard let match = quantityPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let before = Range(match.range(at: 1), in: text), let number = Range(match.range(at: 2), in: text),
            let after = Range(match.range(at: 3), in: text),
            let amount = Arithmetic.number(String(text[number]), format: format), amount.isFinite
        else { return nil }
        let prefix = String(text[before])
        let suffix = String(text[after])
        // Exactly one of them names the currency.
        switch (prefix.isEmpty, suffix.isEmpty) {
        case (true, false): return currency(suffix, locale: locale).map { (amount, $0) }
        case (false, true): return currency(prefix, locale: locale).map { (amount, $0) }
        default: return nil
        }
    }

    /// The code `text` names: an ECB code in any case, a symbol, or `kr`.
    static func currency(_ text: String, locale: Locale) -> String? {
        if let code = symbols[text] { return code }
        if text == "kr" {
            // The locale's krone or krona, else the Danish krone.
            let own = locale.currency?.identifier ?? ""
            return ["DKK", "SEK", "NOK"].contains(own) ? own : "DKK"
        }
        let code = text.uppercased()
        return codes.contains(code) ? code : nil
    }

    /// `amount` of `from` in `to`, through the euro. Nil when the rates lack either currency.
    public static func convert(_ query: Query, rates: ExchangeRates) -> Double? {
        guard let from = rates.rate(query.from), let to = rates.rate(query.to), from > 0 else { return nil }
        return query.amount / from * to
    }

    /// The currency's name in plural English, title-cased: "US Dollars", "Euros", "Japanese Yen".
    public static func pluralName(_ code: String) -> String {
        let formatter = NumberFormatter()
        // The currency goes in the locale: `currencyCode` doesn't reach the plural style's name.
        formatter.locale = Locale(identifier: "en_US@currency=\(code)")
        formatter.numberStyle = .currencyPlural
        guard let text = formatter.string(from: 2), let space = text.firstIndex(of: " ") else { return code }
        return text[text.index(after: space)...].split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The digits after the decimal point that `code` is written with: 2, or 0 for the yen and others like it.
    public static func fractionDigits(_ code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.maximumFractionDigits
    }

    /// `value` as an amount of `code` in `locale`'s currency format, with `format`'s separators (by default the
    /// locale's): `€91.04` in en_US, `91,04 €` in da_DK.
    public static func format(_ value: Double, code: String, locale: Locale, format: NumberFormat? = nil) -> String {
        let format = format ?? .system(locale)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.currencyDecimalSeparator = String(format.decimal)
        formatter.currencyGroupingSeparator = format.grouping
        formatter.usesGroupingSeparator = !format.grouping.isEmpty
        let digits = fractionDigits(code)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// What ↵ copies: the number with the currency's digits and `format`'s decimal separator (by default the
    /// locale's), without a symbol or grouping.
    public static func copyText(_ value: Double, code: String, locale: Locale, format: NumberFormat? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.decimalSeparator = String((format ?? .system(locale)).decimal)
        formatter.usesGroupingSeparator = false
        let digits = fractionDigits(code)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
