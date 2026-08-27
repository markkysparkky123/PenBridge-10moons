import Foundation
import TabletCore

/// A live view of what the pressure sensor is doing, raw and after the configured curve.
///
/// Two snapshots from `dump` cannot show whether a sensor responds smoothly to force or
/// slams to full scale the moment the tip touches. Watching a bar move while you lean on
/// the pen can, and it also makes saturation obvious: when the raw value climbs past the
/// configured upper threshold the mapped output stops moving, which is exactly what
/// "it jumps to maximum" feels like.
struct PressureMeter {
    let layout: PenReportLayout
    let curve: PressureCurve

    private static var minSeen = Int.max
    private static var maxSeen = Int.min

    func render(_ report: PenReport) -> String {
        let raw = report.pressure
        if report.tipSwitch {
            Self.minSeen = min(Self.minSeen, raw)
            Self.maxSeen = max(Self.maxSeen, raw)
        }

        let scale = layout.pressureRange.upperBound
        let mapped = curve.apply(raw, range: layout.pressureRange)

        let width = 32
        let filled = max(0, min(width, Int(Double(width) * Double(raw) / Double(max(scale, 1)))))
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "·", count: width - filled)

        // Where the configured band sits on the same scale, so the two can be compared
        // at a glance.
        let lowerRaw = Int(curve.lowerThreshold * Double(scale))
        let upperRaw = Int(curve.upperThreshold * Double(scale))

        var note = ""
        if !report.tipSwitch {
            note = "hovering"
        } else if raw >= upperRaw {
            note = "SATURATED — raw \(raw) is above the configured ceiling of \(upperRaw)"
        } else if raw <= lowerRaw {
            note = "below the configured floor of \(lowerRaw)"
        }

        let seen = Self.minSeen == .max
            ? "—"
            : "\(Self.minSeen)…\(Self.maxSeen)"

        return String(
            format: "raw %4d/%d %@ → mapped %.3f   seen %@   band %d…%d   %@",
            raw, scale, bar, mapped, seen, lowerRaw, upperRaw, note
        )
    }
}
