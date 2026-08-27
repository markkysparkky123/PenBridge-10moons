import AppKit
import ServiceManagement

/// Registration as a login item, so the tablet works after a restart without the
/// driver having to be started by hand.
///
/// `SMAppService` replaces the old practice of writing a LaunchAgent plist into
/// `~/Library/LaunchAgents`. That approach leaves a file pointing at a path, and the
/// file outlives the app: the vendor driver this project replaces left behind
/// `com.pingit.MyTabletDaemon.plist` pointing at a binary that no longer exists.
/// A registration is tied to the app bundle instead, and macOS shows it in
/// System Settings where the user can turn it off.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user disabled the registration in System Settings. macOS will not
    /// let the app re-register in that state, so the difference is worth reporting
    /// rather than silently failing.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }

    /// Explains the two ways this can fail, both of which look like the checkbox
    /// refusing to stay ticked.
    @MainActor
    static func presentFailure(_ error: Error?, wasEnabling: Bool) {
        let alert = NSAlert()
        if isBlockedByUser {
            alert.messageText = "Login item needs approval"
            alert.informativeText = """
                macOS is holding this registration for approval. Enable PenBridge under \
                Login Items in System Settings, and it will start with you from then on.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
                )
            }
            return
        }

        alert.messageText = wasEnabling
            ? "Could not set PenBridge to start at login"
            : "Could not stop PenBridge starting at login"
        alert.informativeText = error?.localizedDescription
            ?? "macOS did not say why."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
