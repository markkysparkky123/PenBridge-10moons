import CoreGraphics
import Foundation
import TabletCore

/// Interactive selection of the tablet's active area, by tapping two corners.
///
/// The area is what the whole screen maps onto. Making it smaller than the tablet
/// trades reach for precision; making it match the screen's shape keeps circles round.
/// Neither can be guessed from the hardware, because it depends on how far the person
/// wants to move their hand.
final class AreaSetup {

    private enum Stage {
        case waitingForFirst
        case waitingForSecond
        case done
    }

    private var stage = Stage.waitingForFirst
    private var first = CGPoint.zero
    private var second = CGPoint.zero
    private var tipWasDown = false

    private(set) var status = "Tap the first corner of the area you want to use."

    var isFinished: Bool { stage == .done }

    /// Feeds one sample. Corners are taken on the release of a tap, so the position is
    /// the one the pen settled at rather than wherever it was first detected.
    func handle(_ report: PenReport, calibration: Calibration, layout: PenReportLayout) {
        let x = normalize(report.x, in: calibration.xRange(orDeclared: layout.xRange))
        let y = normalize(report.y, in: calibration.yRange(orDeclared: layout.yRange))

        let released = tipWasDown && !report.tipSwitch
        tipWasDown = report.tipSwitch

        guard released else {
            if report.tipSwitch, stage != .done {
                status = String(format: "holding at %.3f, %.3f", x, y)
            }
            return
        }

        switch stage {
        case .waitingForFirst:
            first = CGPoint(x: x, y: y)
            stage = .waitingForSecond
            status = String(
                format: "first corner %.3f, %.3f — now tap the opposite corner", x, y
            )
        case .waitingForSecond:
            second = CGPoint(x: x, y: y)
            stage = .done
        case .done:
            break
        }
    }

    /// The selected rectangle, normalized to the tablet's calibrated range.
    var area: CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    /// A description of what was chosen, in millimetres as well as fractions, because
    /// "0.84 of the height" means much less than "114 mm of 136".
    func summary(layout: PenReportLayout, screen: CGRect, preserveAspect: Bool) -> String {
        let area = self.area
        var lines: [String] = []

        if let widthMM = layout.widthMM, let heightMM = layout.heightMM {
            lines.append(String(
                format: "Selected  %.1f x %.1f mm of %.1f x %.1f",
                area.width * widthMM, area.height * heightMM, widthMM, heightMM
            ))
        }
        lines.append(String(
            format: "          x %.3f…%.3f   y %.3f…%.3f",
            area.minX, area.maxX, area.minY, area.maxY
        ))

        if preserveAspect {
            let trimmed = AreaMapper.proportionalArea(
                layout: layout, screen: screen, within: area
            )
            if let heightMM = layout.heightMM, let widthMM = layout.widthMM {
                let lostHeight = (area.height - trimmed.height) * heightMM
                let lostWidth = (area.width - trimmed.width) * widthMM
                if lostHeight > 0.5 {
                    lines.append(String(
                        format: "          proportions trim %.1f mm of height (%.1f mm each edge)",
                        lostHeight, lostHeight / 2
                    ))
                } else if lostWidth > 0.5 {
                    lines.append(String(
                        format: "          proportions trim %.1f mm of width (%.1f mm each edge)",
                        lostWidth, lostWidth / 2
                    ))
                } else {
                    lines.append("          already matches the screen's shape — nothing trimmed")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func normalize(_ value: Int, in range: ClosedRange<Int>) -> Double {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return min(max(Double(value - range.lowerBound) / span, 0), 1)
    }
}
