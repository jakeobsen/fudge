import Foundation

/// A `Color.ColorLike` from an extension: one of Raycast's named colors, a hex color, or a light/dark pair.
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
            return
        }
        guard trimmed.hasPrefix("#") else { return nil }
        var digits = Array(trimmed.dropFirst())
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
        if digits.count == 6 { digits += ["f", "f"] }
        let bytes = stride(from: 0, to: 8, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16)!) / 255 }
        self = .rgb(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}
