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

    /// The grouping separator a typed number may contain: `.` or `,`. Any other (a space, `’`) is only shown: a space
    /// already separates tokens (`2 pi`), and nobody types `’`.
    public var typedGrouping: Character? {
        guard grouping.count == 1, let separator = grouping.first, separator == "." || separator == ",",
            separator != decimal
        else { return nil }
        return separator
    }

    /// A number as typed: digits with this format's separators, an optional leading `-`, and an optional exponent
    /// (`1,5E3`). Nil when it isn't one in this format, never another reading:
    /// - the decimal separator starts the fraction, and there's at most one (`,5` is 0.5 with "1.234,5");
    /// - the grouping separator is allowed only in the integer part, in proper groups: 1–3 digits, then groups of
    ///   exactly 3 (`1.000`, `12.345.678,9`), and it's dropped when reading;
    /// - anything else is no number: `1.5`, `3.14`, `1.00`, `1.000.00` and `.5` with "1.234,5", `1,5` with "1,234.5".
    public func number(_ literal: String) -> Double? {
        var text = Substring(literal)
        let negative = text.first == "-"
        if negative { text = text.dropFirst() }
        let exponentStart = text.firstIndex { $0 == "e" || $0 == "E" } ?? text.endIndex
        let exponent = text[exponentStart...]
        let parts = text[..<exponentStart].split(separator: decimal, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard let integer = digits(ofInteger: parts[0]), fraction.allSatisfy(Self.isDigit),
            !(integer.isEmpty && fraction.isEmpty)
        else { return nil }
        let normalized = (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Double(normalized + exponent) else { return nil }
        return negative ? -value : value
    }

    /// The integer part's digits, without its grouping, or nil when it isn't grouped properly.
    private func digits(ofInteger integer: Substring) -> String? {
        if integer.allSatisfy(Self.isDigit) { return String(integer) }
        guard let grouping = typedGrouping else { return nil }
        let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
        guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }),
            groups.allSatisfy({ $0.allSatisfy(Self.isDigit) })
        else { return nil }
        return groups.joined()
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
