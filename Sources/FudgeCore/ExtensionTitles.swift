import Foundation

/// How Fudge names each installed extension (SPEC-174 A): its title, then its repository in parentheses when another
/// installed extension has the same title.
///
/// It's built from the whole set of installs, enabled or not, with the bundled ones, so a label never changes when a
/// switch is flipped, and root search, the menu bar and Settings show one extension under the same title.
public struct ExtensionTitles: Sendable, Equatable {
    /// The label of each install whose title another install shares, by id.
    private let labels: [ExtensionID: String]

    public init(_ installed: [InstalledExtension], names: RepositoryNames) {
        // Grouped by the key's scalars, so titles are the same name exactly when they share a group.
        var groups: [[Unicode.Scalar]: [InstalledExtension]] = [:]
        for item in InstalledExtension.index(installed).values {
            groups[Array(Self.key(item.manifest.title).unicodeScalars), default: []].append(item)
        }
        var labels: [ExtensionID: String] = [:]
        for group in groups.values where group.count > 1 {
            for item in group { labels[item.id] = names.label(of: item.repository) }
        }
        self.labels = labels
    }

    /// The repository's label when another install has the same title, else nil.
    public func label(of installed: InstalledExtension) -> String? {
        labels[installed.id]
    }

    /// The manifest's title, then " (label)" when there is one.
    public func title(of installed: InstalledExtension) -> String {
        label(of: installed).map { "\(installed.manifest.title) (\($0))" } ?? installed.manifest.title
    }

    /// The answer to the Extension Store's `sharedLabels()` (`store.sharedLabels`, SPEC-175): each labeled install's
    /// label by its id, `{ "<id>": "<label>" }`; `{}` when no two installs have the same title.
    public var storeAnswer: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: labels.map { ($0.key.key, JSONValue.string($0.value)) }))
    }

    /// The scalars trimmed from both ends of a name (SPEC-175 5.2 step 1): exactly what `.whitespacesAndNewlines` trims
    /// on macOS 26.6, written out so the Extension Store's `repository-name.ts` can hold the same list.
    static let trimmedScalars: [Unicode.Scalar] = [
        "\u{9}", "\u{A}", "\u{B}", "\u{C}", "\u{D}", "\u{20}", "\u{85}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2001}",
        "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{200B}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
    ]

    /// Unicode's case foldings that lowercasing leaves out for letters people type (SPEC-175 5.2 step 3).
    static let folds: [Unicode.Scalar: String] = [
        "\u{DF}": "ss", "\u{3C2}": "\u{3C3}", "\u{17F}": "s", "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
        "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    /// `text` without the trimmed scalars at either end (SPEC-175 5.2 step 1), for the name rule.
    static func trimmed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(where: { !trimmedScalars.contains($0) }) else { return "" }
        let end = scalars.lastIndex(where: { !trimmedScalars.contains($0) })!
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start...end])
        return String(view)
    }

    /// A name's key (SPEC-175 5.2), the same step for step as the Extension Store's `nameKey`: trimmed, decomposed
    /// (NFD), each scalar's full lowercase mapping with the fold table applied, and decomposed again. Two names are the
    /// same when their keys have the same scalars.
    public static func key(_ title: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in trimmed(title).decomposedStringWithCanonicalMapping.unicodeScalars {
            for lower in scalar.properties.lowercaseMapping.unicodeScalars {
                if let fold = folds[lower] {
                    folded.append(contentsOf: fold.unicodeScalars)
                } else {
                    folded.append(lower)
                }
            }
        }
        return String(folded).decomposedStringWithCanonicalMapping
    }

    /// Whether two titles or repository names are the same name: their keys have the same scalars, compared one by
    /// one, never with `==`, which uses Swift's own canonical equivalence. Root search tells a subtitle that only
    /// repeats the title the same way (`RootItem.subtitle(_:unlessItRepeats:)`). Spaces inside a name still count.
    public static func same(_ first: String, _ second: String) -> Bool {
        key(first).unicodeScalars.elementsEqual(key(second).unicodeScalars)
    }
}
