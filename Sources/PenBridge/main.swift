import CoreGraphics
import Foundation
import IOKit.hid
import TabletCore

// MARK: - Command line

let usage = """
penbridge — diagnostics for the PenBridge graphics tablet driver

USAGE
  penbridge info        Show every detected tablet, its parsed descriptor and pen layout
  penbridge dump        Stream raw HID reports with a decoded breakdown
  penbridge calibrate   Track the true min/max of X, Y and pressure while you move the pen
  penbridge pressure    Live pressure meter: raw reading, configured band, mapped output
  penbridge area        Choose the active area by tapping two opposite corners
  penbridge probe       Log the tablet events another driver is posting (needs Accessibility)
  penbridge nsprobe     Open a scratch window and draw in it — shows what an app receives

OPTIONS
  --seize   Take the tablet exclusively, so macOS's own HID driver stops handling it.
            Try this if reports never arrive, or if the cursor appears to be driven twice.
  --apply   calibrate and area: write the measurement into the driver's settings,
            so the mapper uses your tablet and your choice rather than its defaults.

All modes run until interrupted with Ctrl-C.
"""

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first(where: { !$0.hasPrefix("-") }) ?? "info"
let seize = arguments.contains("--seize")
let apply = arguments.contains("--apply")
guard ["info", "dump", "calibrate", "probe", "pressure", "nsprobe", "area"].contains(command) else {
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 2)
}

// MARK: - Permissions

/// Reading HID input requires Input Monitoring. Without it the run loop simply stays
/// silent, which is the single most confusing failure mode in this kind of tool.
func ensureInputMonitoring() {
    guard command != "probe" else { return }
    let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    switch granted {
    case kIOHIDAccessTypeGranted:
        return
    case kIOHIDAccessTypeDenied:
        FileHandle.standardError.write(Data("""
            Input Monitoring is denied for this process.
            Grant it in System Settings > Privacy & Security > Input Monitoring,
            then run penbridge again.

            """.utf8))
        exit(1)
    default:
        print("Requesting Input Monitoring access…")
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

ensureInputMonitoring()

// MARK: - Formatting helpers

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func bits(_ byte: UInt8) -> String {
    let text = String(byte, radix: 2)
    return String(repeating: "0", count: 8 - text.count) + text
}

func describe(_ device: TabletDevice) -> String {
    let layout = device.layout

    func axis(_ label: String, _ range: ClosedRange<Int>, _ field: HIDReportField) -> String {
        let low: Int = range.lowerBound
        let high: Int = range.upperBound
        let offset: Int = field.bitOffset
        let size: Int = field.bitSize
        let padded: String = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(padded)\(low)…\(high)  (bit \(offset), \(size) bits)"
    }

    var lines: [String] = [
        "Device      \(device.identifier)",
        "Pen report  ID \(layout.reportID), \(layout.payloadSize)-byte payload",
        axis("X", layout.xRange, layout.xField),
        axis("Y", layout.yRange, layout.yField),
        axis("Pressure", layout.pressureRange, layout.pressureField),
        "Tilt        \(layout.hasTilt ? "yes" : "no")",
    ]
    if let width = layout.widthMM, let height = layout.heightMM {
        lines.append(String(format: "Active area %.1f x %.1f mm (%.3f:1)", width, height, width / height))
    }
    let otherReports = Set(device.fields.filter { $0.kind == .input }.map(\.reportID))
        .subtracting([layout.reportID]).sorted()
    if !otherReports.isEmpty {
        lines.append("Other input reports  \(otherReports.map(String.init).joined(separator: ", "))")
    }

    // The vendor configuration channel. Reading it is harmless and shows what mode the
    // tablet thinks it is in — useful when the pen stays silent.
    for report in device.featureReports {
        let value = device.readFeatureReport(id: report.id, size: report.size)
        let rendered = value.map(hex) ?? "unreadable"
        lines.append("Feature \(report.id)   \(report.size) bytes: \(rendered)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Modes

let monitor = TabletDeviceMonitor()
monitor.seizeDevice = seize

/// Running extremes, used by `calibrate`.
final class Extremes {
    var minX = Int.max, maxX = Int.min
    var minY = Int.max, maxY = Int.min
    var minPressure = Int.max, maxPressure = Int.min
    var samples = 0

    /// Where the result is written, so it survives closing the terminal and can be
    /// read back without copying numbers by hand.
    static let outputURL = Settings.storeURL
        .deletingLastPathComponent()
        .appendingPathComponent("calibration.json")

    private var lastWrite = Date.distantPast
    /// Kept so the saved file can record what the descriptor claimed alongside what
    /// was actually measured.
    var layout: PenReportLayout?

    func record(_ report: PenReport) {
        minX = min(minX, report.x); maxX = max(maxX, report.x)
        minY = min(minY, report.y); maxY = max(maxY, report.y)
        if report.tipSwitch {
            minPressure = min(minPressure, report.pressure)
            maxPressure = max(maxPressure, report.pressure)
        }
        samples += 1

        // Written as it goes rather than on exit, so a Ctrl-C or a crash still leaves
        // the measurement behind.
        if Date().timeIntervalSince(lastWrite) > 0.5 {
            lastWrite = Date()
            save(layout: layout)
        }
    }

    func save(layout: PenReportLayout? = nil) {
        guard samples > 0 else { return }
        var payload: [String: Any] = [
            "samples": samples,
            "observed": [
                "x": ["min": minX, "max": maxX],
                "y": ["min": minY, "max": maxY],
                "pressure": [
                    "min": minPressure == .max ? 0 : minPressure,
                    "max": maxPressure == .min ? 0 : maxPressure,
                ],
            ],
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let layout {
            payload["declared"] = [
                "x": ["min": layout.xRange.lowerBound, "max": layout.xRange.upperBound],
                "y": ["min": layout.yRange.lowerBound, "max": layout.yRange.upperBound],
                "pressure": [
                    "min": layout.pressureRange.lowerBound,
                    "max": layout.pressureRange.upperBound,
                ],
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: Self.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.outputURL, options: .atomic)
    }

    func render(against layout: PenReportLayout) -> String {
        guard samples > 0 else { return "waiting for the pen…" }
        func compare(_ observed: ClosedRange<Int>, _ declared: ClosedRange<Int>) -> String {
            observed == declared ? "" : "  <- differs from descriptor \(declared.lowerBound)…\(declared.upperBound)"
        }
        return String(
            format: "%6d samples   X %5d…%-5d%@   Y %5d…%-5d%@   P %5d…%-5d%@",
            samples,
            minX, maxX, compare(minX...max(maxX, minX), layout.xRange),
            minY, maxY, compare(minY...max(maxY, minY), layout.yRange),
            minPressure == .max ? 0 : minPressure, maxPressure == .min ? 0 : maxPressure,
            ""
        )
    }
}

let extremes = Extremes()

monitor.onAttach = { device in
    print("\n── tablet connected ──")
    print(describe(device))
    switch command {
    case "dump":
        print("\nStreaming reports. Move the pen over the tablet.\n")
    case "calibrate":
        print("""

            Drag the pen slowly along all four edges of the drawing area — the marked
            rectangle only, not any soft-key strip outside it — then press firmly in
            the middle. Watch the numbers stop changing: those are the device's true
            limits, which is what the mapper needs.

            Saving continuously to:
            \(Extremes.outputURL.path)

            """)
    case "pressure":
        print("""

            Press the pen down and lean on it. Watch how the bar responds:

              • a bar that climbs smoothly with force means the sensor is fine
              • a bar that jumps most of the way the instant the tip touches means
                the hardware barely distinguishes force, which no driver can fix
              • "SATURATED" means the mapped output has stopped moving because the
                configured ceiling is lower than what you actually press — recalibrate
                with `calibrate --apply`, pressing as hard as you ever will

            """)
    case "area":
        print("""

            The active area is the part of the tablet that maps to the whole screen.

            Tap two opposite corners of the area you want — top-left, then
            bottom-right. Tap where you want the edge of the screen to be, not
            necessarily at the edge of the tablet.

            """)
    default:
        break
    }
}

monitor.onDetach = { device in
    print("── tablet disconnected: \(device.identifier) ──")
}

let areaSetup = AreaSetup()

/// Writes the selected active area into the driver's settings.
///
/// Refuses a selection too small to be a deliberate choice: a stray double tap in one
/// spot would otherwise map the entire screen onto a few millimetres of tablet, leaving
/// a cursor that cannot be steered well enough to open the menu and undo it.
func applyArea(layout: PenReportLayout) {
    let area = areaSetup.area
    guard area.width > 0.05, area.height > 0.05 else {
        print("""

            That selection is only \(Int(area.width * 100))% by \(Int(area.height * 100))% \
            of the tablet — too small to be intended, so nothing was written.
            Tap two genuinely opposite corners.
            """)
        return
    }
    guard apply else {
        print("""

            Nothing written. Run `penbridge-cli area --apply` to save this.
            """)
        return
    }

    var settings = Settings.load()
    settings.area = NormalizedRect(area)
    do {
        try settings.save()
        print("""

            Written to \(Settings.storeURL.path)
            Restart PenBridge for it to take effect.
            """)
    } catch {
        print("\nCould not write settings: \(error.localizedDescription)")
    }
}

/// Counts every report of every kind, so "nothing is happening" can be diagnosed.
final class Traffic {
    var total = 0
    var pen = 0
    var byReportID: [UInt8: Int] = [:]
}
let traffic = Traffic()

monitor.onLog = { message in
    FileHandle.standardError.write(Data("!! \(message)\n".utf8))
}

monitor.onReport = { device, reportID, payload in
    traffic.total += 1
    traffic.byReportID[reportID, default: 0] += 1
    if reportID == device.layout.reportID { traffic.pen += 1 }

    guard ["dump", "calibrate", "pressure", "area"].contains(command) else { return }

    // Reports other than the pen's (express keys, consumer control, vendor config)
    // are still worth showing in dump mode — they are undocumented territory.
    guard reportID == device.layout.reportID else {
        if command == "dump" {
            print("id \(reportID)  \(hex(payload))   [non-pen report]")
        }
        return
    }

    guard let report = device.layout.decode(payload) else {
        print("id \(reportID)  \(hex(payload))   [too short: \(payload.count) bytes]")
        return
    }

    switch command {
    case "dump":
        var flags: [String] = []
        if report.inRange { flags.append("range") }
        if report.tipSwitch { flags.append("tip") }
        if report.barrelSwitch { flags.append("barrel") }
        if report.eraser { flags.append("eraser") }
        if report.invert { flags.append("invert") }
        print(String(
            format: "%@ | %@ | X %5d  Y %5d  P %5d  %@",
            hex(payload),
            payload.first.map(bits) ?? "--------",
            report.x, report.y, report.pressure,
            flags.joined(separator: " ")
        ))
    case "calibrate":
        extremes.record(report)
        extremes.layout = device.layout
        print("\r\(extremes.render(against: device.layout))", terminator: "")
        fflush(stdout)
    case "pressure":
        let meter = PressureMeter(layout: device.layout, curve: Settings.load().pressure)
        print("\r\u{1B}[K\(meter.render(report))", terminator: "")
        fflush(stdout)
    case "area":
        guard !areaSetup.isFinished else { return }
        let settings = Settings.load()
        areaSetup.handle(report, calibration: settings.calibration, layout: device.layout)
        if areaSetup.isFinished {
            let screen = CGDisplayBounds(settings.displayID ?? CGMainDisplayID())
            print("\r\u{1B}[K")
            print(areaSetup.summary(
                layout: device.layout, screen: screen,
                preserveAspect: settings.preserveAspectRatio
            ))
            applyArea(layout: device.layout)
            exit(0)
        }
        print("\r\u{1B}[K\(areaSetup.status)", terminator: "")
        fflush(stdout)
    default:
        break
    }
}

/// Writes a finished measurement into the driver's settings.
///
/// Deliberately conservative: a half-finished sweep would otherwise lock the cursor
/// into a fraction of the screen, which is worse than trusting the descriptor.
func applyCalibration() {
    guard command == "calibrate", apply else { return }
    guard let layout = extremes.layout, extremes.samples > 200 else {
        print("\n\nNot enough samples to apply — nothing written.")
        return
    }

    let xSpan = extremes.maxX - extremes.minX
    let ySpan = extremes.maxY - extremes.minY
    let declaredX = layout.xRange.upperBound - layout.xRange.lowerBound
    let declaredY = layout.yRange.upperBound - layout.yRange.lowerBound
    guard xSpan > declaredX / 2, ySpan > declaredY / 2 else {
        print("""

            The sweep covered only \(xSpan * 100 / max(declaredX, 1))% by \
            \(ySpan * 100 / max(declaredY, 1))% of the declared range — that looks
            like an incomplete pass, so nothing was written. Trace all four edges
            of the drawing area and try again.
            """)
        return
    }

    var settings = Settings.load()
    settings.calibration = Calibration(
        xMin: extremes.minX, xMax: extremes.maxX,
        yMin: extremes.minY, yMax: extremes.maxY
    )

    // Pressure is expressed as fractions of the declared scale, so it stays meaningful
    // if the same config is carried to a tablet with a different resolution.
    let pressureScale = Double(layout.pressureRange.upperBound - layout.pressureRange.lowerBound)
    if pressureScale > 0, extremes.maxPressure > extremes.minPressure {
        settings.pressure.lowerThreshold = Double(max(extremes.minPressure, 0)) / pressureScale
        settings.pressure.upperThreshold = Double(extremes.maxPressure) / pressureScale
    }

    do {
        try settings.save()
        let percent = Int((settings.pressure.upperThreshold * 100).rounded())
        print("""


            Written to \(Settings.storeURL.path)

              X          \(extremes.minX)…\(extremes.maxX)
              Y          \(extremes.minY)…\(extremes.maxY)
              Pressure   full scale now reached at \(percent)% of the raw range

            Restart PenBridge for it to take effect.
            """)

        // Setting the ceiling from a press that was not actually maximal is a trap:
        // every heavier press then maps to the same full pressure, and strokes read as
        // jumping straight to maximum weight.
        if settings.pressure.upperThreshold < 0.9 {
            print("""

                Note: \(extremes.maxPressure) of \(layout.pressureRange.upperBound) was
                the hardest press recorded. If you normally press harder than that while
                drawing, everything above it will now saturate at full pressure. Run
                `calibrate --apply` again and press as hard as you ever will.
                """)
        }
    } catch {
        print("\n\nCould not write settings: \(error.localizedDescription)")
    }
}

if command == "probe" {
    runEventProbe()
} else if command == "nsprobe" {
    runNSEventProbe()
} else {
    // Ctrl-C is the normal way to end a calibration run, so it has to be a clean exit
    // rather than a kill, or --apply would never get the chance to write anything.
    signal(SIGINT, SIG_IGN)
    let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupts.setEventHandler {
        extremes.save(layout: extremes.layout)
        applyCalibration()
        print("")
        exit(0)
    }
    interrupts.resume()

    monitor.start()
    print("penbridge \(command) — looking for tablets. Ctrl-C to stop.")

    // Silence is ambiguous: it can mean the pen is out of range, the device never
    // opened, or another driver holds it. A periodic summary tells them apart.
    var quietTicks = 0
    var lastTotal = 0
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        guard command == "dump" || command == "calibrate" else { return }
        if traffic.total == lastTotal {
            quietTicks += 1
            if traffic.total == 0 && quietTicks <= 4 {
                print("""
                    … no reports yet (\(quietTicks * 3)s). If the pen is on the tablet, check:
                      • the vendor driver is not still running — `pkill -f TabletDriver.app`
                      • the pen has a working battery, if it takes one
                      • the pen tip is within a centimetre of the surface
                    """)
            } else if traffic.total > 0 && quietTicks == 1 {
                let breakdown = traffic.byReportID.sorted { $0.key < $1.key }
                    .map { "id \($0.key): \($0.value)" }.joined(separator: ", ")
                print("\n… idle. Received so far — \(breakdown); pen reports: \(traffic.pen)")
            }
        } else {
            quietTicks = 0
            lastTotal = traffic.total
        }
    }
    RunLoop.main.run()
}
