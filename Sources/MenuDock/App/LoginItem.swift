import Foundation
import OSLog
import ServiceManagement

/// Launch-at-login, via `SMAppService`.
///
/// The modern replacement for `SMLoginItemSetEnabled` and its separate helper bundle: the
/// main app registers itself, and macOS surfaces it in System Settings › General ›
/// Login Items where the user can override us. That override is authoritative — which is why
/// ``isEnabled`` reads live status rather than caching a preference we wrote.
enum LoginItem {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                    category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when the user disabled us in System Settings; we cannot re-enable
    /// programmatically and must send them there.
    static var requiresUserApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Could not \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
            return false
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
