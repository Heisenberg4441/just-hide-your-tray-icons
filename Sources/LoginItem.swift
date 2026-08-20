import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` so the menu does not have to care about the
/// difference between "not registered", "registered but switched off by the
/// user in System Settings", and the errors that come out of registering an app
/// living somewhere macOS is unhappy about.
enum LoginItem {

    /// Whether macOS will actually launch us. Drives the checkmark.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether a registration exists at all. Toggling has to key off this
    /// rather than off `isEnabled`: right after a successful `register()` the
    /// status can still read `.requiresApproval`, and treating that as "off"
    /// makes the next click register a second time instead of undoing it.
    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// Registered, but the user has the switch off in System Settings — we
    /// cannot flip that back on from here, only point at it.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(SMAppService.mainApp.status.rawValue))"
        }
    }

    /// Returns nil on success, or a message worth showing the user.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if needsApproval {
                    return "Turn JustHide on under System Settings › General › Login Items."
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
