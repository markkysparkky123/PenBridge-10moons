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
  penbridge probe       Log the tablet events another driver is posting (needs Accessibility)

All modes run until interrupted with Ctrl-C.
"""

let command = CommandLine.arguments.dropFirst().first ?? "info"
guard ["info", "dump", "calibrate", "probe"].contains(command) else {
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
    return lines.joined(separator: "\n")
}

// MARK: - Modes

let monitor = TabletDeviceMonitor()

/// Running extremes, used by `calibrate`.
final class Extremes {
    var minX = Int.max, maxX = Int.min
    var minY = Int.max, maxY = Int.min
    var minPressure = Int.max, maxPressure = Int.min
    var samples = 0

    func record(_ report: PenReport) {
        minX = min(minX, report.x); maxX = max(maxX, report.x)
        minY = min(minY, report.y); maxY = max(maxY, report.y)
        if report.tipSwitch {
            minPressure = min(minPressure, report.pressure)
            maxPressure = max(maxPressure, report.pressure)
        }
        samples += 1
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

            Drag the pen slowly along all four edges of the active area, then press
            firmly in the middle. Watch the numbers stop changing — those are the
            device's true limits, which is what the mapper needs.

            """)
    default:
        break
    }
}

monitor.onDetach = { device in
    print("── tablet disconnected: \(device.identifier) ──")
}

monitor.onReport = { device, reportID, payload in
    guard command == "dump" || command == "calibrate" else { return }

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
        print("\r\(extremes.render(against: device.layout))", terminator: "")
        fflush(stdout)
    default:
        break
    }
}

if command == "probe" {
    runEventProbe()
} else {
    monitor.start()
    print("penbridge \(command) — looking for tablets. Ctrl-C to stop.")
    RunLoop.main.run()
}
