import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import TabletCore

/// Shows both halves of what a tablet button does: the report the device sends, and the
/// event macOS makes of it.
///
/// The two are normally invisible to each other, which is what makes a half-working
/// suppressor so hard to reason about. A button whose keystroke is discarded and a button
/// whose scroll is not look identical from the outside — both are "a button that does
/// something" — while the reason lives in which report it came from and which tap the
/// resulting event passes through.
///
/// Two taps are installed, not one. An event synthesized low in the stack appears in both;
/// one the window server produces later appears only in the session tap. That difference
/// decides where a suppressor has to listen, and it cannot be read off a single tap.
///
/// Everything is listen-only. This mode never discards anything.
final class ButtonProbe {

    private let started = Date()
    private let logURL: URL
    private var log: FileHandle?
    /// Pen flags are only worth a line when they change; a resting pen reports at full
    /// rate and would bury everything else.
    private var lastPenFlags: UInt8?
    private var contexts: [TapContext] = []

    /// How long after a tablet report an event is still credited to it. Generous compared
    /// with what the suppressor uses: here a false pairing is visible in the summary and
    /// costs nothing, while a missed one hides the very thing being looked for.
    private let attribution: TimeInterval = 0.2

    private struct Recent {
        let key: String
        let at: Date
    }

    private var recentReports: [Recent] = []
    /// tablet report → the macOS events that followed it, with counts.
    private var attributed: [String: [String: Int]] = [:]
    /// Events with no tablet report behind them: the user's own keyboard and mouse. Kept
    /// rather than discarded, because "my typing showed up in the log" is otherwise
    /// indistinguishable from "the tablet did that".
    private var unattributed: [String: Int] = [:]
    private var reportCount = 0

    init(logURL: URL) {
        self.logURL = logURL
        // Appended, not replaced. Working out what a button does takes several runs, and
        // each one used to erase the evidence of the last — including the run that
        // happened to catch the thing being chased.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        self.log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()

        let stamp = ISO8601DateFormatter().string(from: Date())
        log?.write(Data("\n══ penbridge buttons — \(stamp) ══\n".utf8))
    }

    /// Written to a file as well as the terminal. A tablet button can close a window, kill
    /// a foreground process or switch applications — that is the whole reason for looking
    /// at it — so the evidence has to survive the session that produced it.
    func line(_ text: String) {
        let stamp = String(format: "%7.3f  ", Date().timeIntervalSince(started))
        print(stamp + text)
        log?.write(Data((stamp + text + "\n").utf8))
    }

    // MARK: - HID side

    func handle(device: TabletDevice, reportID: UInt8, payload: [UInt8]) {
        reportCount += 1
        let bytes = payload.map { String(format: "%02X", $0) }.joined(separator: " ")

        if let keys = device.expressKeys, reportID == keys.reportID {
            guard let event = keys.decode(payload) else {
                line("HID  id \(reportID)  \(bytes)   [keyboard report too short to decode]")
                return
            }
            let names = event.usages.map {
                HIDKeyCodes.name(usage: $0, modifiers: event.modifiers)
            }
            let described = event.isRelease
                ? "release"
                : (names.isEmpty
                    ? HIDKeyCodes.name(usage: 0, modifiers: event.modifiers)
                    : names.joined(separator: " "))
            line("HID  id \(reportID)  \(bytes)   keyboard: \(described)")
            // A release is not a button; crediting events to it would attach the key-up of
            // one press to the button that had just been let go.
            if !event.isRelease { remember("button sending \(described)") }
            return
        }

        if let keys = device.consumerKeys, reportID == keys.reportID {
            guard let event = keys.decode(payload) else {
                line("HID  id \(reportID)  \(bytes)   [consumer report too short to decode]")
                return
            }
            let described = event.isRelease
                ? "release"
                : event.usages.map(Self.consumerName).joined(separator: " ")
            line("HID  id \(reportID)  \(bytes)   consumer: \(described)")
            if !event.isRelease { remember("button sending consumer \(described)") }
            return
        }

        if reportID == device.layout.reportID {
            guard let flags = payload.first else { return }
            // Only the switch bits matter here; coordinates and pressure change constantly.
            guard flags != lastPenFlags else { return }
            lastPenFlags = flags
            guard let report = device.layout.decode(payload) else {
                line("HID  id \(reportID)  \(bytes)   [pen report too short to decode]")
                return
            }
            var set: [String] = []
            if report.inRange { set.append("range") }
            if report.tipSwitch { set.append("tip") }
            if report.barrelSwitch { set.append("barrel") }
            if report.eraser { set.append("eraser") }
            if report.invert { set.append("invert") }
            let bits = String(flags, radix: 2)
            let padded = String(repeating: "0", count: max(0, 8 - bits.count)) + bits
            line("HID  id \(reportID)  flags \(padded)   pen: \(set.joined(separator: " "))")
            remember("pen with \(set.joined(separator: " "))")
            return
        }

        line("HID  id \(reportID)  \(bytes)   [unrecognised report]")
        remember("unrecognised report \(reportID)")
    }

    /// Files a tablet report as the possible cause of whatever macOS does next.
    private func remember(_ key: String) {
        let now = Date()
        recentReports.removeAll { now.timeIntervalSince($0.at) > attribution }
        recentReports.append(Recent(key: key, at: now))
        // Named here even when nothing follows, so a button that produces no event at all
        // still appears in the summary — that is a finding, not an absence.
        attributed[key] = attributed[key] ?? [:]
    }

    /// One sample from the tablet's mouse-shaped second interface — where this model's
    /// scroll buttons live.
    func handleAux(_ interface: TabletAuxInterface, _ event: MouseReportEvent) {
        reportCount += 1
        guard !event.isIdle else { return }

        var parts: [String] = []
        if event.wheel != 0 { parts.append("wheel \(event.wheel > 0 ? "+" : "")\(event.wheel)") }
        if event.buttons != 0 { parts.append(String(format: "buttons 0x%02X", event.buttons)) }
        if event.deltaX != 0 || event.deltaY != 0 {
            parts.append("move \(event.deltaX),\(event.deltaY)")
        }
        let described = parts.joined(separator: " ")
        line("HID  id \(interface.mouse.reportID)  \(described)   [second interface: mouse]")
        remember("scroll button (\(described))")
    }

    /// The consumer usages a tablet's strip and scroll buttons are wired to. Named because
    /// a bare number tells you nothing about why the volume just changed.
    private static func consumerName(_ usage: UInt16) -> String {
        let names: [UInt16: String] = [
            0x00B5: "Next Track", 0x00B6: "Previous Track", 0x00CD: "Play/Pause",
            0x00E2: "Mute", 0x00E9: "Volume Up", 0x00EA: "Volume Down",
            0x0183: "Media Player", 0x0192: "Calculator", 0x0223: "Browser Home",
            0x022D: "AC Zoom In", 0x022E: "AC Zoom Out", 0x0230: "AC Full Screen",
            0x0233: "AC Scroll Up", 0x0234: "AC Scroll Down", 0x0238: "AC Pan",
        ]
        let known = names[usage].map { " \($0)" } ?? ""
        return String(format: "0x%04X%@", usage, known)
    }

    // MARK: - Event side

    /// `NX_SYSDEFINED` — media keys arrive under this type, which `CGEventType` has no
    /// case for.
    private static let systemDefined: UInt32 = 14

    func startTaps() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << Self.systemDefined)

        let levels: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "hid"),
            (.cgSessionEventTap, "session"),
        ]

        var installed = 0
        for (location, label) in levels {
            // Held for the run: the callback carries a bare pointer to it, and a context
            // released at the end of this iteration would leave the tap pointing at
            // nothing.
            let box = TapContext(probe: self, label: label)
            contexts.append(box)
            let context = Unmanaged.passUnretained(box).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, context in
                    if let context {
                        let box = Unmanaged<TapContext>.fromOpaque(context).takeUnretainedValue()
                        box.probe.observed(type: type, event: event, at: box.label)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: context
            ) else {
                line("!! could not create the \(label) tap")
                continue
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            installed += 1
        }
        return installed > 0
    }

    fileprivate func observed(type: CGEventType, event: CGEvent, at label: String) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return }

        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        // A suppressor uses this to tell hardware from another program's synthetic input,
        // so it has to be visible here or a mismatch is invisible.
        let origin = pid == 0 ? "hardware" : "pid \(pid)"

        let detail: String
        switch type.rawValue {
        case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            detail = String(format: "%@ keycode 0x%02X",
                            type == .keyDown ? "keyDown" : "keyUp", key)
        case CGEventType.flagsChanged.rawValue:
            detail = String(format: "flagsChanged flags 0x%llX", event.flags.rawValue)
        case CGEventType.scrollWheel.rawValue:
            let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            detail = "scrollWheel delta \(axis1)/\(axis2) continuous \(continuous)"
        case CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            detail = "otherMouse\(type == .otherMouseDown ? "Down" : "Up") button \(button)"
        case Self.systemDefined:
            // Subtype and data1 have no `CGEventField` of their own; NSEvent is the only
            // public way to read them. Subtype 8 is the one media keys use.
            if let wrapped = NSEvent(cgEvent: event), wrapped.type == .systemDefined {
                detail = String(
                    format: "systemDefined subtype %d data1 0x%08lX",
                    wrapped.subtype.rawValue, wrapped.data1
                )
            } else {
                detail = "systemDefined (unreadable)"
            }
        default:
            detail = "type \(type.rawValue)"
        }

        line("EVT  [\(label)]  \(detail)   (\(origin))")

        let key = "[\(label)] \(detail)" + (pid == 0 ? "" : " (pid \(pid))")
        let now = Date()
        recentReports.removeAll { now.timeIntervalSince($0.at) > attribution }
        if let cause = recentReports.last {
            attributed[cause.key, default: [:]][key, default: 0] += 1
        } else {
            unattributed[key, default: 0] += 1
        }
    }

    /// Prints what was actually learned, rather than leaving it to be read out of a
    /// timestamped stream mixed with the user's own typing and mouse.
    func printSummary() {
        line("")
        line("══ summary ══")
        line("\(reportCount) reports came from the tablet.")

        if reportCount == 0 {
            line("""

                Nothing at all arrived from the tablet, so nothing below can be credited to
                it. Every event listed is from the keyboard or the mouse. Check the tablet
                is on the bus (`penbridge-cli info`) and that no other driver holds it.
                """)
        }

        if attributed.isEmpty {
            line("\nNo tablet button was pressed during this run.")
        } else {
            line("\n── what each tablet button produced ──")
            for (cause, events) in attributed.sorted(by: { $0.key < $1.key }) {
                line("\n  \(cause)")
                if events.isEmpty {
                    // The interesting case: a button macOS does nothing visible with, or
                    // one whose effect is produced somewhere neither tap can see.
                    line("      (no event followed it at either tap)")
                    continue
                }
                for (event, count) in events.sorted(by: { $0.key < $1.key }) {
                    line("      \(event)  ×\(count)")
                }
            }
        }

        if !unattributed.isEmpty {
            line("\n── events with no tablet report behind them (your keyboard and mouse) ──")
            for (event, count) in unattributed.sorted(by: { $0.key < $1.key }) {
                line("      \(event)  ×\(count)")
            }
        }

        line("\nWritten to \(logURL.path)")
    }
}

/// Boxes the callback context: a C function pointer can carry one opaque pointer, and two
/// taps need to be told apart inside a shared callback.
private final class TapContext {
    let probe: ButtonProbe
    let label: String

    init(probe: ButtonProbe, label: String) {
        self.probe = probe
        self.label = label
    }
}
