import CoreGraphics
import Foundation

/// How the tablet is physically oriented relative to the screen.
public enum TabletRotation: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270

    /// Rotation swaps which tablet axis feeds the screen's width.
    var swapsAxes: Bool { self == .ninety || self == .twoSeventy }
}

/// Maps raw tablet coordinates onto screen coordinates.
///
/// Two details make this less trivial than a pair of `lerp`s:
///
/// 1. The tablet's logical units are not square. The T501 reports 0…4096 on both axes
///    but spans 203.2 mm horizontally and 135.6 mm vertically, so a step of one unit
///    covers different distances on each axis. Aspect-ratio work has to happen in
///    millimetres, not in logical units.
/// 2. Screens use a different aspect ratio again. Mapping the full tablet onto the full
///    screen stretches the image — a circle drawn on the tablet arrives as an ellipse.
///    Preserving the ratio means using a slightly smaller slice of the tablet.
public struct AreaMapper: Sendable {

    /// The portion of the tablet's active area to use, in normalized 0…1 coordinates
    /// with the origin at the top-left of the tablet.
    public var area: CGRect
    public var rotation: TabletRotation
    /// Target rectangle in Core Graphics global display coordinates (origin top-left).
    public var screen: CGRect

    public init(area: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                rotation: TabletRotation = .none,
                screen: CGRect) {
        self.area = area
        self.rotation = rotation
        self.screen = screen
    }

    /// Builds a mapper that fills the whole screen without distorting proportions,
    /// by trimming the tablet's active area to the screen's aspect ratio.
    public static func proportional(
        layout: PenReportLayout,
        screen: CGRect,
        rotation: TabletRotation = .none
    ) -> AreaMapper {
        AreaMapper(
            area: proportionalArea(layout: layout, screen: screen, rotation: rotation),
            rotation: rotation,
            screen: screen
        )
    }

    /// The largest centred sub-rectangle of the tablet whose physical shape matches the screen.
    public static func proportionalArea(
        layout: PenReportLayout,
        screen: CGRect,
        rotation: TabletRotation = .none
    ) -> CGRect {
        guard
            let widthMM = layout.widthMM, let heightMM = layout.heightMM,
            widthMM > 0, heightMM > 0, screen.width > 0, screen.height > 0
        else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // Under 90/270 rotation the tablet's height feeds the screen's width.
        let tabletWidth = rotation.swapsAxes ? heightMM : widthMM
        let tabletHeight = rotation.swapsAxes ? widthMM : heightMM

        let tabletAspect = tabletWidth / tabletHeight
        let screenAspect = screen.width / screen.height

        var fractionX = 1.0
        var fractionY = 1.0
        if tabletAspect > screenAspect {
            // Tablet is relatively wider: narrow it.
            fractionX = screenAspect / tabletAspect
        } else if tabletAspect < screenAspect {
            // Tablet is relatively taller: shorten it.
            fractionY = tabletAspect / screenAspect
        }

        // Those fractions are expressed in the rotated frame; undo the swap so the
        // result is a rectangle in the tablet's own coordinate space.
        let normalizedWidth = rotation.swapsAxes ? fractionY : fractionX
        let normalizedHeight = rotation.swapsAxes ? fractionX : fractionY

        return CGRect(
            x: (1 - normalizedWidth) / 2,
            y: (1 - normalizedHeight) / 2,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    /// Converts one pen sample into a screen point, using the tablet's declared ranges.
    public func map(x: Int, y: Int, layout: PenReportLayout) -> CGPoint {
        map(x: x, y: y, xRange: layout.xRange, yRange: layout.yRange)
    }

    /// Converts one pen sample into a screen point against explicit coordinate ranges.
    ///
    /// The caller supplies the ranges so a measured calibration can override what the
    /// descriptor claims — the two disagree more often than not.
    public func map(
        x: Int, y: Int, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>
    ) -> CGPoint {
        let normalizedX = normalize(x, in: xRange)
        let normalizedY = normalize(y, in: yRange)

        // Restrict to the configured sub-area, then renormalize to 0…1 within it.
        let areaX = area.width > 0 ? (normalizedX - area.minX) / area.width : normalizedX
        let areaY = area.height > 0 ? (normalizedY - area.minY) / area.height : normalizedY

        let (rotatedX, rotatedY) = rotate(areaX, areaY)

        return CGPoint(
            x: screen.minX + clamp(rotatedX) * screen.width,
            y: screen.minY + clamp(rotatedY) * screen.height
        )
    }

    private func rotate(_ x: Double, _ y: Double) -> (Double, Double) {
        switch rotation {
        case .none: return (x, y)
        case .ninety: return (1 - y, x)
        case .oneEighty: return (1 - x, 1 - y)
        case .twoSeventy: return (y, 1 - x)
        }
    }

    private func normalize(_ value: Int, in range: ClosedRange<Int>) -> Double {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return Double(value - range.lowerBound) / span
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
