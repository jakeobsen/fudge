import Foundation

/// A `Color.ColorLike` from an extension: one of Raycast's named colors, an HTML color (hex, `rgb()`, `rgba()`,
/// `hsl()`, `hsla()` or a CSS color name), or a light/dark pair.
public indirect enum ExtensionColor: Sendable, Equatable {
    /// A Raycast color by its value, e.g. "raycast-red" or "raycast-secondary-text".
    case named(String)
    /// Components from 0 to 1.
    case rgb(red: Double, green: Double, blue: Double, alpha: Double)
    case dynamic(light: ExtensionColor, dark: ExtensionColor)

    public static let namedColors: Set<String> = [
        "raycast-blue", "raycast-green", "raycast-magenta", "raycast-orange", "raycast-purple", "raycast-red",
        "raycast-yellow", "raycast-primary-text", "raycast-secondary-text",
    ]

    public init?(json: JSONValue?) {
        switch json {
        case .string(let string):
            self.init(string)
        case .object(let object):
            guard let light = ExtensionColor(json: object["light"]), let dark = ExtensionColor(json: object["dark"])
            else { return nil }
            self = .dynamic(light: light, dark: dark)
        default:
            return nil
        }
    }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if Self.namedColors.contains(trimmed) {
            self = .named(trimmed)
        } else if trimmed.hasPrefix("#") {
            guard let color = Self.hex(String(trimmed.dropFirst())) else { return nil }
            self = color
        } else if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            let function = trimmed[..<open].lowercased()
            let arguments = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            guard let color = Self.function(function, arguments: String(arguments)) else { return nil }
            self = color
        } else if let hex = Self.cssNames[trimmed.lowercased()] {
            self = Self.hex(hex)!
        } else {
            return nil
        }
    }

    /// `rgb`, `rgba`, `hsl` or `hsla` with comma- or space-separated arguments, and `/` before the alpha.
    private static func function(_ name: String, arguments: String) -> ExtensionColor? {
        let parts = arguments.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func number(_ text: String, scale: Double) -> Double? {
            if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
            return Double(text).map { $0 / scale }
        }
        let alpha = parts.count == 4 ? number(parts[3], scale: 1) : 1
        switch name {
        case "rgb", "rgba":
            guard let red = number(parts[0], scale: 255), let green = number(parts[1], scale: 255),
                let blue = number(parts[2], scale: 255), let alpha
            else { return nil }
            return .rgb(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
        case "hsl", "hsla":
            guard let hue = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                let saturation = number(parts[1], scale: 100), let lightness = number(parts[2], scale: 100), let alpha
            else { return nil }
            let (red, green, blue) = rgb(hue: hue, saturation: clamp(saturation), lightness: clamp(lightness))
            return .rgb(red: red, green: green, blue: blue, alpha: clamp(alpha))
        default:
            return nil
        }
    }

    private static func hex(_ text: String) -> ExtensionColor? {
        var digits = Array(text)
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
        if digits.count == 6 { digits += ["f", "f"] }
        let bytes = stride(from: 0, to: 8, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16)!) / 255 }
        return .rgb(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Components that stay readable on the appearance's background, as Raycast's `adjustContrast` does:
    /// a color too dark for dark mode is mixed toward white, one too light for light mode toward black.
    public static func readable(red: Double, green: Double, blue: Double, dark: Bool) -> (Double, Double, Double) {
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let target = dark ? 1.0 : 0.0
        var mix = 0.0
        while mix < 1 {
            let (r, g, b) = (red + (target - red) * mix, green + (target - green) * mix, blue + (target - blue) * mix)
            let l = luminance(r, g, b)
            if dark ? l >= 0.18 : l <= 0.45 { return (r, g, b) }
            mix += 0.05
        }
        return (target, target, target)
    }

    /// HSL to RGB, as CSS defines it.
    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return (channel(0), channel(8), channel(4))
    }

    /// The CSS color names.
    static let cssNames: [String: String] = [
        "aliceblue": "f0f8ff", "antiquewhite": "faebd7", "aqua": "00ffff", "aquamarine": "7fffd4", "azure": "f0ffff",
        "beige": "f5f5dc", "bisque": "ffe4c4", "black": "000000", "blanchedalmond": "ffebcd", "blue": "0000ff",
        "blueviolet": "8a2be2", "brown": "a52a2a", "burlywood": "deb887", "cadetblue": "5f9ea0",
        "chartreuse": "7fff00", "chocolate": "d2691e", "coral": "ff7f50", "cornflowerblue": "6495ed",
        "cornsilk": "fff8dc", "crimson": "dc143c", "cyan": "00ffff", "darkblue": "00008b", "darkcyan": "008b8b",
        "darkgoldenrod": "b8860b", "darkgray": "a9a9a9", "darkgreen": "006400", "darkgrey": "a9a9a9",
        "darkkhaki": "bdb76b", "darkmagenta": "8b008b", "darkolivegreen": "556b2f", "darkorange": "ff8c00",
        "darkorchid": "9932cc", "darkred": "8b0000", "darksalmon": "e9967a", "darkseagreen": "8fbc8f",
        "darkslateblue": "483d8b", "darkslategray": "2f4f4f", "darkslategrey": "2f4f4f", "darkturquoise": "00ced1",
        "darkviolet": "9400d3", "deeppink": "ff1493", "deepskyblue": "00bfff", "dimgray": "696969",
        "dimgrey": "696969", "dodgerblue": "1e90ff", "firebrick": "b22222", "floralwhite": "fffaf0",
        "forestgreen": "228b22", "fuchsia": "ff00ff", "gainsboro": "dcdcdc", "ghostwhite": "f8f8ff",
        "gold": "ffd700", "goldenrod": "daa520", "gray": "808080", "green": "008000", "greenyellow": "adff2f",
        "grey": "808080", "honeydew": "f0fff0", "hotpink": "ff69b4", "indianred": "cd5c5c", "indigo": "4b0082",
        "ivory": "fffff0", "khaki": "f0e68c", "lavender": "e6e6fa", "lavenderblush": "fff0f5",
        "lawngreen": "7cfc00", "lemonchiffon": "fffacd", "lightblue": "add8e6", "lightcoral": "f08080",
        "lightcyan": "e0ffff", "lightgoldenrodyellow": "fafad2", "lightgray": "d3d3d3", "lightgreen": "90ee90",
        "lightgrey": "d3d3d3", "lightpink": "ffb6c1", "lightsalmon": "ffa07a", "lightseagreen": "20b2aa",
        "lightskyblue": "87cefa", "lightslategray": "778899", "lightslategrey": "778899",
        "lightsteelblue": "b0c4de", "lightyellow": "ffffe0", "lime": "00ff00", "limegreen": "32cd32",
        "linen": "faf0e6", "magenta": "ff00ff", "maroon": "800000", "mediumaquamarine": "66cdaa",
        "mediumblue": "0000cd", "mediumorchid": "ba55d3", "mediumpurple": "9370db", "mediumseagreen": "3cb371",
        "mediumslateblue": "7b68ee", "mediumspringgreen": "00fa9a", "mediumturquoise": "48d1cc",
        "mediumvioletred": "c71585", "midnightblue": "191970", "mintcream": "f5fffa", "mistyrose": "ffe4e1",
        "moccasin": "ffe4b5", "navajowhite": "ffdead", "navy": "000080", "oldlace": "fdf5e6", "olive": "808000",
        "olivedrab": "6b8e23", "orange": "ffa500", "orangered": "ff4500", "orchid": "da70d6",
        "palegoldenrod": "eee8aa", "palegreen": "98fb98", "paleturquoise": "afeeee", "palevioletred": "db7093",
        "papayawhip": "ffefd5", "peachpuff": "ffdab9", "peru": "cd853f", "pink": "ffc0cb", "plum": "dda0dd",
        "powderblue": "b0e0e6", "purple": "800080", "rebeccapurple": "663399", "red": "ff0000",
        "rosybrown": "bc8f8f", "royalblue": "4169e1", "saddlebrown": "8b4513", "salmon": "fa8072",
        "sandybrown": "f4a460", "seagreen": "2e8b57", "seashell": "fff5ee", "sienna": "a0522d", "silver": "c0c0c0",
        "skyblue": "87ceeb", "slateblue": "6a5acd", "slategray": "708090", "slategrey": "708090", "snow": "fffafa",
        "springgreen": "00ff7f", "steelblue": "4682b4", "tan": "d2b48c", "teal": "008080", "thistle": "d8bfd8",
        "tomato": "ff6347", "transparent": "00000000", "turquoise": "40e0d0", "violet": "ee82ee", "wheat": "f5deb3",
        "white": "ffffff", "whitesmoke": "f5f5f5", "yellow": "ffff00", "yellowgreen": "9acd32",
    ]
}
