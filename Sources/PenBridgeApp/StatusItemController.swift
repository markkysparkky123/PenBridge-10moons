import AppKit
import CoreGraphics
import TabletCore

/// The menu-bar presence: current status, the switches worth reaching quickly,
/// and a way out.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let engine: TabletDriverEngine
    private let suppressor: ExpressKeySuppressor
    /// What the suppressor has discarded, shown in the menu so the feature is visibly
    /// doing something rather than indistinguishable from a button that does nothing.
    private var suppressedCount = 0
    private var lastSuppressed: String?
    private var settings: Settings {
        didSet {
            engine.settings = settings
            try? settings.save()
            rebuildMenu()
        }
    }

    init(engine: TabletDriverEngine, suppressor: ExpressKeySuppressor) {
        self.engine = engine
        self.suppressor = suppressor
        self.settings = engine.settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.button?.image = NSImage(
            systemSymbolName: "pencil.and.outline", accessibilityDescription: "PenBridge"
        )
        statusItem.button?.image?.isTemplate = true

        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.render(state) }
        }
        suppressor.onSuppressed = { [weak self] key in
            guard let self else { return }
            self.suppressedCount += 1
            self.lastSuppressed = key
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

        let login = NSMenuItem(
            title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: ""
        )
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.isBlockedByUser {
            login.title = "Start at login — needs approval"
        }
        menu.addItem(login)

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

        let suppress = NSMenuItem(
            title: "Ignore the tablet's own buttons",
            action: #selector(toggleSuppressExpressKeys), keyEquivalent: ""
        )
        suppress.target = self
        suppress.state = settings.suppressExpressKeys ? .on : .off
        suppress.toolTip = """
            The tablet's buttons send fixed keyboard shortcuts from firmware, and macOS \
            acts on them before this driver sees anything. Discarding them is the first \
            step towards putting your own actions on those buttons. It works by watching \
            keystrokes and dropping the ones a tablet button just caused — so it is off \
            until you ask for it.
            """
        menu.addItem(suppress)

        if settings.suppressExpressKeys {
            let detail = suppressedCount == 0
                ? "    nothing discarded yet — press a tablet button"
                : "    discarded \(suppressedCount), last: \(lastSuppressed ?? "—")"
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

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
        let reannounce = NSMenuItem(
            title: "Re-announce pen to applications",
            action: #selector(reannouncePen), keyEquivalent: ""
        )
        reannounce.target = self
        reannounce.toolTip = """
            Withdraws the pen and presents it again. An application that started at an \
            awkward moment can end up believing no tablet is attached, and ignore \
            pressure until it is told otherwise. This is the polite version of \
            unplugging the tablet.
            """
        menu.addItem(reannounce)

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

    @objc private func toggleLoginItem() {
        let wantsEnabled = !LoginItem.isEnabled
        let error = LoginItem.setEnabled(wantsEnabled)
        if error != nil || LoginItem.isBlockedByUser {
            LoginItem.presentFailure(error, wasEnabling: wantsEnabled)
        }
        rebuildMenu()
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

    @objc private func toggleSuppressExpressKeys() {
        settings.suppressExpressKeys.toggle()
        if settings.suppressExpressKeys {
            suppressor.start()
            if !suppressor.isRunning {
                settings.suppressExpressKeys = false
                let alert = NSAlert()
                alert.messageText = "Could not watch the keyboard"
                alert.informativeText = """
                    Creating the event tap failed. This needs Accessibility permission, \
                    which is the same grant the pen uses to move the cursor.
                    """
                alert.runModal()
            }
        } else {
            suppressor.stop()
        }
    }

    @objc private func selectRotation(_ sender: NSMenuItem) {
        settings.rotation = TabletRotation.allCases[sender.tag]
    }

    @objc private func selectPressure(_ sender: NSMenuItem) {
        settings.pressure = [PressureCurve.soft, .linear, .firm][sender.tag]
    }

    @objc private func reannouncePen() {
        engine.frontmostApplicationChanged()
    }

    @objc private func fixPermissions() {
        Permissions.presentMissingAlert()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}
