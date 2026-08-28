import AppKit
import CoreGraphics
import TabletCore

/// The menu-bar presence: current status, the switches worth reaching quickly,
/// and a way out.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    /// One menu for the lifetime of the app, refilled just before it opens. Rebuilding it
    /// on every change instead would leave the discard counter showing whatever it read
    /// last, which for a feature whose whole job is invisible is the wrong thing to show.
    private let menu = NSMenu()
    private let engine: TabletDriverEngine
    private let suppressor: ExpressKeySuppressor
    /// What the suppressor has discarded, shown in the menu so the feature is visibly
    /// doing something rather than indistinguishable from a button that does nothing.
    private var suppressedCount = 0
    private var lastSuppressed: String?
    /// Called when a change needs the event tap started or stopped. The tap is the app's
    /// business, not the menu's.
    var onBindingsChanged: ((Settings) -> Void)?
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
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        statusItem.button?.image = NSImage(
            systemSymbolName: "pencil.and.outline", accessibilityDescription: "PenBridge"
        )
        statusItem.button?.image?.isTemplate = true

        engine.onStateChange = { [weak self] state in
            // Set outside the hop to the main actor: the suppressor's tap runs on the
            // main run loop and must never be left believing a tablet is attached after
            // it has gone, however briefly.
            suppressor.isTabletConnected = state != .waitingForTablet
            Task { @MainActor in self?.render(state) }
        }
        suppressor.isTabletConnected = engine.state != .waitingForTablet
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

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

        menu.addItem(penButtonsItem())

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
            The tablet's buttons send fixed shortcuts from firmware — keystrokes from the \
            side buttons, scrolling and media keys from the rest — and macOS acts on them \
            before this driver sees anything. Discarding them is the first step towards \
            putting your own actions on those buttons. It works by watching input and \
            dropping the events a tablet button just caused — so it is off until you ask \
            for it.
            """
        menu.addItem(suppress)

        if settings.suppressExpressKeys {
            // The tap can fail to start — it needs Accessibility — and at launch there is
            // nobody to show an alert to. Saying so here is the difference between a
            // feature that is off and one that is broken.
            let detail: String
            if !suppressor.isRunning {
                detail = "    not watching — needs Accessibility"
            } else if suppressedCount == 0 {
                detail = "    nothing discarded yet — press a tablet button"
            } else {
                detail = "    discarded \(suppressedCount), last: \(lastSuppressed ?? "—")"
            }
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
    }

    /// The pen's side buttons, and what each should do.
    ///
    /// Not a barrel-switch toggle, which is what this used to be. On the hardware this was
    /// written for the pen's buttons do not touch the barrel-switch bit at all — they send
    /// keystrokes, indistinguishable in the report from the buttons on the case. A toggle
    /// for a bit the tablet never sets looks broken however correct its code, so the menu
    /// now offers what the buttons actually are.
    private func penButtonsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Pen buttons", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard
            let tablet = engine.connectedTablet,
            let pen = KnownTablets.penButtons(vendorID: tablet.vendorID, productID: tablet.productID)
        else {
            // Which keystroke a pen button sends cannot be read off the descriptor; it has
            // to be measured once per model. Saying so is better than offering settings
            // that would silently bind the wrong button.
            let unknown = NSMenuItem(
                title: engine.connectedTablet == nil
                    ? "No tablet connected"
                    : "Not measured for this tablet — run `penbridge-cli buttons`",
                action: nil, keyEquivalent: ""
            )
            unknown.isEnabled = false
            menu.addItem(unknown)
            parent.submenu = menu
            return parent
        }

        for (index, entry) in [("+ button", pen.plus), ("− button", pen.minus)].enumerated() {
            let item = NSMenuItem(title: entry.0, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.autoenablesItems = false
            let current = settings.action(for: entry.1)
            for (offset, action) in ButtonAction.allCases.enumerated() {
                let choice = NSMenuItem(
                    title: action.title, action: #selector(selectPenButtonAction(_:)), keyEquivalent: ""
                )
                choice.target = self
                // Two coordinates through one tag: which button, and which action.
                choice.tag = index * 100 + offset
                choice.state = action == current ? .on : .off
                actions.addItem(choice)
            }
            item.submenu = actions
            menu.addItem(item)
        }

        parent.submenu = menu
        return parent
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

    @objc private func selectPenButtonAction(_ sender: NSMenuItem) {
        guard
            let tablet = engine.connectedTablet,
            let pen = KnownTablets.penButtons(vendorID: tablet.vendorID, productID: tablet.productID)
        else { return }

        let source = sender.tag / 100 == 0 ? pen.plus : pen.minus
        let action = ButtonAction.allCases[sender.tag % 100]
        settings.bind(source, to: action)
        // Binding a button needs the tap even when blanket suppression is off, and
        // unbinding the last one lets it go again.
        onBindingsChanged?(settings)
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
