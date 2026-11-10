import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`, which is the only supported way for an app to
/// register itself as a login item without a helper bundle.
///
/// This matters more here than for a typical menu bar app: the visibility
/// restriction is bound to this process's connection to MenuBarAgent, so when
/// the app is not running, everything it was hiding comes back. Autostart is
/// what makes the setting survive a reboot.
enum LaunchAtLogin {

    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a description of what went wrong.
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else { return "Not running from an app bundle." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
