import FudgeCore
import ServiceManagement

/// fudge itself as a login item, through `SMAppService.mainApp`. Only the real app uses it: snapshots get a
/// `FixedLoginItem`, so they never register anything.
@MainActor
final class SMAppServiceLoginItem: LoginItem {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// A login item that only remembers its status: for snapshots, which never touch the system.
@MainActor
final class FixedLoginItem: LoginItem {
    var status: LoginItemStatus

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettings() {}
}
