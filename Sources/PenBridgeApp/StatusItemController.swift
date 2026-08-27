import AppKit
import CoreGraphics
import TabletCore

/// The menu-bar presence: current status, the switches worth reaching quickly,
/// and a way out.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let engine: TabletDriverEngine
    private var settings: Settings {
        didSet {
            engine.settings = settings
            try? settings.save()
            rebuildMenu()
        }
    }

    init(engine: TabletDriverEngine) {
        self.engine = engine
        self.settings = engine.settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.button?.image = NSImage(
            systemSymbolName: "pencil.and.outline", accessibilityDescription: "PenBridge"
        )
        statusItem.button?.image?.isTemplate = true

        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.render(state) }
        }
        rebuildMenu()
    }

    private func render(_ state: TabletDriverEngine.State) {
        // A dimmed icon is the quickest way to show at a glance that nothing is connected.
        statusItem.button?.appearsDisabled = {
            if case .running = state { return false }
            return true
        }()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status: String
        switch engine.state {
        case .running(let tablet): status = tablet
        case .waitingForTablet: status = "No tablet connected"
        case .disabled: status = "Disabled"
        }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !Permissions.allGranted {
            menu.addItem(.separator())
            let warning = NSMenuItem(
                title: "⚠︎ Missing permissions — click to fix",
                action: #selector(fixPermissions), keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.isEnabled ? .on : .off
        menu.addItem(enabled)

        let proportions = NSMenuItem(
            title: "Preserve proportions", action: #selector(toggleProportions), keyEquivalent: ""
        )
        proportions.target = self
        proportions.state = settings.preserveAspectRatio ? .on : .off
        menu.addItem(proportions)

        let barrel = NSMenuItem(
            title: "Barrel button right-clicks", action: #selector(toggleBarrel), keyEquivalent: ""
        )
        barrel.target = self
        barrel.state = settings.barrelSwitchRightClicks ? .on : .off
        menu.addItem(barrel)

        let seize = NSMenuItem(
            title: "Take exclusive control of the tablet",
            action: #selector(toggleSeize), keyEquivalent: ""
        )
        seize.target = self
        seize.state = settings.seizeDevice ? .on : .off
        seize.toolTip = """
            Stops macOS's own driver from generating plain mouse events from the same \
            pen. Drawing applications that see ordinary mouse movement arrive in the \
            middle of a stroke fall back to treating the pen as a mouse and ignore \
            pressure. While this is on, the tablet does nothing if PenBridge is not \
            running.
            """
        menu.addItem(seize)

        menu.addItem(.separator())
        menu.addItem(submenu(
            title: "Rotation",
            options: TabletRotation.allCases.map { ("\($0.rawValue)°", $0) },
            isSelected: { $0 == self.settings.rotation },
            action: #selector(selectRotation(_:))
        ))
        menu.addItem(submenu(
            title: "Pen feel",
            options: [("Soft", PressureCurve.soft), ("Linear", .linear), ("Firm", .firm)],
            isSelected: { $0 == self.settings.pressure },
            action: #selector(selectPressure(_:))
        ))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PenBridge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func submenu<T>(
        title: String,
        options: [(String, T)],
        isSelected: (T) -> Bool,
        action: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.0, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = isSelected(option.1) ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func toggleProportions() {
        settings.preserveAspectRatio.toggle()
    }

    @objc private func toggleBarrel() {
        settings.barrelSwitchRightClicks.toggle()
    }

    @objc private func toggleSeize() {
        settings.seizeDevice.toggle()
    }

    @objc private func selectRotation(_ sender: NSMenuItem) {
        settings.rotation = TabletRotation.allCases[sender.tag]
    }

    @objc private func selectPressure(_ sender: NSMenuItem) {
        settings.pressure = [PressureCurve.soft, .linear, .firm][sender.tag]
    }

    @objc private func fixPermissions() {
        Permissions.presentMissingAlert()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}
