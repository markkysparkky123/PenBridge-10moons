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
    private let suppressor = ExpressKeySuppressor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.request()

        let engine = TabletDriverEngine()
        self.engine = engine

        // The suppressor needs to know a tablet button was pressed before macOS turns
        // it into a keystroke or a scroll, which is the whole basis for telling the
        // tablet's input apart from the user's own.
        engine.onTabletButton = { [weak self] event in
            self?.suppressor.note(event)
        }
        let statusItem = StatusItemController(engine: engine, suppressor: suppressor)
        statusItem.onBindingsChanged = { [weak self] settings in
            self?.applyExpressKeySuppression(settings)
        }
        self.statusItem = statusItem
        engine.start()
        applyExpressKeySuppression(engine.settings)

        // Plugging in a monitor or changing resolution invalidates the screen
        // geometry the mapper was built against.
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())

        // An application only learns that a tablet exists from a proximity event, and
        // those are posted when the pen enters the sensing range — long before the
        // application the user is about to switch to has launched. Re-announce the pen
        // every time the front application changes, or the first app they open after
        // picking up the pen will treat it as a mouse.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.engine?.frontmostApplicationChanged()
        }

        if !Permissions.allGranted {
            // Deferred deliberately. Running a modal alert inside
            // applicationDidFinishLaunching blocks the main thread before the app has
            // checked in with LaunchServices, which times out and reports the launch as
            // failed (-1712) — the app appears not to start at all, and the dialog
            // explaining why is the very thing preventing it.
            DispatchQueue.main.async { Permissions.presentMissingAlert() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        suppressor.stop()
        engine?.stop()
    }

    /// Starts or stops the event tap to match the settings. Kept here rather than in the
    /// engine because it is a decision about the user's keyboard, not about the tablet.
    ///
    /// The tap is needed for a bound button as much as for the blanket switch: remapping
    /// a button means swallowing what it sent and sending something else, and the first
    /// half of that is the same machinery.
    func applyExpressKeySuppression(_ settings: Settings) {
        suppressor.action = { [weak self] source in
            self?.engine?.settings.action(for: source) ?? .passThrough
        }
        if settings.needsEventTap {
            suppressor.start()
        } else {
            suppressor.stop()
        }
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
