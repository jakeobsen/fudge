import Foundation

/// What root search's Calculator card shows: the question and the answer, each with a label under it, and what ↵
/// copies.
public struct CalculatorResult: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case arithmetic, units, timeZone
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

    /// What Copy Question and Answer puts on the clipboard.
    public var questionAndAnswer: String { "\(question) = \(answer)" }
}

/// Root search's calculator: a time zone conversion, a unit conversion or arithmetic, read and written in the
/// user's locale.
public enum Calculator {
    /// Longer queries aren't evaluated.
    public static let maximumLength = 200

    public static func evaluate(_ query: String, locale: Locale, now: Date, timeZone: TimeZone) -> CalculatorResult? {
        guard query.count <= maximumLength, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let commaIsDecimal = locale.decimalSeparator == ","
        if let conversion = TimeZoneConversion.evaluate(query, now: now, timeZone: timeZone) {
            return timeZoneResult(query, conversion, locale: locale)
        }
        if let conversion = UnitConversion.evaluate(query, commaIsDecimal: commaIsDecimal), conversion.value.isFinite {
            let number = format(conversion.value, locale: locale, for: .card)
            let plain = format(conversion.value, locale: locale, for: .copy)
            return CalculatorResult(
                kind: .units, question: query, questionLabel: conversion.from.name,
                answer: "\(number) \(conversion.to.symbol)", answerLabel: conversion.to.name,
                copyText: "\(plain) \(conversion.to.symbol)")
        }
        if let value = Arithmetic.evaluate(query, commaIsDecimal: commaIsDecimal) {
            // Spelled out only while the answer is written out: past 1e15 the words would name another number.
            let label = Swift.abs(value) < 1e15 ? spelledOut(value) : "Result"
            return CalculatorResult(
                kind: .arithmetic, question: query, questionLabel: "Expression",
                answer: format(value, locale: locale, for: .card), answerLabel: label,
                copyText: format(value, locale: locale, for: .copy))
        }
        return nil
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

    /// The card's significant digits for `value`: at least 10, and more for a longer integer part, up to 15, so
    /// rounding happens in the fraction and never in the integer part below 1e15.
    public static func cardDigits(for value: Double) -> Int {
        let magnitude = Swift.abs(value)
        // Also NaN and infinity, which fail the comparison.
        guard magnitude < 1e15 else { return copyDigits }
        let integerDigits = magnitude < 1 ? 0 : String(UInt64(magnitude)).count
        return min(copyDigits, max(10, integerDigits))
    }

    /// A number in `locale`, as the card shows it or as it's copied (`Use`). Absolute values from 1e-6 up to 1e15
    /// are written out; others in the locale's scientific notation. A last digit of 5 rounds up.
    public static func format(_ value: Double, locale: Locale, for use: Use) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        let magnitude = Swift.abs(value)
        formatter.numberStyle = value != 0 && (magnitude < 1e-6 || magnitude >= 1e15) ? .scientific : .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = use == .card ? cardDigits(for: value) : copyDigits
        formatter.roundingMode = .halfUp
        formatter.usesGroupingSeparator = use == .card && formatter.numberStyle == .decimal
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
