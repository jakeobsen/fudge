import Foundation

/// Where the running app is, for the offer to move it to Applications at launch (SPEC-114 §1). Opened straight from
/// the mounted disk image, Fudge works until the image is ejected; opened from Downloads, macOS runs it from a random
/// read-only copy (App Translocation) that's gone after a restart. Either way Open at Login would point at an app
/// that disappears, so both are offered the move, and neither may become a login item.
public enum AppLocation: Equatable, Sendable {
    /// Somewhere it can stay: Applications, a build folder, anywhere writable.
    case installed
    /// A read-only volume: the mounted disk image.
    case diskImage
    /// App Translocation's read-only copy of a quarantined download.
    case translocated

    /// Where it is, from the bundle's path and whether its volume is read-only. Pure, so it's tested without either.
    public init(bundlePath: String, isOnReadOnlyVolume: Bool) {
        // macOS mounts a translocated app at …/AppTranslocation/<UUID>/d/<name>.app, itself read-only.
        if bundlePath.split(separator: "/").contains("AppTranslocation") {
            self = .translocated
        } else if isOnReadOnlyVolume {
            self = .diskImage
        } else {
            self = .installed
        }
    }

    /// Whether launch offers to move Fudge to Applications.
    public var offersMove: Bool { self != .installed }

    /// The alert's title.
    public static let moveTitle = "Move Fudge to Applications?"

    /// The alert's text, saying why.
    public var moveMessage: String? {
        switch self {
        case .installed:
            nil
        case .diskImage:
            "Fudge is running from its disk image, so it stops working when the image is ejected, and can't open at "
                + "login. Move it to Applications to keep it."
        case .translocated:
            "Fudge is running from a temporary copy macOS made of your download, so it can't open at login. Move it to "
                + "Applications to keep it."
        }
    }

    /// Why Open at Login can't be turned on from here, or nil when it can.
    public var loginItemRefusal: String? {
        offersMove ? "Move Fudge to Applications first, so it can open at login." : nil
    }

    /// Where the move puts the app: `/Applications/<name>.app`, or, for a user who can't add apps there (a standard
    /// account), the Applications folder in their home folder. Fudge never asks for an administrator's password.
    public static func destination(
        for bundle: URL, applicationsWritable: Bool, home: URL,
        applications: URL = URL(fileURLWithPath: "/Applications")
    ) -> URL {
        let folder =
            applicationsWritable ? applications : home.appendingPathComponent("Applications", isDirectory: true)
        return folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
    }

    /// The alert's text, saying why, and where the app goes when that isn't `/Applications`.
    public func moveMessage(destination: URL, applications: URL = URL(fileURLWithPath: "/Applications")) -> String? {
        guard let message = moveMessage else { return nil }
        guard destination.deletingLastPathComponent().standardizedFileURL != applications.standardizedFileURL else {
            return message
        }
        return message
            + " This account can't add apps to /Applications, so it goes to Applications in your home folder."
    }

    /// The argument a moved copy is opened with, so it knows it was just moved.
    public static let movedArgument = "--moved-to-applications"

    /// What launch does: nothing, the offer, or, for a copy opened right after a move that still runs from a
    /// read-only place (macOS translocated it again), say so once instead of offering the move in a loop.
    public enum LaunchStep: Equatable, Sendable {
        case nothing
        case offer
        case stillNotMoved
    }

    public func launchStep(arguments: [String]) -> LaunchStep {
        guard offersMove else { return .nothing }
        return arguments.contains(Self.movedArgument) ? .stillNotMoved : .offer
    }

    public static let stillNotMovedMessage =
        "Fudge was copied to Applications, but macOS still runs it from a temporary copy. Open it from Applications in "
        + "Finder."
}
