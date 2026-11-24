import Foundation

/// What each repository is called (SPEC-174 B), from `settings.json`: the label an install shows after its title when
/// another installed extension has the same title (`ExtensionTitles`).
public struct RepositoryNames: Sendable, Equatable {
    /// Raycast's official repository's label, fixed, also once it's removed and added back.
    public static let raycast = ExtensionRepositoryText.raycastLabel
    /// The development folder's label.
    public static let development = "development"
    /// The label of the extensions in Fudge's own resources.
    public static let fudge = "Fudge"
    /// The longest name, in characters.
    public static let maxLength = 40

    /// Why a name typed in the **Add Repository** window can't be used. Each has one sentence.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case slash
        /// A control or format character, a line or paragraph separator, or a space other than U+0020.
        case characters
        case tooLong
        case raycast
        case development
        case fudge
        /// Another repository in the list has that name, as it's written there.
        case taken(String)

        public var description: String {
            switch self {
            case .slash: "A name can't have a slash in it."
            case .characters: "That name has characters Fudge can't use."
            case .tooLong: "Use a name of up to \(RepositoryNames.maxLength) characters."
            case .raycast: "Raycast's official repository is called raycast."
            case .development: "Fudge uses that name for your development builds."
            case .fudge: "Fudge uses that name for its own extensions."
            case .taken(let name): "Another repository is already called \(name)."
            }
        }
    }

    /// The name in `text`, trimmed of spaces and line breaks at both ends, nil when that leaves nothing; or why it
    /// can't be used beside `others`, the names of the other repositories in the list. The checks run in this order,
    /// so a name with more than one problem always gets the same sentence.
    ///
    /// No `/`, so no name reads like an unnamed repository's label, which always has one. None of the characters that
    /// are invisible or change how the rest of the row is drawn, so no name reads the same as another that passed the
    /// duplicate check.
    public static func check(_ text: String, others: [String] = []) -> Result<String?, Refusal> {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .success(nil) }
        guard !name.contains("/") else { return .failure(.slash) }
        guard name.unicodeScalars.allSatisfy(isUsable) else { return .failure(.characters) }
        guard name.count <= maxLength else { return .failure(.tooLong) }
        if ExtensionTitles.same(name, raycast) { return .failure(.raycast) }
        if ExtensionTitles.same(name, development) { return .failure(.development) }
        if ExtensionTitles.same(name, fudge) { return .failure(.fudge) }
        if let other = others.first(where: { ExtensionTitles.same(name, $0) }) { return .failure(.taken(other)) }
        return .success(name)
    }

    /// Whether a name may have `scalar`: not of Unicode category Cc, Cf, Zl or Zp, and no space but U+0020.
    static func isUsable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: false
        case .spaceSeparator: scalar == " "
        default: true
        }
    }

    /// Each listed repository's label by its folder: its name, else its `owner/repository` as typed.
    private let listed: [String: String]

    public init(settings: FudgeSettings) {
        listed = Dictionary(
            settings.extensionRepositories.map { ($0.repository.folder, $0.label ?? $0.repository.name) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The label of an install from `repository`: `raycast` for Raycast's official repository, listed or not; a listed
    /// repository's name, else its `owner/repository`; the folder of a repository no longer in the list; `development`
    /// for the development folder; and `Fudge` for an extension in Fudge's own resources.
    public func label(of repository: InstalledExtension.Repository) -> String {
        switch repository {
        case .raycast: Self.raycast
        case .development: Self.development
        case .bundled: Self.fudge
        case .added(let folder): listed[folder] ?? folder
        }
    }
}
