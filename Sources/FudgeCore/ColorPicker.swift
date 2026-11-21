import CoreGraphics
import Foundation

// The Color Picker (SPEC-090): Pick Color and Recent Colors, in the Tools group of Fudge's own commands. Every
// decision lives here; the app only shows macOS's loupe (`ColorSampling`), copies and shows the HUD, and tests and
// snapshot runs use samplers that never open the loupe.

/// A color as Fudge keeps it: sRGB components from 0 to 1.
public struct PickedColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    /// Each component is clamped to 0…1, and a component that isn't a number counts as 0, so an out-of-gamut value
    /// (extended sRGB's below 0 or above 1) is the nearest color sRGB has.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// A color in any color space, such as the display's (often Display P3) that macOS's loupe gives, converted to
    /// sRGB first, as `NSColor.usingColorSpace(.sRGB)` converts it, then clamped. Nil when it can't be converted (a
    /// pattern, say).
    public init?(cgColor: CGColor) {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count == 4
        else { return nil }
        self.init(
            red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]),
            alpha: Double(components[3]))
    }

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(1, max(0, value))
    }

    /// The components as bytes, 0–255, rounded to the nearest. Every format is written from these. HEX, RGB, SwiftUI
    /// and UIColor name exactly the color the HEX does; HSL is rounded to whole degrees and percent, as CSS writes it,
    /// so it can read back a step or so off on a channel.
    public var bytes: (red: Int, green: Int, blue: Int, alpha: Int) {
        (Self.byte(red), Self.byte(green), Self.byte(blue), Self.byte(alpha))
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }

    /// Whether two colors are the same once written as bytes: the same in every format.
    public func isSame(as other: PickedColor) -> Bool {
        bytes == other.bytes
    }
}

/// A way to copy a color, and the **Copy Format** setting (`colorFormat` in `settings.json`, HEX unless set).
public enum ColorFormat: String, Sendable, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl
    case swiftUI = "swiftui"
    case uiColor = "uicolor"

    public static let `default` = ColorFormat.hex

    public var id: String { rawValue }

    /// Its name in the Settings popup and the actions ("Copy HEX").
    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .swiftUI: "SwiftUI"
        case .uiColor: "UIColor"
        }
    }

    /// The color written in this format, from its bytes (`PickedColor.bytes`). An opaque color leaves its alpha out,
    /// except UIColor's initializer, which needs one.
    /// - HEX: `#3A7BD5`, or `#3A7BD580` with alpha.
    /// - RGB: `rgb(58, 123, 213)`, or `rgba(58, 123, 213, 0.502)`.
    /// - HSL: `hsl(215, 65%, 53%)`, or `hsla(…, 0.502)`, in whole degrees and percent, so it's rounded.
    /// - SwiftUI: `Color(red: 0.227, green: 0.482, blue: 0.835)`, with `opacity:` when there's alpha.
    /// - UIColor: `UIColor(red: 0.227, green: 0.482, blue: 0.835, alpha: 1)`.
    public func string(for color: PickedColor) -> String {
        let bytes = color.bytes
        let opaque = bytes.alpha == 255
        let alpha = Self.decimal(bytes.alpha)
        switch self {
        case .hex:
            let rgb = String(format: "#%02X%02X%02X", bytes.red, bytes.green, bytes.blue)
            return opaque ? rgb : rgb + String(format: "%02X", bytes.alpha)
        case .rgb:
            let rgb = "\(bytes.red), \(bytes.green), \(bytes.blue)"
            return opaque ? "rgb(\(rgb))" : "rgba(\(rgb), \(alpha))"
        case .hsl:
            let hsl = Self.hsl(bytes)
            let text = "\(hsl.hue), \(hsl.saturation)%, \(hsl.lightness)%"
            return opaque ? "hsl(\(text))" : "hsla(\(text), \(alpha))"
        case .swiftUI:
            let rgb =
                "red: \(Self.decimal(bytes.red)), green: \(Self.decimal(bytes.green)), blue: \(Self.decimal(bytes.blue))"
            return opaque ? "Color(\(rgb))" : "Color(\(rgb), opacity: \(alpha))"
        case .uiColor:
            return
                "UIColor(red: \(Self.decimal(bytes.red)), green: \(Self.decimal(bytes.green)), "
                + "blue: \(Self.decimal(bytes.blue)), alpha: \(alpha))"
        }
    }

    /// A byte as a fraction of 255 with at most three decimals and no trailing zeros, always with a `.`: `0.227`,
    /// `0.5`, `1`, `0`.
    static func decimal(_ byte: Int) -> String {
        var text = String(format: "%.3f", Double(byte) / 255)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Hue in whole degrees (0–359), saturation and lightness in whole percent.
    static func hsl(_ bytes: (red: Int, green: Int, blue: Int, alpha: Int)) -> (
        hue: Int, saturation: Int, lightness: Int
    ) {
        let r = Double(bytes.red) / 255
        let g = Double(bytes.green) / 255
        let b = Double(bytes.blue) / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let lightness = (high + low) / 2
        guard high > low else { return (0, 0, Int((lightness * 100).rounded())) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if high == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        return (Int(hue.rounded()) % 360, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }
}

/// Shows macOS's loupe and gives the color picked, in sRGB; nil when the user cancels with Esc. The app's is
/// `NSColorSampler`, which needs no Screen Recording permission. Tests and snapshot runs use ones that never show
/// the loupe.
public protocol ColorSampling: Sendable {
    func sample() async -> PickedColor?
}

/// A sampler that never shows the loupe and picks nothing, as if the user pressed Esc: snapshot runs get it.
public struct InertColorSampler: ColorSampling {
    public init() {}
    public func sample() async -> PickedColor? { nil }
}

/// Pick Color: the loupe, then the picked color copied in the Copy Format and added to Recent Colors.
public struct ColorPick: Sendable {
    public var sampler: any ColorSampling
    /// Puts the text on the clipboard; false when that failed.
    public var copy: @Sendable (String) async -> Bool
    /// `colors.json`.
    public var file: URL

    public init(sampler: any ColorSampling, copy: @escaping @Sendable (String) async -> Bool, file: URL) {
        self.sampler = sampler
        self.copy = copy
        self.file = file
    }

    /// Shows the loupe and handles the pick, returning the HUD's text: "Copied #3A7BD5". Esc returns nil, with
    /// nothing copied or saved. A color that can't be saved to Recent Colors is still copied, and the HUD says so.
    public func run(format: ColorFormat, now: @Sendable () -> Date = { Date() }) async -> String? {
        guard let color = await sampler.sample() else { return nil }
        let text = format.string(for: color)
        guard await copy(text) else { return "Couldn't copy \(text)" }
        var store = RecentColorStore.load(from: file)
        store.add(color, now: now())
        do {
            try store.save(to: file)
        } catch {
            return "Copied \(text), but Recent Colors can't be saved"
        }
        return "Copied \(text)"
    }
}

/// One of the Tools group's commands, named by its raw value in `settings.json` (`:tools/<raw value>`).
public enum ToolCommand: String, CaseIterable, Sendable {
    case pickColor = "pick-color"
    case recentColors = "recent-colors"

    /// The command's title, extra search words and SF Symbol.
    var presentation: (String, [String], String) {
        switch self {
        case .pickColor: ("Pick Color", ["color", "colour", "picker", "eyedropper", "hex"], "eyedropper")
        case .recentColors: ("Recent Colors", ["color", "colour", "picker", "history", "hex"], "swatchpalette")
        }
    }
}

extension BuiltInCommandGroup {
    /// Tools: small utilities that aren't about windows or the system, one command per `ToolCommand`.
    public static let tools = BuiltInCommandGroup(
        name: ":tools", title: "Tools",
        commands: ToolCommand.allCases.map { command in
            let (title, keywords, symbol) = command.presentation
            return BuiltInCommand(name: command.rawValue, title: title, keywords: keywords, symbol: symbol)
        })
}
