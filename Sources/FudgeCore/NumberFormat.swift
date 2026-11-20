import Foundation

/// How the calculator reads and writes numbers: a decimal separator and a grouping separator.
public struct NumberFormat: Sendable, Equatable {
    /// `.` or `,`.
    public var decimal: Character
    /// What answers group thousands with: `,` or `.`, or a locale's own (a space, a no-break space, de_CH's `’`).
    /// Empty for none.
    public var grouping: String

    public init(decimal: Character, grouping: String) {
        self.decimal = decimal
        self.grouping = grouping
    }

    /// "1,234.5".
    public static let dotDecimal = NumberFormat(decimal: ".", grouping: ",")
    /// "1.234,5".
    public static let commaDecimal = NumberFormat(decimal: ",", grouping: ".")

    /// The Mac's format: `locale`'s separators. A decimal separator other than `.` or `,` gives "1,234.5".
    public static func system(_ locale: Locale) -> NumberFormat {
        guard let decimal = locale.decimalSeparator, decimal == "." || decimal == "," else { return .dotDecimal }
        let grouping = locale.groupingSeparator ?? ""
        return NumberFormat(decimal: Character(decimal), grouping: grouping == decimal ? "" : grouping)
    }

    /// The characters a typed number may group with, which reading drops: the format's grouping separator, with
    /// `'` and `’` counted as one (de_CH writes `'`, a typed one may come out curly). None for a space grouping (fr_FR's
    /// U+202F): a space separates tokens (`2 pi`).
    public var typedGrouping: Set<Character> {
        guard grouping.count == 1, let separator = grouping.first, separator != decimal,
            !separator.isWhitespace
        else { return [] }
        return Self.apostrophes.contains(separator) ? Self.apostrophes : [separator]
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    /// Every grouping character a typed number can contain in some format, so the tokenizer and the conversions'
    /// patterns keep it inside the number and `number(_:)` decides.
    public static let groupingCharacters: Set<Character> = [".", ",", "'", "\u{2019}"]

    /// A number as typed: digits with this format's separators, an optional leading `-`, and an optional exponent
    /// (`1,5E3`). Nil when it isn't one in this format:
    /// - the decimal separator starts the fraction, and there's at most one (`,5` is 0.5 with "1.234,5");
    /// - the grouping separator (`typedGrouping`) is dropped wherever it stands between two digits, with no group
    ///   sizes checked: `0.1234` is 1234 and `1.5` is 15 with "1.234,5", `1,5` is 15 with "1,234.5";
    /// - a grouping separator that isn't between two digits (`.5`, `5.`, `1..2` with "1.234,5"), or any other
    ///   character, means it's no number.
    public func number(_ literal: String) -> Double? {
        var text = Substring(literal)
        let negative = text.first == "-"
        if negative { text = text.dropFirst() }
        let exponentStart = text.firstIndex { $0 == "e" || $0 == "E" } ?? text.endIndex
        let exponent = text[exponentStart...]
        let parts = text[..<exponentStart].split(separator: decimal, omittingEmptySubsequences: false)
        guard parts.count <= 2, let integer = digits(parts[0]),
            let fraction = parts.count == 2 ? digits(parts[1]) : "", !(integer.isEmpty && fraction.isEmpty)
        else { return nil }
        let normalized = (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Double(normalized + exponent) else { return nil }
        return negative ? -value : value
    }

    /// `part`'s digits, with each grouping separator that stands between two digits dropped; nil for anything else.
    private func digits(_ part: Substring) -> String? {
        let characters = Array(part)
        var result = ""
        for (index, character) in characters.enumerated() {
            if Self.isDigit(character) {
                result.append(character)
            } else if typedGrouping.contains(character), index > 0, index + 1 < characters.count,
                Self.isDigit(characters[index - 1]), Self.isDigit(characters[index + 1])
            {
                continue
            } else {
                return nil
            }
        }
        return result
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

/// The calculator's number format setting (`numberFormat` in `settings.json`).
public enum NumberFormatSetting: String, Sendable, CaseIterable {
    /// The Mac's format, read each time a query is evaluated, so a change in System Settings applies at once.
    case system
    /// "1,234.5".
    case dotDecimal = "dot-decimal"
    /// "1.234,5".
    case commaDecimal = "comma-decimal"

    public func resolve(_ locale: Locale) -> NumberFormat {
        switch self {
        case .system: .system(locale)
        case .dotDecimal: .dotDecimal
        case .commaDecimal: .commaDecimal
        }
    }
}
