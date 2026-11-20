import Foundation

/// Converts between units written the way people type them: `13kg to lbs`, `5 km in miles`, `100f to c`,
/// `2 gb in mb`. Both units must measure the same thing.
public enum UnitConversion {
    public struct Result: Sendable, Equatable {
        public var value: Double
        public var from: UnitName
        public var to: UnitName
    }

    /// A unit as fudge shows it: its symbol after a number, and its name in labels.
    public struct UnitName: Sendable, Equatable {
        public var symbol: String
        public var name: String
    }

    // Lookarounds, so `5 in to cm` matches both `in` and `to`: a match doesn't use up the spaces around it.
    nonisolated(unsafe) private static let separator = try! NSRegularExpression(
        pattern: #"(?<=\s)(?:to|in|as|into|=|->)(?=\s)"#)
    nonisolated(unsafe) private static let quantityPattern = try! NSRegularExpression(
        pattern: #"^\s*(-?[\d.,'’]*\d(?:[eE][+-]?\d+)?)\s*(.+?)\s*$"#)

    /// The conversion `text` asks for, or nil. Its number is read in `format` (`NumberFormat.number`).
    public static func evaluate(_ text: String, format: NumberFormat = .dotDecimal) -> Result? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        // Try each `to`/`in`/`as`/`into`/`=`, so `5 in to cm` (inches) still works.
        let range = NSRange(lowered.startIndex..., in: lowered)
        for match in separator.matches(in: lowered, range: range) {
            guard let split = Range(match.range, in: lowered) else { continue }
            guard let (amount, from) = quantity(String(lowered[..<split.lowerBound]), format: format),
                let to = unit(String(lowered[split.upperBound...])),
                sameQuantity(from.unit, to.unit)
            else { continue }
            let value = Measurement(value: amount, unit: from.unit).converted(to: to.unit).value
            return Result(value: value, from: from.name, to: to.name)
        }
        return nil
    }

    /// Whether two units measure the same thing. Foundation's built-in units are private subclasses
    /// (`_NSStatic_NSUnitMass`), so classes can't be compared; their base units can.
    private static func sameQuantity(_ a: Dimension, _ b: Dimension) -> Bool {
        type(of: a).baseUnit().symbol == type(of: b).baseUnit().symbol
    }

    /// `13kg`, `13 kg`, `13,5 kg`.
    private static func quantity(_ text: String, format: NumberFormat) -> (Double, Known)? {
        guard let match = quantityPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let number = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text),
            let amount = Arithmetic.number(String(text[number]), format: format),
            let known = unit(String(text[name]))
        else { return nil }
        return (amount, known)
    }

    struct Known {
        var unit: Dimension
        var name: UnitName
    }

    private static func unit(_ text: String) -> Known? {
        var key = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "°", with: "")
        key = key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for prefix in ["degrees ", "degree ", "deg "] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        return table[key]
    }

    /// Every spelling of every unit, built from `units`.
    static let table: [String: Known] = {
        var table: [String: Known] = [:]
        for (unit, symbol, name, aliases) in units {
            let known = Known(unit: unit, name: UnitName(symbol: symbol, name: name))
            for alias in aliases + [symbol.lowercased(), name.lowercased()] where table[alias] == nil {
                table[alias] = known
            }
        }
        return table
    }()

    private static func duration(_ symbol: String, seconds: Double) -> UnitDuration {
        UnitDuration(symbol: symbol, converter: UnitConverterLinear(coefficient: seconds))
    }

    // Foundation rounds some customary units (a pound is 0.453592 kg), which shows at 10 significant digits.
    // These use the exact definitions.
    private static func exact<U: Dimension>(_ type: U.Type, _ symbol: String, _ coefficient: Double) -> U {
        U(symbol: symbol, converter: UnitConverterLinear(coefficient: coefficient))
    }

    // (unit, symbol, plural name, other spellings). The symbol and the name are spellings too.
    nonisolated(unsafe) static let units: [(Dimension, String, String, [String])] = [
        (UnitLength.millimeters, "mm", "Millimeters", ["millimeter", "millimetre", "millimetres"]),
        (UnitLength.centimeters, "cm", "Centimeters", ["centimeter", "centimetre", "centimetres"]),
        (UnitLength.meters, "m", "Meters", ["meter", "metre", "metres"]),
        (UnitLength.kilometers, "km", "Kilometers", ["kilometer", "kilometre", "kilometres", "kms"]),
        (UnitLength.micrometers, "µm", "Micrometers", ["um", "micrometer", "micron", "microns"]),
        (UnitLength.inches, "in", "Inches", ["inch", "\""]),
        (UnitLength.feet, "ft", "Feet", ["foot", "'"]),
        (UnitLength.yards, "yd", "Yards", ["yard", "yds"]),
        (UnitLength.miles, "mi", "Miles", ["mile"]),
        (UnitLength.nauticalMiles, "nmi", "Nautical Miles", ["nautical mile"]),
        (UnitMass.milligrams, "mg", "Milligrams", ["milligram"]),
        (UnitMass.grams, "g", "Grams", ["gram", "gr"]),
        (UnitMass.kilograms, "kg", "Kilograms", ["kilogram", "kilo", "kilos", "kgs"]),
        (UnitMass.metricTons, "t", "Tonnes", ["tonne", "ton", "tons", "metric ton", "metric tons"]),
        (exact(UnitMass.self, "oz", 0.028349523125), "oz", "Ounces", ["ounce"]),
        (exact(UnitMass.self, "lb", 0.45359237), "lb", "Pounds", ["lbs", "pound"]),
        (exact(UnitMass.self, "st", 6.35029318), "st", "Stones", ["stone"]),
        (UnitTemperature.celsius, "°C", "Celsius", ["c", "centigrade"]),
        (UnitTemperature.fahrenheit, "°F", "Fahrenheit", ["f"]),
        (UnitTemperature.kelvin, "K", "Kelvin", ["kelvins"]),
        (UnitVolume.milliliters, "ml", "Milliliters", ["milliliter", "millilitre", "millilitres"]),
        (UnitVolume.centiliters, "cl", "Centiliters", ["centiliter", "centilitre"]),
        (UnitVolume.deciliters, "dl", "Deciliters", ["deciliter", "decilitre"]),
        (UnitVolume.liters, "l", "Liters", ["liter", "litre", "litres", "ltr"]),
        (UnitVolume.cubicMeters, "m³", "Cubic Meters", ["m3", "cubic meter", "cubic metre"]),
        (exact(UnitVolume.self, "gal", 3.785411784), "gal", "Gallons", ["gallon", "us gallon", "us gallons"]),
        (UnitVolume.imperialGallons, "imp gal", "Imperial Gallons", ["imperial gallon", "uk gallon"]),
        (exact(UnitVolume.self, "qt", 0.946352946), "qt", "Quarts", ["quart"]),
        (exact(UnitVolume.self, "pt", 0.473176473), "pt", "Pints", ["pint"]),
        (exact(UnitVolume.self, "cup", 0.2365882365), "cup", "Cups", ["cups"]),
        (exact(UnitVolume.self, "fl oz", 0.0295735295625), "fl oz", "Fluid Ounces", ["floz", "fluid ounce"]),
        (exact(UnitVolume.self, "tbsp", 0.01478676478125), "tbsp", "Tablespoons", ["tablespoon"]),
        (exact(UnitVolume.self, "tsp", 0.00492892159375), "tsp", "Teaspoons", ["teaspoon"]),
        (UnitArea.squareMillimeters, "mm²", "Square Millimeters", ["mm2", "sq mm"]),
        (UnitArea.squareCentimeters, "cm²", "Square Centimeters", ["cm2", "sq cm"]),
        (UnitArea.squareMeters, "m²", "Square Meters", ["m2", "sqm", "sq m", "square meter", "square metre"]),
        (UnitArea.squareKilometers, "km²", "Square Kilometers", ["km2", "sq km", "square kilometer"]),
        (UnitArea.squareInches, "in²", "Square Inches", ["in2", "sq in", "square inch"]),
        (exact(UnitArea.self, "ft²", 0.09290304), "ft²", "Square Feet", ["ft2", "sq ft", "sqft", "square foot"]),
        (exact(UnitArea.self, "mi²", 2_589_988.110336), "mi²", "Square Miles", ["mi2", "sq mi", "square mile"]),
        (exact(UnitArea.self, "ac", 4046.8564224), "ac", "Acres", ["acre"]),
        (UnitArea.hectares, "ha", "Hectares", ["hectare"]),
        (UnitSpeed.metersPerSecond, "m/s", "Meters per Second", ["mps", "meters per second"]),
        (UnitSpeed.kilometersPerHour, "km/h", "Kilometers per Hour", ["kmh", "kph", "kmt", "km/t"]),
        (UnitSpeed.milesPerHour, "mph", "Miles per Hour", ["mi/h"]),
        (exact(UnitSpeed.self, "kn", 1852.0 / 3600), "kn", "Knots", ["knot", "kt", "kts"]),
        (UnitDuration.milliseconds, "ms", "Milliseconds", ["millisecond", "msec"]),
        (UnitDuration.seconds, "s", "Seconds", ["sec", "secs", "second"]),
        (UnitDuration.minutes, "min", "Minutes", ["mins", "minute"]),
        (UnitDuration.hours, "h", "Hours", ["hr", "hrs", "hour"]),
        (duration("d", seconds: 86_400), "d", "Days", ["day"]),
        (duration("wk", seconds: 604_800), "wk", "Weeks", ["week", "weeks", "w"]),
        (duration("yr", seconds: 31_557_600), "yr", "Years", ["year", "years", "y"]),
        (UnitInformationStorage.bits, "bit", "Bits", ["bits"]),
        (UnitInformationStorage.bytes, "B", "Bytes", ["byte"]),
        (UnitInformationStorage.kilobytes, "KB", "Kilobytes", ["kilobyte"]),
        (UnitInformationStorage.megabytes, "MB", "Megabytes", ["megabyte"]),
        (UnitInformationStorage.gigabytes, "GB", "Gigabytes", ["gigabyte"]),
        (UnitInformationStorage.terabytes, "TB", "Terabytes", ["terabyte"]),
        (UnitInformationStorage.kibibytes, "KiB", "Kibibytes", ["kibibyte"]),
        (UnitInformationStorage.mebibytes, "MiB", "Mebibytes", ["mebibyte"]),
        (UnitInformationStorage.gibibytes, "GiB", "Gibibytes", ["gibibyte"]),
        (UnitInformationStorage.megabits, "Mbit", "Megabits", ["mb/s", "mbps", "megabit"]),
        (UnitInformationStorage.gigabits, "Gbit", "Gigabits", ["gbps", "gigabit"]),
        (UnitEnergy.joules, "J", "Joules", ["joule"]),
        (UnitEnergy.kilojoules, "kJ", "Kilojoules", ["kilojoule"]),
        (UnitEnergy.calories, "cal", "Calories", ["calorie"]),
        (UnitEnergy.kilocalories, "kcal", "Kilocalories", ["kilocalorie"]),
        (UnitEnergy.kilowattHours, "kWh", "Kilowatt-Hours", ["kilowatt hour", "kilowatt hours"]),
        (UnitPressure.hectopascals, "hPa", "Hectopascals", ["hectopascal", "mbar", "millibar"]),
        (UnitPressure.kilopascals, "kPa", "Kilopascals", ["kilopascal"]),
        (UnitPressure.bars, "bar", "Bars", ["bars"]),
        (exact(UnitPressure.self, "psi", 6894.757293168), "psi", "Pounds per Square Inch", []),
        (
            UnitPressure(symbol: "atm", converter: UnitConverterLinear(coefficient: 101_325)), "atm",
            "Atmospheres", ["atmosphere"]
        ),
    ]
}
