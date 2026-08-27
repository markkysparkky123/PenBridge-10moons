import ApplicationServices
import CoreGraphics
import Foundation

/// Listens to the tablet events already flowing through the window server.
///
/// Point it at the vendor driver (or at PenBridge itself) to see exactly which fields
/// reach applications. Drawing apps decide whether a tablet supports pressure by
/// inspecting these fields, so a side-by-side comparison is the fastest way to find
/// out why one of them ignores the pen.
func runEventProbe() {
    guard AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    ) else {
        FileHandle.standardError.write(Data("""
            Accessibility access is required to observe events.
            Approve it in System Settings > Privacy & Security > Accessibility,
            then run `penbridge probe` again.

            """.utf8))
        exit(1)
    }

    let mask: CGEventMask =
        (1 << CGEventType.tabletPointer.rawValue)
        | (1 << CGEventType.tabletProximity.rawValue)
        | (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, _ in
            logEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        FileHandle.standardError.write(Data("Could not create the event tap.\n".utf8))
        exit(1)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("""
        penbridge probe — observing tablet events. Ctrl-C to stop.

        Use the pen now. Proximity events appear when the pen enters or leaves the
        sensing range; point events carry the pressure that drawing apps read.

        """)
    CFRunLoopRun()
}

private var lastProximitySummary = ""
private var pointCount = 0

private func logEvent(type: CGEventType, event: CGEvent) {
    func int(_ field: CGEventField) -> Int64 { event.getIntegerValueField(field) }
    func double(_ field: CGEventField) -> Double { event.getDoubleValueField(field) }

    switch type {
    case .tabletProximity:
        let entering = int(.tabletProximityEventEnterProximity) != 0
        print("""

            PROXIMITY \(entering ? "enter" : "leave")
              vendorID            \(int(.tabletProximityEventVendorID))
              tabletID            \(int(.tabletProximityEventTabletID))
              pointerID           \(int(.tabletProximityEventPointerID))
              deviceID            \(int(.tabletProximityEventDeviceID))
              systemTabletID      \(int(.tabletProximityEventSystemTabletID))
              vendorPointerType   \(int(.tabletProximityEventVendorPointerType))
              vendorUniqueID      \(int(.tabletProximityEventVendorUniqueID))
              capabilityMask      0x\(String(int(.tabletProximityEventCapabilityMask), radix: 16))
              pointerType         \(int(.tabletProximityEventPointerType))
            """)
        pointCount = 0

    case .tabletPointer:
        summarizePoint(label: "POINT", event: event)

    case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged:
        // Subtype 1 is NX_SUBTYPE_TABLET_POINT, 2 is NX_SUBTYPE_TABLET_PROXIMITY.
        // A mouse event carrying subtype 1 is how a driver attaches pressure to a
        // normal cursor event — this is the path most drawing apps actually read.
        let subtype = int(.mouseEventSubtype)
        guard subtype == 1 || subtype == 2 else { return }
        summarizePoint(label: "MOUSE(\(name(of: type))) subtype \(subtype)", event: event)

    default:
        break
    }
}

private func summarizePoint(label: String, event: CGEvent) {
    func int(_ field: CGEventField) -> Int64 { event.getIntegerValueField(field) }
    func double(_ field: CGEventField) -> Double { event.getDoubleValueField(field) }

    // Point events arrive at tablet report rate; printing every one drowns the console.
    pointCount += 1
    let summary = String(
        format: "%@  deviceID %-6d  tabletXY %6d,%-6d  pressure %.4f  buttons 0x%llX  tilt %.2f,%.2f  loc %.0f,%.0f",
        label,
        int(.tabletEventDeviceID),
        int(.tabletEventPointX), int(.tabletEventPointY),
        double(.tabletEventPointPressure),
        int(.tabletEventPointButtons),
        double(.tabletEventTiltX), double(.tabletEventTiltY),
        event.location.x, event.location.y
    )
    if summary != lastProximitySummary {
        print(summary)
        lastProximitySummary = summary
    }
}

private func name(of type: CGEventType) -> String {
    switch type {
    case .mouseMoved: return "moved"
    case .leftMouseDown: return "down"
    case .leftMouseUp: return "up"
    case .leftMouseDragged: return "dragged"
    default: return "other"
    }
}
