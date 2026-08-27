import AppKit
import ApplicationServices
import IOKit.hid

/// The two privacy grants this driver cannot work without.
///
/// Neither one fails loudly: without Input Monitoring the HID callback simply never
/// fires, and without Accessibility the synthesized events are silently dropped. Both
/// look identical from the user's side — "the tablet does nothing" — so the app checks
/// them up front and says which is missing.
enum Permissions {

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static var allGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    /// Triggers the system prompts. Both only appear once per app identity; afterwards
    /// the user has to visit System Settings, which is what `openSettings` is for.
    static func request() {
        if inputMonitoring == .notDetermined {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if accessibility != .granted {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )
        }
    }

    enum Pane: String {
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// Explains what is missing and takes the user straight to the right pane.
    @MainActor
    static func presentMissingAlert() {
        var missing: [(String, Pane)] = []
        if inputMonitoring != .granted {
            missing.append(("Input Monitoring — to read the pen", .inputMonitoring))
        }
        if accessibility != .granted {
            missing.append(("Accessibility — to move the cursor", .accessibility))
        }
        guard let first = missing.first else { return }

        let alert = NSAlert()
        alert.messageText = "PenBridge needs permission to control the tablet"
        alert.informativeText = """
            Still to grant:

            \(missing.map { "• \($0.0)" }.joined(separator: "\n"))

            Add PenBridge in System Settings, then quit and reopen it — macOS only \
            applies these grants to a freshly launched app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            openSettings(first.1)
        }
    }
}
