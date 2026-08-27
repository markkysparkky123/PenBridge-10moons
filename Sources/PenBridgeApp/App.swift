import AppKit
import CoreGraphics
import TabletCore

/// Menu-bar host for the driver engine.
///
/// There is no window and no dock icon: the app is a background service with a status
/// item, which is what `LSUIElement` in the bundle's Info.plist declares.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var engine: TabletDriverEngine?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.request()

        let engine = TabletDriverEngine()
        self.engine = engine
        self.statusItem = StatusItemController(engine: engine)
        engine.start()

        // Plugging in a monitor or changing resolution invalidates the screen
        // geometry the mapper was built against.
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())

        if !Permissions.allGranted {
            Permissions.presentMissingAlert()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    fileprivate func reconfigureDisplays() {
        engine?.displayConfigurationChanged()
    }
}

private func displayReconfigured(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context, !flags.contains(.beginConfigurationFlag) else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in delegate.reconfigureDisplays() }
}

@main
enum PenBridgeApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        // `NSApplication.delegate` is a weak reference, so the delegate has to be held
        // for the lifetime of the run loop.
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
