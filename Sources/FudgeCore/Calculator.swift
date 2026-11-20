import Foundation

/// What root search's Calculator card shows: the question and the answer, each with a label under it, and what ↵
/// copies.
public struct CalculatorResult: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case arithmetic, units, timeZone, currency
    }

    /// What ↵ does on the card.
    public enum Enter: Sendable, Equatable {
        /// Copies the answer: every card that has one.
        case copy
        /// Opens Settings on the General page, where currency conversion is turned on.
        case turnOnCurrencyConversion
        /// Downloads the exchange rates again at once.
        case retryExchangeRates
        /// Nothing to do yet (the rates are downloading, or the ECB has no rate for the currency).
        case nothing
    }

    public var kind: Kind
    /// The query as typed.
    public var question: String
    public var questionLabel: String
    public var answer: String
    public var answerLabel: String
    /// What Copy Answer puts on the clipboard: the answer without grouping separators, and with up to 15
    /// significant digits rather than the card's.
    public var copyText: String
    /// Small text under the arrow: how fresh a currency conversion's rates are.
    public var footnote: String? = nil
    public var enter: Enter = .copy

    /// What Copy Question and Answer puts on the clipboard.
    public var questionAndAnswer: String { "\(question) = \(answer)" }
}

/// Root search's calculator: a time zone conversion, a currency conversion, a unit conversion or arithmetic, read
/// and written in the user's locale.
public enum Calculator {
    /// Longer queries aren't evaluated.
    public static let maximumLength = 200

    /// `currency` is what fudge knows about exchange rates; a currency query gets a card even without them, saying
    /// why it can't answer. Numbers are read and shown in `format`, by default `locale`'s (`NumberFormat.system`);
    /// `locale` still names times, dates, currencies and the spelled-out answer.
    public static func evaluate(
        _ query: String, locale: Locale, format: NumberFormat? = nil, now: Date, timeZone: TimeZone,
        currency: CurrencyState = .off
    ) -> CalculatorResult? {
        guard query.count <= maximumLength, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let format = format ?? .system(locale)
        if let conversion = TimeZoneConversion.evaluate(query, now: now, timeZone: timeZone) {
            return timeZoneResult(query, conversion, locale: locale)
        }
        if let conversion = CurrencyConversion.parse(query, locale: locale, format: format) {
            return currencyResult(query, conversion, currency: currency, locale: locale, format: format, now: now)
        }
        if let conversion = UnitConversion.evaluate(query, format: format), conversion.value.isFinite {
            let number = self.format(conversion.value, locale: locale, format: format, for: .card)
            let plain = self.format(conversion.value, locale: locale, format: format, for: .copy)
            return CalculatorResult(
                kind: .units, question: query, questionLabel: conversion.from.name,
                answer: "\(number) \(conversion.to.symbol)", answerLabel: conversion.to.name,
                copyText: "\(plain) \(conversion.to.symbol)")
        }
        if let value = Arithmetic.evaluate(query, format: format) {
            // Spelled out only while the answer is written out: past 1e15 the words would name another number.
            let label = Swift.abs(value) < 1e15 ? spelledOut(value) : "Result"
            return CalculatorResult(
                kind: .arithmetic, question: query, questionLabel: "Expression",
                answer: self.format(value, locale: locale, format: format, for: .card), answerLabel: label,
                copyText: self.format(value, locale: locale, format: format, for: .copy))
        }
        return nil
    }

    private static func currencyResult(
        _ query: String, _ conversion: CurrencyConversion.Query, currency: CurrencyState, locale: Locale,
        format: NumberFormat, now: Date
    ) -> CalculatorResult {
        let from = CurrencyConversion.pluralName(conversion.from)
        let to = CurrencyConversion.pluralName(conversion.to)
        func card(_ answer: String, _ label: String, enter: CalculatorResult.Enter) -> CalculatorResult {
            CalculatorResult(
                kind: .currency, question: query, questionLabel: from, answer: answer, answerLabel: label,
                copyText: "", enter: enter)
        }
        guard currency.enabled else {
            return card("Currency conversion is off", "Press ↵ to turn it on", enter: .turnOnCurrencyConversion)
        }
        guard let rates = currency.rates else {
            if let failure = currency.failure, !currency.downloading {
                return card("Couldn't download exchange rates", failure, enter: .retryExchangeRates)
            }
            return card("Downloading exchange rates…", to, enter: .nothing)
        }
        guard let value = CurrencyConversion.convert(conversion, rates: rates), value.isFinite else {
            let lacking = rates.rate(conversion.from) == nil ? conversion.from : conversion.to
            return card("No rate for \(lacking) in the ECB data", to, enter: .nothing)
        }
        return CalculatorResult(
            kind: .currency, question: query, questionLabel: from,
            answer: CurrencyConversion.format(value, code: conversion.to, locale: locale, format: format),
            answerLabel: to,
            copyText: CurrencyConversion.copyText(value, code: conversion.to, locale: locale, format: format),
            footnote: rates.freshness(now: now, locale: locale))
    }

    private static func timeZoneResult(_ query: String, _ conversion: TimeZoneConversion.Result, locale: Locale)
        -> CalculatorResult
    {
        let time = DateFormatter()
        time.locale = locale
        time.dateStyle = .none
        time.timeStyle = .short
        time.timeZone = conversion.source.zone
        let full = DateFormatter()
        full.locale = locale
        full.dateStyle = .long
        full.timeStyle = .short
        full.timeZone = conversion.target.zone
        let answer = full.string(from: conversion.date)
        // A place typed as an abbreviation shows the one in force on that date: `pst` in July is PDT.
        func name(_ place: TimeZoneConversion.Place) -> String {
            place.isAbbreviation ? TimeZoneConversion.abbreviation(of: place.zone, at: conversion.date) : place.name
        }
        let source = name(conversion.source)
        let questionLabel =
            conversion.isNow ? "now, \(source)" : "\(time.string(from: conversion.date)), \(source)"
        let target = conversion.target
        let answerLabel =
            target.isAbbreviation
            ? name(target)
            : "\(target.name), \(TimeZoneConversion.abbreviation(of: target.zone, at: conversion.date))"
        return CalculatorResult(
            kind: .timeZone, question: query, questionLabel: questionLabel, answer: answer, answerLabel: answerLabel,
            copyText: answer)
    }

    /// Where a formatted answer goes.
    public enum Use: Sendable {
        /// Shown on the card: grouped, with `cardDigits(for:)` significant digits.
        case card
        /// Put on the clipboard: no grouping, up to `copyDigits` significant digits.
        case copy
    }

    /// A copied answer's significant digits: as many as a `Double` reliably holds, few enough that floating-point
    /// noise (`0.1+0.2`) rounds away.
    public static let copyDigits = 15

    /// The card's significant digits for `value`: while it's written out (below 1e15), at least 10 and more for a
    /// longer integer part, up to 15, so rounding happens in the fraction and never in the integer part. In
    /// scientific notation, 10.
    public static func cardDigits(for value: Double) -> Int {
        let magnitude = Swift.abs(value)
        // Also NaN and infinity, which fail the comparison.
        guard magnitude < 1e15 else { return 10 }
        let integerDigits = magnitude < 1 ? 0 : String(UInt64(magnitude)).count
        return min(copyDigits, max(10, integerDigits))
    }

    /// A number in `locale` with `format`'s separators (by default the locale's), as the card shows it or as it's
    /// copied (`Use`). Absolute values from 1e-6 up to 1e15 are written out; others in scientific notation. A last
    /// digit of 5 rounds up.
    public static func format(_ value: Double, locale: Locale, format: NumberFormat? = nil, for use: Use) -> String {
        let format = format ?? .system(locale)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.decimalSeparator = String(format.decimal)
        formatter.groupingSeparator = format.grouping
        let magnitude = Swift.abs(value)
        formatter.numberStyle = value != 0 && (magnitude < 1e-6 || magnitude >= 1e15) ? .scientific : .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = use == .card ? cardDigits(for: value) : copyDigits
        formatter.roundingMode = .halfUp
        formatter.usesGroupingSeparator = use == .card && formatter.numberStyle == .decimal && !format.grouping.isEmpty
        return formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) ?? String(value)
    }

    /// The value in English words, in title case: 24.5 is "Twenty-Four Point Five".
    public static func spelledOut(_ value: Double) -> String {
        // Spell the number as the card shows it, rounded to its significant digits.
        let posix = Locale(identifier: "en_US_POSIX")
        let shown = Double(format(value, locale: posix, for: .card).replacingOccurrences(of: ",", with: "")) ?? value
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: shown)) ?? ""
        var result = ""
        var capitalizeNext = true
        for character in words {
            result.append(capitalizeNext ? Character(character.uppercased()) : character)
            capitalizeNext = character == " " || character == "-"
        }
        return result
    }
}
