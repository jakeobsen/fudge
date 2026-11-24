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
        // Grouped by the folded title first, so only titles that can be the same are compared.
        var groups: [String: [InstalledExtension]] = [:]
        for item in InstalledExtension.index(installed).values {
            groups[Self.key(item.manifest.title), default: []].append(item)
        }
        var labels: [ExtensionID: String] = [:]
        for group in groups.values where group.count > 1 {
            for item in group
            where group.contains(where: { $0.id != item.id && Self.same($0.manifest.title, item.manifest.title) }) {
                labels[item.id] = names.label(of: item.repository)
            }
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

    /// Whether two titles are the same name: equal after trimming spaces and line breaks at both ends, ignoring letter
    /// case, as root search tells a subtitle that only repeats the title (`RootItem.subtitle(_:unlessItRepeats:)`).
    /// Spaces inside a title still count.
    public static func same(_ first: String, _ second: String) -> Bool {
        first.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(second.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// A title's group: trimmed and folded the way `caseInsensitiveCompare` folds case, so titles that are the same name
    /// always share one. `same` still decides within a group.
    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .caseInsensitive, locale: nil)
    }
}
