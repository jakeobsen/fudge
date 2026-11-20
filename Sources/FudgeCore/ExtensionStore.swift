import Foundation

/// The Extension Store (FUD-50): an extension bundled with fudge that lists and installs extensions from the public
/// github.com/raycast/extensions repository. It's off until the user turns it on in Settings and confirms the
/// consent sheet; `settings.json` edited by hand to on, without the consent date, counts as off.
public enum ExtensionStore {
    /// The bundled extension's name, which a user's extension can't take while the store is on.
    public static let extensionName = "fudge-extension-store"

    /// The bundled extension: `store-extension/` in the app's resources, when it's there.
    public static func bundledDirectory(resources: URL?) -> URL? {
        guard let folder = resources?.appendingPathComponent("store-extension", isDirectory: true),
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("package.json").path)
        else { return nil }
        return folder
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
            "The Extension Store lists the extensions published in the open-source repository "
            + "github.com/raycast/extensions, and installs the ones you choose. While it's on, fudge connects to "
            + "GitHub (github.com and its image servers) to download the list, the extensions you install, and "
            + "their pictures. npm downloads their packages from registry.npmjs.org; the store refuses extensions "
            + "that get packages from anywhere else. fudge never contacts Raycast's servers. An extension you "
            + "install runs its own code on your Mac with your permissions, like any app you install, so only "
            + "install extensions you trust."
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

extension InstalledExtension {
    /// The user's installed extensions, plus the bundled Extension Store while it's on, sorted by title. A user's
    /// extension with the store's name gives way to the bundled one.
    public static func all(paths: FudgePaths, settings: FudgeSettings, resources: URL?) -> [InstalledExtension] {
        var extensions = all(in: paths.extensionsDirectory)
        guard settings.isExtensionStoreOn, let folder = ExtensionStore.bundledDirectory(resources: resources),
            let store = try? load(from: folder)
        else { return extensions }
        extensions.removeAll { $0.manifest.name == store.manifest.name }
        extensions.append(store)
        return extensions.sorted { $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending }
    }
}
