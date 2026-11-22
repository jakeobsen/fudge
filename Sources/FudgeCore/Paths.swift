import Foundation

/// Where fudge keeps its files.
public struct FudgePaths: Sendable, Equatable {
    /// The root folder for everything fudge stores.
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// `~/Library/Application Support/fudge`, or `$FUDGE_SUPPORT_DIR` when it is set.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FudgePaths {
        if let override = environment["FUDGE_SUPPORT_DIR"], !override.isEmpty {
            return FudgePaths(supportDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FudgePaths(supportDirectory: applicationSupport.appendingPathComponent("fudge", isDirectory: true))
    }

    /// Where the log files go (SPEC-124): `~/Library/Logs/Fudge`, or `$FUDGE_SUPPORT_DIR/Logs` when that is set, so
    /// a throwaway run (tests, snapshot runs) never writes into the user's logs.
    public static func logsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["FUDGE_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/Fudge", isDirectory: true)
    }

    /// SwiftPM's shared cache for extensions' parts written in Swift (SPEC-145 §2), so a later build doesn't fetch
    /// their packages again: `~/Library/Caches/Fudge/SwiftPM`, or `$FUDGE_SUPPORT_DIR/Caches/SwiftPM` when that is set,
    /// so a throwaway run never writes into the user's caches.
    public static func swiftPackageCache(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["FUDGE_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("Caches/SwiftPM", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Fudge/SwiftPM", isDirectory: true)
    }

    /// fudge's own settings.
    /// The certificates the Mac trusts, for a Node without `--use-system-ca` (`NodeTrust`).
    public var trustRootsFile: URL {
        supportDirectory.appendingPathComponent("trust/roots.pem")
    }

    public var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// The calculator's exchange rates, downloaded from the European Central Bank while that's turned on.
    public var exchangeRatesFile: URL {
        supportDirectory.appendingPathComponent("exchange-rates.json")
    }

    /// When Fudge last checked GitHub for a new release, and what it found (`UpdateCheckState`).
    public var updateCheckFile: URL {
        supportDirectory.appendingPathComponent("update-check.json")
    }

    /// How often and how recently root items were opened.
    public var historyFile: URL {
        supportDirectory.appendingPathComponent("history.json")
    }

    /// The values of search bar dropdowns that ask for theirs to be kept (`storeValue`).
    public var dropdownValuesFile: URL {
        supportDirectory.appendingPathComponent("dropdown-values.json")
    }

    /// The values of Form fields with `storeValue`, one file per extension.
    public var formValuesDirectory: URL {
        supportDirectory.appendingPathComponent("form-values", isDirectory: true)
    }

    /// Which extensions the user allowed to open other extensions' commands (`launchCommand`).
    public var launchPermissionsFile: URL {
        supportDirectory.appendingPathComponent("launch-permissions.json")
    }

    /// Which onboarding steps the user has answered (`Onboarding`).
    public var onboardingFile: URL {
        supportDirectory.appendingPathComponent("onboarding.json")
    }

    /// What commands changed about themselves with `updateCommandMetadata` (`CommandMetadata`).
    public var commandMetadataFile: URL {
        supportDirectory.appendingPathComponent("command-metadata.json")
    }

    /// The menu-bar commands the user activated (`MenuBarStore`).
    public var menuBarFile: URL {
        supportDirectory.appendingPathComponent("menu-bar.json")
    }

    /// The user's quicklinks (`QuicklinkStore`).
    public var quicklinksFile: URL {
        supportDirectory.appendingPathComponent("quicklinks.json")
    }

    /// The user's snippets (`SnippetStore`).
    public var snippetsFile: URL {
        supportDirectory.appendingPathComponent("snippets.json")
    }

    /// Recent Colors (`RecentColorStore`).
    public var colorsFile: URL {
        supportDirectory.appendingPathComponent("colors.json")
    }

    /// The user's custom window positions and saved layouts (`WindowLayoutStore`).
    public var windowLayoutsFile: URL {
        supportDirectory.appendingPathComponent("window-layouts.json")
    }

    /// The preference values set for each extension.
    public var preferencesDirectory: URL {
        supportDirectory.appendingPathComponent("preferences", isDirectory: true)
    }

    /// An extension's own folder for files it keeps (`environment.supportPath`).
    public func supportDirectory(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("extension-data/\(name)", isDirectory: true)
    }

    /// Where an extension's `Cache` lives.
    public func cacheDirectory(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("cache/\(name)", isDirectory: true)
    }

    /// Where an extension's `LocalStorage` lives.
    public func localStorageFile(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("local-storage/\(name).json")
    }

    /// The https images extensions showed, kept by `RemoteImageCache`.
    public var imageCacheDirectory: URL {
        supportDirectory.appendingPathComponent("image-cache", isDirectory: true)
    }

    /// Installed extensions, one folder each.
    /// The before-import backups (`Backup.apply`): plain archives of the state an import replaced.
    public var backupsDirectory: URL {
        supportDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public var extensionsDirectory: URL {
        supportDirectory.appendingPathComponent("extensions", isDirectory: true)
    }
}
