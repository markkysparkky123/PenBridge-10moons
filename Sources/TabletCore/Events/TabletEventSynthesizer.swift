import CoreGraphics
import Foundation

/// Bits of the tablet capability mask (`NX_TABLET_CAPABILITY_*` in `IOLLEvent.h`).
///
/// Drawing applications read this mask out of the proximity event to decide what the
/// tablet can do. An app that finds the pressure bit clear will treat every stroke as
/// full pressure no matter what the point events carry, which is exactly how a driver
/// ends up "working" while pressure silently does nothing.
public struct TabletCapability: OptionSet, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    public static let deviceID = TabletCapability(rawValue: 0x0001)
    public static let absoluteX = TabletCapability(rawValue: 0x0002)
    public static let absoluteY = TabletCapability(rawValue: 0x0004)
    public static let vendor1 = TabletCapability(rawValue: 0x0008)
    public static let vendor2 = TabletCapability(rawValue: 0x0010)
    public static let vendor3 = TabletCapability(rawValue: 0x0020)
    public static let buttons = TabletCapability(rawValue: 0x0040)
    public static let tiltX = TabletCapability(rawValue: 0x0080)
    public static let tiltY = TabletCapability(rawValue: 0x0100)
    public static let absoluteZ = TabletCapability(rawValue: 0x0200)
    public static let pressure = TabletCapability(rawValue: 0x0400)
    public static let tangentialPressure = TabletCapability(rawValue: 0x0800)
    public static let orientation = TabletCapability(rawValue: 0x1000)
    public static let rotation = TabletCapability(rawValue: 0x2000)
}

/// `NX_TABLET_POINTER_*`.
private enum PointerType: Int64 {
    case unknown = 0
    case pen = 1
    case cursor = 2
    case eraser = 3
}

/// `NX_SUBTYPE_TABLET_*` values for the `mouseEventSubtype` field.
private enum MouseSubtype: Int64 {
    case tabletPoint = 1
    case tabletProximity = 2
}

/// Turns decoded pen samples into the Core Graphics events macOS applications consume.
///
/// The contract that matters, and the part that is easy to get subtly wrong:
///
/// * A proximity event must be posted when the pen enters the sensing range, *before*
///   any point events, and again when it leaves.
/// * The `deviceID` carried by every point event has to equal the `deviceID` announced
///   in that proximity event. An application tracks the tool by this identifier; if the
///   two disagree it sees pressure arriving for a tool it never saw appear, and ignores it.
/// * Point data rides on ordinary mouse events tagged with the tablet subtype. That is
///   the path AppKit turns into `NSEvent.pressure` and friends.
public final class TabletEventSynthesizer {

    public struct Configuration: Sendable {
        /// Send the barrel switch as a right-click rather than as tablet button 2 only.
        public var barrelSwitchRightClicks: Bool = true
        /// Capabilities announced to applications.
        public var capabilities: TabletCapability = [
            .deviceID, .absoluteX, .absoluteY, .buttons, .pressure,
        ]
        public init() {}
    }

    public var configuration: Configuration

    private let source: CGEventSource?
    private let vendorID: Int64
    private let productID: Int64
    /// Identifies this tablet to applications for the lifetime of the connection.
    private let deviceID: Int64

    private var isInProximity = false
    /// Whether this synthesizer has announced the pen at all yet.
    ///
    /// A previous run of the driver may have exited without withdrawing the pen —
    /// killed, crashed, or simply quit while the pen was away from the tablet. Any
    /// application still running holds a registration for a device that no longer has
    /// anything behind it, and treats the fresh "entered" as a duplicate.
    private var hasAnnounced = false
    private var currentTool: PenTool = .pen
    private var isTipDown = false
    private var isBarrelDown = false
    private var lastLocation = CGPoint.zero
    private var lastPressure = 0.0

    public init(vendorID: Int, productID: Int, configuration: Configuration = Configuration()) {
        self.vendorID = Int64(vendorID)
        self.productID = Int64(productID)
        self.configuration = configuration
        self.source = CGEventSource(stateID: .hidSystemState)

        // Without this, macOS briefly ignores the physical mouse after each synthetic
        // event, which shows up as a cursor that stutters when both are in use.
        self.source?.localEventsSuppressionInterval = 0

        // Any stable non-zero value works; applications only compare it for equality.
        self.deviceID = Int64(truncatingIfNeeded: (vendorID << 16) | productID) & 0xFFFF
    }

    /// Feeds one decoded sample through the state machine and posts whatever it implies.
    public func handle(_ report: PenReport, at location: CGPoint, pressure: Double) {
        if report.inRange && !isInProximity {
            currentTool = report.tool
            // Every approach of the pen is announced as a complete leave/enter cycle,
            // not just the first one.
            //
            // An application only ever learns about the pen from these events, and it
            // can start at any moment: between two strokes, while the pen rests beside
            // the tablet, long after the driver did. Sending a bare "entered" reaches
            // only those that happened to be listening for the matching "left" earlier;
            // anything launched since is left holding a registration it never saw
            // withdrawn, and treats the arrival as a duplicate.
            //
            // A withdrawal nobody is registered for is ignored, so the extra event
            // costs nothing and removes the need to reason about who started when.
            postProximity(entering: false, tool: currentTool, at: location)
            hasAnnounced = true
            postProximity(entering: true, tool: currentTool, at: location)
            isInProximity = true
        }

        // Flipping the pen over mid-hover is a tool change: the old tool leaves
        // proximity and the new one enters, or apps keep drawing with the wrong one.
        if isInProximity && report.tool != currentTool {
            releaseHeldButtons(at: location, pressure: 0)
            postProximity(entering: false, tool: currentTool, at: location)
            currentTool = report.tool
            postProximity(entering: true, tool: currentTool, at: location)
        }

        if report.inRange {
            postPoint(report, at: location, pressure: pressure)
            lastLocation = location
        }

        if !report.inRange && isInProximity {
            releaseHeldButtons(at: lastLocation, pressure: 0)
            postProximity(entering: false, tool: currentTool, at: lastLocation)
            isInProximity = false
        }
    }

    /// Announces the pen again to whichever application is now in front.
    ///
    /// Proximity is a one-off event: it is posted when the pen enters the sensing range
    /// and reaches whatever application is frontmost at that moment. An application
    /// launched afterwards — or merely switched to — never sees it, and so never learns
    /// a tablet exists. Every point event that follows carries pressure it has no reason
    /// to look at, and the pen behaves as a plain mouse.
    ///
    /// Callers should invoke this whenever the frontmost application changes.
    public func refreshProximity() {
        // Leave first, then enter. Applications track the pen with a state machine, and
        // a bare second "entered" with no matching "left" is a sequence real hardware
        // never produces — some reset their tablet state on the leave and would
        // otherwise be left holding a registration they think is already active.
        postProximity(entering: false, tool: currentTool, at: lastLocation)
        guard isInProximity else {
            // The pen is away from the tablet, so there is nothing to present yet. The
            // withdrawal above still clears any stale registration, and the next
            // approach of the pen announces it properly.
            return
        }
        postProximity(entering: true, tool: currentTool, at: lastLocation)
    }

    /// Drops the pen out of proximity — used when the tablet is unplugged or the
    /// driver is switched off, so no application is left thinking a button is held.
    public func reset() {
        // The withdrawal is sent whenever the pen was ever announced, not only while it
        // happens to be in range. Quitting with the pen resting beside the tablet would
        // otherwise leave every running application registered to a device that is
        // about to disappear.
        guard hasAnnounced else { return }
        releaseHeldButtons(at: lastLocation, pressure: 0)
        postProximity(entering: false, tool: currentTool, at: lastLocation)
        isInProximity = false
    }

    // MARK: - Event construction

    private func postProximity(entering: Bool, tool: PenTool, at location: CGPoint) {
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletProximity
        // Proximity events are routed by position like any other event. Left at the
        // default (0, 0) they reach whatever happens to be in the top-left corner
        // rather than the window being drawn in — and an application that never sees
        // the pen arrive treats every following point as an ordinary mouse move,
        // silently discarding pressure. Qt-based apps are particularly strict here.
        event.location = location

        let pointerType: PointerType = tool == .eraser ? .eraser : .pen
        event.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: productID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 0)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: pointerType.rawValue)
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: (vendorID << 16) | productID)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: configuration.capabilities.rawValue)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType.rawValue)
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)

        event.post(tap: .cghidEventTap)
    }

    private func postPoint(_ report: PenReport, at location: CGPoint, pressure: Double) {
        let wantsTip = report.tipSwitch
        let wantsBarrel = report.barrelSwitch && configuration.barrelSwitchRightClicks

        // Button transitions come first so the down/up event carries the position the
        // pen was actually at when the switch closed.
        if wantsTip != isTipDown {
            post(
                type: wantsTip ? .leftMouseDown : .leftMouseUp, button: .left,
                report: report, at: location, pressure: pressure
            )
            isTipDown = wantsTip
        }
        if wantsBarrel != isBarrelDown {
            post(
                type: wantsBarrel ? .rightMouseDown : .rightMouseUp, button: .right,
                report: report, at: location, pressure: pressure
            )
            isBarrelDown = wantsBarrel
        }

        // Only emit motion when something actually changed, otherwise a resting pen
        // floods the event stream at the tablet's full report rate. Pressure counts as
        // a change in its own right: pressing harder without moving is a real event,
        // and dropping it makes a stroke's weight lag behind the hand.
        let moved = location != lastLocation
        let pressureChanged = abs(pressure - lastPressure) > 0.002
        guard moved || pressureChanged else { return }
        lastPressure = pressure

        var buttonMask: Int64 = 0
        if report.tipSwitch { buttonMask |= 1 << 0 }
        if report.barrelSwitch { buttonMask |= 1 << 1 }
        if report.eraser { buttonMask |= 1 << 2 }
        postTabletPointer(report, at: location, pressure: pressure, buttons: buttonMask)

        let type: CGEventType
        if isTipDown {
            type = .leftMouseDragged
        } else if isBarrelDown {
            type = .rightMouseDragged
        } else {
            type = .mouseMoved
        }
        post(type: type, button: isBarrelDown ? .right : .left, report: report, at: location, pressure: pressure)
    }

    private func post(
        type: CGEventType, button: CGMouseButton,
        report: PenReport, at location: CGPoint, pressure: Double
    ) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: location, mouseButton: button
        ) else { return }

        var buttonMask: Int64 = 0
        if report.tipSwitch { buttonMask |= 1 << 0 }
        if report.barrelSwitch { buttonMask |= 1 << 1 }
        if report.eraser { buttonMask |= 1 << 2 }

        event.setIntegerValueField(.mouseEventSubtype, value: MouseSubtype.tabletPoint.rawValue)
        // Some applications read NSEvent.pressure straight off the mouse event rather
        // than digging into the tablet payload, so fill both.
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletEventPointX, value: Int64(report.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(report.y))
        event.setIntegerValueField(.tabletEventPointZ, value: 0)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttonMask)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: 0)
        event.setDoubleValueField(.tabletEventTiltY, value: 0)
        event.setDoubleValueField(.tabletEventRotation, value: 0)
        event.setDoubleValueField(.tabletEventTangentialPressure, value: 0)

        event.post(tap: .cghidEventTap)
    }

    /// Posts a standalone tablet-pointer event carrying the same sample.
    ///
    /// Mouse events tagged with the tablet subtype move the cursor and deliver clicks,
    /// and AppKit applications read pressure straight off them. Toolkits that model the
    /// pen as its own input device — Qt, and therefore anything built on it — instead
    /// listen for `NSEventTypeTabletPoint`, which only ever arrives from an event of
    /// this type. Without it they see the cursor move and treat the pen as a mouse.
    ///
    /// A real tablet produces both, so both are sent. This event carries no button
    /// state and does not move the cursor; it is data alongside the mouse event, not a
    /// duplicate of it.
    private func postTabletPointer(
        _ report: PenReport, at location: CGPoint, pressure: Double, buttons: Int64
    ) {
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletPointer
        event.location = location

        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletEventPointX, value: Int64(report.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(report.y))
        event.setIntegerValueField(.tabletEventPointZ, value: 0)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: 0)
        event.setDoubleValueField(.tabletEventTiltY, value: 0)
        event.setDoubleValueField(.tabletEventRotation, value: 0)
        event.setDoubleValueField(.tabletEventTangentialPressure, value: 0)

        event.post(tap: .cghidEventTap)
    }

    private func releaseHeldButtons(at location: CGPoint, pressure: Double) {
        var report = PenReport(x: 0, y: 0, pressure: 0, inRange: true)
        if isTipDown {
            post(type: .leftMouseUp, button: .left, report: report, at: location, pressure: pressure)
            isTipDown = false
        }
        if isBarrelDown {
            report.barrelSwitch = false
            post(type: .rightMouseUp, button: .right, report: report, at: location, pressure: pressure)
            isBarrelDown = false
        }
    }
}
