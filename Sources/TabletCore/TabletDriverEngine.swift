import CoreGraphics
import Foundation

/// Ties the pieces together: HID reports in, screen events out.
public final class TabletDriverEngine {

    public enum State: Equatable, Sendable {
        case waitingForTablet
        case running(tablet: String)
        case disabled
    }

    /// Called whenever the state changes, on an arbitrary thread.
    public var onStateChange: ((State) -> Void)?

    /// Called for each press or release of the tablet's own buttons, on the HID thread.
    ///
    /// Reported whether or not the driver acts on them: knowing a button was pressed,
    /// before macOS turns it into a keystroke, is what lets that keystroke be
    /// recognised afterwards.
    public var onExpressKey: ((ExpressKeyEvent) -> Void)?

    public private(set) var state: State = .waitingForTablet {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public var settings: Settings {
        didSet { rebuildMapping() }
    }

    private let monitor: TabletDeviceMonitor
    private var device: TabletDevice?
    private var synthesizer: TabletEventSynthesizer?
    private var mapper: AreaMapper?

    public init(settings: Settings = .load()) {
        self.settings = settings
        self.monitor = TabletDeviceMonitor()
        self.monitor.seizeDevice = settings.seizeDevice

        monitor.onAttach = { [weak self] device in self?.attach(device) }
        monitor.onDetach = { [weak self] device in self?.detach(device) }
        monitor.onReport = { [weak self] device, reportID, payload in
            self?.process(device: device, reportID: reportID, payload: payload)
        }
    }

    public func start() {
        monitor.start()
    }

    public func stop() {
        synthesizer?.reset()
        monitor.stop()
    }

    /// Screen geometry changes when displays are plugged in or resolution changes.
    public func displayConfigurationChanged() {
        rebuildMapping()
    }

    /// Re-announce the pen to the application that just came to the front, which
    /// otherwise has no way of knowing a tablet is connected. See
    /// `TabletEventSynthesizer.refreshProximity()`.
    public func frontmostApplicationChanged() {
        synthesizer?.refreshProximity()
    }

    // MARK: - Device lifecycle

    private func attach(_ device: TabletDevice) {
        guard self.device == nil else { return }
        self.device = device

        var configuration = TabletEventSynthesizer.Configuration()
        configuration.barrelSwitchRightClicks = settings.barrelSwitchRightClicks
        // Only advertise tilt if the hardware actually reports it. Claiming a
        // capability the device lacks makes applications show controls that do nothing.
        if device.layout.hasTilt {
            configuration.capabilities.insert([.tiltX, .tiltY])
        }

        synthesizer = TabletEventSynthesizer(
            vendorID: device.vendorID, productID: device.productID, configuration: configuration
        )
        rebuildMapping()
        state = settings.isEnabled ? .running(tablet: device.name) : .disabled
    }

    private func detach(_ device: TabletDevice) {
        guard self.device === device else { return }
        synthesizer?.reset()
        synthesizer = nil
        mapper = nil
        self.device = nil
        state = .waitingForTablet
    }

    private func rebuildMapping() {
        guard let device else { return }

        let displayID = settings.displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        // A display that has gone away reports an empty rect; fall back to the main one.
        let screen = bounds.isEmpty ? CGDisplayBounds(CGMainDisplayID()) : bounds

        // The chosen area says which part of the tablet to use; preserving proportions
        // then trims inside it. Two independent choices, applied in that order.
        let area = settings.preserveAspectRatio
            ? AreaMapper.proportionalArea(
                layout: device.layout, screen: screen,
                rotation: settings.rotation, within: settings.area.cgRect
            )
            : settings.area.cgRect

        mapper = AreaMapper(area: area, rotation: settings.rotation, screen: screen)
        synthesizer?.configuration.barrelSwitchRightClicks = settings.barrelSwitchRightClicks
        monitor.seizeDevice = settings.seizeDevice

        if case .running = state, !settings.isEnabled {
            synthesizer?.reset()
            state = .disabled
        } else if case .disabled = state, settings.isEnabled {
            state = .running(tablet: device.name)
        }
    }

    // MARK: - Report processing

    private func process(device: TabletDevice, reportID: UInt8, payload: [UInt8]) {
        if let keys = device.expressKeys, reportID == keys.reportID,
           let event = keys.decode(payload) {
            onExpressKey?(event)
            return
        }

        guard
            settings.isEnabled,
            reportID == device.layout.reportID,
            let synthesizer, let mapper,
            let report = device.layout.decode(payload)
        else { return }

        let location = mapper.map(
            x: report.x, y: report.y,
            xRange: settings.calibration.xRange(orDeclared: device.layout.xRange),
            yRange: settings.calibration.yRange(orDeclared: device.layout.yRange)
        )
        let pressure = settings.pressure.apply(report.pressure, range: device.layout.pressureRange)
        synthesizer.handle(report, at: location, pressure: pressure)
    }
}
