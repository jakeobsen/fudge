import Foundation

/// Whether fudge starts at login, as macOS reports it (`SMAppService.Status`).
public enum LoginItemStatus: String, Sendable, Equatable, CaseIterable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// fudge as a login item: `SMAppService.mainApp` in the app, a fake in tests and snapshots, which must never
/// register the real app.
@MainActor
public protocol LoginItem: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings → General → Login Items.
    func openSystemSettings()
}

/// What the General page's Open at Login switch shows. It follows the system's real status, never a stored value,
/// so a change made in System Settings shows too.
public struct LoginItemState: Sendable, Equatable {
    public var isOn: Bool
    /// A line under the switch, when the user has more to do.
    public var note: String?
    /// Whether to offer a button that opens System Settings' Login Items.
    public var offersLoginItemsSettings: Bool

    public static let approvalNote = "Allow Fudge in System Settings → General → Login Items"

    public init(_ status: LoginItemStatus) {
        switch status {
        case .enabled:
            self.init(isOn: true, note: nil, offersLoginItemsSettings: false)
        case .requiresApproval:
            self.init(isOn: true, note: Self.approvalNote, offersLoginItemsSettings: true)
        case .notRegistered, .notFound:
            self.init(isOn: false, note: nil, offersLoginItemsSettings: false)
        }
    }

    public init(isOn: Bool, note: String?, offersLoginItemsSettings: Bool) {
        self.isOn = isOn
        self.note = note
        self.offersLoginItemsSettings = offersLoginItemsSettings
    }

    /// Turns `item` on (`register()`) or off (`unregister()`), then reads its real state back, whether that
    /// worked or not. A failure comes back as the message to show under the switch. Turning it on while Fudge runs
    /// from somewhere that goes away (`AppLocation.loginItemRefusal`) registers nothing and says why instead.
    @MainActor
    public static func change(_ item: any LoginItem, to on: Bool, location: AppLocation = .installed)
        -> (state: LoginItemState, error: String?)
    {
        if on, let refusal = location.loginItemRefusal {
            return (LoginItemState(item.status), refusal)
        }
        var error: String?
        do {
            if on { try item.register() } else { try item.unregister() }
        } catch let failure {
            error = failure.localizedDescription
        }
        return (LoginItemState(item.status), error)
    }
}
