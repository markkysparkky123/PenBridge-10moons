import AppKit

/// A scratch window that draws with the pen and reports what AppKit delivered.
///
/// `probe` taps the Core Graphics event stream, which shows what the driver *posted*.
/// This shows what an application actually *receives*: the same `NSEvent` layer that
/// Qt, and therefore OpenToonz, reads. Between the two, a pressure problem can be
/// placed on one side of the line or the other instead of being argued about.
///
/// Draw here. If the stroke varies in width, the driver is delivering pressure
/// correctly and any application that ignores it is doing so on its own.
func runNSEventProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "PenBridge — draw here"
    window.acceptsMouseMovedEvents = true

    let canvas = ProbeCanvas(frame: window.contentLayoutRect)
    canvas.autoresizingMask = [.width, .height]
    window.contentView = canvas
    window.makeFirstResponder(canvas)
    window.center()
    window.makeKeyAndOrderFront(nil)

    application.activate(ignoringOtherApps: true)

    print("""
        penbridge nsprobe — a window has opened. Draw in it with the pen.

        Watch two things:
          • the stroke — does it get thicker as you press harder?
          • the readout at the top of the window

        If the stroke varies here but not in your drawing application, the driver is
        fine and the application is not reading the pressure it is being sent.

        Close the window to finish.

        """)

    NSApp.run()
}

private final class ProbeCanvas: NSView {

    private struct Segment {
        let from: NSPoint
        let to: NSPoint
        let width: CGFloat
    }

    private var segments: [Segment] = []
    private var previous: NSPoint?
    private var status = "Bring the pen close to the tablet…"
    private var sawProximity = false
    private var maxPressureSeen: Float = 0

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        NSColor.textColor.setStroke()
        for segment in segments {
            let path = NSBezierPath()
            path.move(to: segment.from)
            path.line(to: segment.to)
            path.lineWidth = segment.width
            path.lineCapStyle = .round
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let banner = """
            \(status)
            proximity received: \(sawProximity ? "yes" : "NO — applications will treat the pen as a mouse")
            highest pressure seen: \(String(format: "%.3f", maxPressureSeen))
            """
        banner.draw(at: NSPoint(x: 12, y: bounds.height - 56), withAttributes: attributes)
    }

    // MARK: - Tablet events

    override func tabletProximity(with event: NSEvent) {
        sawProximity = true
        report(event, label: event.isEnteringProximity ? "proximity enter" : "proximity leave")
    }

    override func mouseMoved(with event: NSEvent) {
        track(event, drawing: false)
    }

    override func mouseDown(with event: NSEvent) {
        previous = convert(event.locationInWindow, from: nil)
        track(event, drawing: true)
    }

    override func mouseDragged(with event: NSEvent) {
        track(event, drawing: true)
    }

    override func mouseUp(with event: NSEvent) {
        previous = nil
        track(event, drawing: false)
    }

    private func track(_ event: NSEvent, drawing: Bool) {
        // A proximity event can also arrive folded into a mouse event's subtype.
        if event.subtype == .tabletProximity { sawProximity = true }

        let isTablet = event.subtype == .tabletPoint || event.subtype == .tabletProximity
        let pressure = isTablet ? event.pressure : 0
        maxPressureSeen = max(maxPressureSeen, pressure)

        let point = convert(event.locationInWindow, from: nil)
        if drawing, let start = previous {
            // Width follows pressure directly, with a floor so a zero-pressure stroke
            // is still visible rather than vanishing.
            segments.append(Segment(from: start, to: point, width: 1 + CGFloat(pressure) * 24))
        }
        if drawing { previous = point }

        report(event, label: drawing ? "drawing" : "hovering", pressure: pressure, isTablet: isTablet)
    }

    private func report(
        _ event: NSEvent, label: String, pressure: Float = 0, isTablet: Bool = true
    ) {
        status = String(
            format: "%@  subtype %@  pressure %.3f  deviceID %d",
            label,
            isTablet ? "tablet" : "PLAIN MOUSE — no tablet data",
            pressure,
            event.subtype == .tabletPoint || event.subtype == .tabletProximity ? event.deviceID : 0
        )
        needsDisplay = true
    }
}
