import Foundation

/// Evaluates arithmetic typed into root search: `+ - * / ^`, `×` and `÷`, parentheses, `%` (`15% of 200`,
/// `200 + 10%`), `!`, functions (`sqrt`, `sin`, `log`, …; trig in radians, `log` base 10, `ln` natural) and the
/// constants `pi`, `e` and `tau`. A number written next to a parenthesis or a name multiplies (`2pi`, `3(4+5)`).
/// A sign binds looser than `^`, which is right-associative: `-2^2` is -4 and `2^3^2` is 512. Numbers are read by
/// `number(_:format:)`.
public enum Arithmetic {
    /// The value of `text`, or nil when it isn't a calculation: not arithmetic, a lone number, constants alone
    /// (`e`, `pi pi`), or a date (`2026-11-20`).
    public static func evaluate(_ text: String, format: NumberFormat = .dotDecimal) -> Double? {
        guard !isDate(text) else { return nil }
        // One token is a number or a name (`42`, `e`), not a calculation; nor is a signed number (`-5`).
        guard let tokens = tokenize(text, format: format), tokens.count > 1,
            tokens.contains(where: \.isOperation)
        else { return nil }
        if tokens.count == 2, tokens[0] == .symbol("-") || tokens[0] == .symbol("+"), case .number = tokens[1] {
            return nil
        }
        // Constants side by side (`e e`) multiply, but nobody types them to calculate, any more than a lone `e`.
        if tokens.allSatisfy(\.isConstant) { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.isAtEnd, value.number.isFinite else { return nil }
        return value.isPercent ? value.number / 100 : value.number
    }

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)

        /// Whether the token makes the text a calculation rather than a number.
        var isOperation: Bool {
            switch self {
            case .number: false
            case .name(let name): name != "of"
            case .symbol(let symbol): symbol != "(" && symbol != ")"
            }
        }

        var isConstant: Bool {
            if case .name(let name) = self { Arithmetic.constants[name] != nil } else { false }
        }
    }

    /// Whether `text` is exactly an ISO date, `YYYY-MM-DD` with a month from 01 to 12 and a day from 01 to 31.
    static func isDate(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return isoDate.firstMatch(in: text, range: range) != nil
    }

    nonisolated(unsafe) private static let isoDate = try! NSRegularExpression(
        pattern: #"^\s*[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])\s*$"#)

    /// A number as typed in `format` (`NumberFormat.number`), with an optional exponent (`2.5E3`, `1e-7`).
    public static func number(_ literal: String, format: NumberFormat) -> Double? {
        format.number(literal)
    }

    static func tokenize(_ text: String, format: NumberFormat = .dotDecimal) -> [Token]? {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
            } else if character.isNumber || ((character == "." || character == ",") && nextIsDigit(text, index)) {
                var end = index
                while end < text.endIndex, text[end].isNumber || text[end] == "." || text[end] == "," {
                    end = text.index(after: end)
                }
                end = exponentEnd(text, from: end)
                guard let number = number(String(text[index..<end]), format: format) else {
                    return nil
                }
                tokens.append(.number(number))
                index = end
            } else if character.isLetter || character == "π" {
                var end = index
                while end < text.endIndex, text[end].isLetter || text[end] == "π" { end = text.index(after: end) }
                tokens.append(.name(text[index..<end].lowercased()))
                index = end
            } else if "+-*/^%()!×÷−".contains(character) {
                let normalized: Character =
                    switch character {
                    case "×": "*"
                    case "÷": "/"
                    case "−": "-"
                    default: character
                    }
                tokens.append(.symbol(normalized))
                index = text.index(after: index)
            } else {
                return nil
            }
        }
        return tokens
    }

    /// Where a number's exponent ends, if one starts at `index`: `e` or `E`, an optional `+` or `-`, and at least one
    /// digit, with no spaces anywhere (`1e-7`, `2.5E3`, `2e+1`). Otherwise `index` itself, and the `e` is read as
    /// the constant: `2e` is 2 × e, `2e + 1` is 2 × e + 1, and in `1e3e` the second `e` is.
    private static func exponentEnd(_ text: String, from index: String.Index) -> String.Index {
        guard index < text.endIndex, text[index] == "e" || text[index] == "E" else { return index }
        var digits = text.index(after: index)
        if digits < text.endIndex, text[digits] == "+" || text[digits] == "-" { digits = text.index(after: digits) }
        guard digits < text.endIndex, text[digits].isNumber else { return index }
        var end = digits
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        return end
    }

    private static func nextIsDigit(_ text: String, _ index: String.Index) -> Bool {
        let next = text.index(after: index)
        return next < text.endIndex && text[next].isNumber
    }

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]

    static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": { Foundation.cbrt($0) }, "abs": { Swift.abs($0) },
        "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
        "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) }, "log2": { Foundation.log2($0) },
        "exp": { Foundation.exp($0) }, "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) },
        "tan": { Foundation.tan($0) }, "asin": { Foundation.asin($0) }, "acos": { Foundation.acos($0) },
        "atan": { Foundation.atan($0) },
    ]

    /// A value, and whether it was written as a percentage (`10%`), which `+` and `-` read as a share of the
    /// left side.
    struct Value {
        var number: Double
        var isPercent = false
    }

    struct Parser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position == tokens.count }
        var current: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func take(_ symbol: Character) -> Bool {
            guard current == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        mutating func expression() -> Value? {
            guard var left = term() else { return nil }
            while let token = current, token == .symbol("+") || token == .symbol("-") {
                position += 1
                guard let right = term() else { return nil }
                let sign: Double = token == .symbol("+") ? 1 : -1
                let base = left.isPercent ? left.number / 100 : left.number
                let amount = right.isPercent ? base * right.number / 100 : right.number
                left = Value(number: base + sign * amount)
            }
            return left
        }

        mutating func term() -> Value? {
            guard var left = unary() else { return nil }
            while true {
                if take("*") || take("/") {
                    let divide = tokens[position - 1] == .symbol("/")
                    guard let right = unary() else { return nil }
                    left = combine(left, right, divide: divide)
                } else if startsImplicitProduct {
                    guard let right = unary() else { return nil }
                    left = combine(left, right, divide: false)
                } else {
                    return left
                }
            }
        }

        private func combine(_ left: Value, _ right: Value, divide: Bool) -> Value {
            let a = left.isPercent ? left.number / 100 : left.number
            let b = right.isPercent ? right.number / 100 : right.number
            return Value(number: divide ? a / b : a * b)
        }

        /// `2pi`, `3(4+5)`, `2 sqrt(4)`: a value directly followed by a parenthesis, a name or a number.
        private var startsImplicitProduct: Bool {
            switch current {
            case .symbol("("): true
            case .name(let name): name != "of"
            case .number: true
            default: false
            }
        }

        /// `unary := ('-' | '+') unary | power`: a sign applies to the whole power, so `-2^2` is -4.
        mutating func unary() -> Value? {
            if take("-") { return unary().map { Value(number: -$0.number, isPercent: $0.isPercent) } }
            if take("+") { return unary() }
            return power()
        }

        /// `power := postfix ('^' unary)?`, right-associative: `2^3^2` is 2^9, and `2^-1` is 0.5.
        mutating func power() -> Value? {
            guard let base = postfix() else { return nil }
            guard take("^") else { return base }
            guard let exponent = unary() else { return nil }
            return Value(number: Foundation.pow(base.number, exponent.number))
        }

        mutating func postfix() -> Value? {
            guard var value = primary() else { return nil }
            while true {
                if take("!") {
                    guard value.number >= 0, value.number <= 170, value.number == value.number.rounded() else {
                        return nil
                    }
                    value = Value(number: (1...max(1, Int(value.number))).reduce(1.0) { $0 * Double($1) })
                } else if take("%") {
                    // `15% of 200` is 30; a bare `10%` stays a percentage for `+` and `-`.
                    if current == .name("of") {
                        position += 1
                        guard let whole = unary() else { return nil }
                        value = Value(number: value.number / 100 * whole.number)
                    } else {
                        value.isPercent = true
                    }
                } else {
                    return value
                }
            }
        }

        mutating func primary() -> Value? {
            switch current {
            case .number(let number):
                position += 1
                return Value(number: number)
            case .name(let name):
                position += 1
                if let constant = constants[name] { return Value(number: constant) }
                guard let function = functions[name], take("(") else { return nil }
                guard let argument = expression(), take(")") else { return nil }
                return Value(number: function(argument.isPercent ? argument.number / 100 : argument.number))
            case .symbol("("):
                position += 1
                guard let inner = expression(), take(")") else { return nil }
                return inner
            default:
                return nil
            }
        }
    }
}
