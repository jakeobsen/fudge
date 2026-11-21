import Foundation

/// The Extension Store (FUD-50): an extension bundled with fudge that lists and installs extensions from the public
/// github.com/raycast/extensions repository. It's always installed, and takes two steps to use (SPEC-041): enable it
/// on the Commands page (`FudgeSettings.isEnabled(extension:)`, off by default for the store alone), then turn it on
/// with the switch on its own Settings page and confirm the consent sheet. `settings.json` edited by hand to on,
/// without the consent date, counts as off.
public enum ExtensionStore {
    /// The bundled extension's name, which a user's extension can't take.
    public static let extensionName = "fudge-extension-store"

    /// The switch at the top of the store's Settings page.
    public enum Switch {
        public static let title = "Extension Store"
        public static let help = "Browse and install extensions from Raycast's open-source repository."
    }

    /// What opening the store shows while it's off, in place of the store: its code isn't started, so it downloads
    /// nothing. The action does what ⌘⇧, does.
    public enum Off {
        public static let title = "The Extension Store is off."
        public static let action = "Open Extension Store Settings"
    }

    /// Whether launching a command of `extensionName` shows the "off" view instead: it's the store, and the store
    /// isn't on (`FudgeSettings.isExtensionStoreOn`). The app decides this before the store's code would start.
    public static func isOff(_ extensionName: String, settings: FudgeSettings) -> Bool {
        extensionName == Self.extensionName && !settings.isExtensionStoreOn
    }

    /// The bundled extension: `store-extension/` in the app's resources, when it's there.
    public static func bundledDirectory(resources: URL?) -> URL? {
        BundledExtensions.directory("store-extension", resources: resources)
    }

    /// The store's downloaded copy of the repository. Turning the store off deletes it, and only it: the store's
    /// `installed.json` beside it stays, so the store still knows what it installed when it's turned on again.
    public static func repositoryDirectory(_ paths: FudgePaths) -> URL {
        paths.supportDirectory(forExtension: extensionName).appendingPathComponent("repo", isDirectory: true)
    }

    /// Deletes the downloaded repository, if there is one.
    public static func deleteRepository(_ paths: FudgePaths) throws {
        let folder = repositoryDirectory(paths)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// What the extension host tells the store: where the `fudge` tool is, and the folder it installs into
    /// (`fudge build --into`). Every worker sees these.
    public static func hostEnvironment(cli: URL?, paths: FudgePaths) -> [String: String] {
        var environment = ["FUDGE_EXTENSIONS_DIR": paths.extensionsDirectory.path]
        if let cli { environment["FUDGE_CLI"] = cli.path }
        return environment
    }

    public enum Consent {
        public static let title = "Turn on the Extension Store?"
        public static let message =
            "This adds the Extension Store to Fudge. It downloads extensions from Raycast's open-source extensions "
            + "repository on GitHub."
        /// The second paragraph, with `issueLinkText` linking to `issuesURL`.
        public static let note =
            "Fudge aims to run Raycast extensions, but not all of them work yet. If you find one that doesn't, "
            + "please file an issue."
        public static let issueLinkText = "file an issue"
        public static let issuesURL = URL(string: "https://github.com/jakeobsen/fudge/issues")!
        public static let confirm = "Turn On"
        public static let cancel = "Cancel"
    }

    public enum TurnOff {
        public static let title = "Turn off the Extension Store?"
        public static let message =
            "Extensions you installed stay installed. The store's downloaded list is deleted."
        public static let confirm = "Turn Off"
        public static let cancel = "Cancel"
    }
}

/// The extensions bundled with Fudge (SPEC-069 §1): the Extension Store, Search Files, Search Emoji & Symbols and Clipboard History. `make app` builds each from
/// `runtime/<folder>` into the app's resources, under the same folder name. They're always installed. The store keeps
/// its own off-by-default rule and switch (`ExtensionStore`); the others are enabled by default, like any extension.
public enum BundledExtensions {
    /// Their folders, in `runtime/` and in the app's resources.
    public static let folders = [
        "store-extension", "file-search-extension", "emoji-extension", "clipboard-history-extension",
    ]

    /// The bundled extension in `folder` of the app's resources, when it's there.
    public static func directory(_ folder: String, resources: URL?) -> URL? {
        guard let directory = resources?.appendingPathComponent(folder, isDirectory: true),
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path)
        else { return nil }
        return directory
    }
}

extension InstalledExtension {
    /// The user's installed extensions, plus the bundled ones, sorted by title. A user's extension with a bundled
    /// one's name gives way to it. Only the bundled ones' manifests are read here.
    public static func all(paths: FudgePaths, resources: URL?) -> [InstalledExtension] {
        var extensions = all(in: paths.extensionsDirectory)
        let bundled = BundledExtensions.folders.compactMap { folder in
            BundledExtensions.directory(folder, resources: resources).flatMap { try? load(from: $0) }
        }
        let names = Set(bundled.map(\.manifest.name))
        extensions.removeAll { names.contains($0.manifest.name) }
        extensions += bundled
        return extensions.sorted { $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending }
    }

    /// The extensions with a page in the Settings window's sidebar: those with preferences, and the Extension Store
    /// and Clipboard History, whose pages start with their switches. Enabled or not.
    public static func settingsPages(of installed: [InstalledExtension]) -> [InstalledExtension] {
        installed.filter { installed in
            installed.manifest.name == ExtensionStore.extensionName
                || installed.manifest.name == ClipboardHistory.extensionName || !installed.manifest.preferences.isEmpty
                || installed.manifest.commands.contains { !$0.preferences.isEmpty }
        }
    }
}
