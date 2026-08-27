import CoreGraphics
import Foundation

/// Maps the pen's raw pressure reading onto the 0…1 value drawing apps expect.
///
/// Two separate jobs:
///
/// * **Thresholds** cut off the ends. Cheap tablets report a non-zero floor as soon as
///   the tip switch closes and often never reach their nominal maximum under normal
///   hand pressure, so the usable band is narrower than the declared range.
/// * **The curve** shapes what happens in between, the same idea as a "pen feel" slider:
///   a soft curve reaches high pressure sooner, a firm one demands more force.
public struct PressureCurve: Sendable, Codable, Equatable {

    /// Raw fraction at or below which pressure reads as zero.
    public var lowerThreshold: Double
    /// Raw fraction at or above which pressure reads as one.
    public var upperThreshold: Double
    /// Cubic Bézier control points inside the unit square, as in CSS `cubic-bezier`.
    public var control1: CGPoint
    public var control2: CGPoint

    public init(
        lowerThreshold: Double = 0,
        upperThreshold: Double = 1,
        control1: CGPoint = CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
        control2: CGPoint = CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0)
    ) {
        self.lowerThreshold = lowerThreshold
        self.upperThreshold = upperThreshold
        self.control1 = control1
        self.control2 = control2
    }

    /// Straight-through response, and the default until the user says otherwise.
    public static let linear = PressureCurve()

    /// Reaches high pressure with less force.
    public static let soft = PressureCurve(
        control1: CGPoint(x: 0.2, y: 0.55), control2: CGPoint(x: 0.45, y: 0.9)
    )

    /// Demands more force before pressure climbs.
    public static let firm = PressureCurve(
        control1: CGPoint(x: 0.55, y: 0.1), control2: CGPoint(x: 0.8, y: 0.45)
    )

    /// Applies thresholds and curve to a raw device reading.
    public func apply(_ raw: Int, range: ClosedRange<Int>) -> Double {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        let normalized = Double(raw - range.lowerBound) / span
        return apply(normalized)
    }

    /// Applies thresholds and curve to an already-normalized 0…1 reading.
    public func apply(_ normalized: Double) -> Double {
        let low = min(lowerThreshold, upperThreshold)
        let high = max(lowerThreshold, upperThreshold)
        let usable = high - low
        guard usable > 0 else { return normalized >= high ? 1 : 0 }

        let clamped = min(max((normalized - low) / usable, 0), 1)
        return min(max(evaluate(at: clamped), 0), 1)
    }

    /// Evaluates the Bézier's y for a given x.
    ///
    /// The curve is parametric, so x has to be inverted for t first. Newton-Raphson
    /// converges in a handful of steps here; the bisection fallback covers the flat
    /// spots where the derivative is too small to trust.
    func evaluate(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }

        var t = x
        for _ in 0..<8 {
            let error = bezier(t, control1.x, control2.x) - x
            if abs(error) < 1e-6 { return bezier(t, control1.y, control2.y) }
            let derivative = bezierSlope(t, control1.x, control2.x)
            if abs(derivative) < 1e-6 { break }
            t -= error / derivative
        }

        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<24 {
            let value = bezier(t, control1.x, control2.x)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezier(t, control1.y, control2.y)
    }

    /// Cubic Bézier with endpoints pinned at 0 and 1.
    private func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * a + 3 * inverse * t * t * b + t * t * t
    }

    private func bezierSlope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * a
            + 6 * inverse * t * (b - a)
            + 3 * t * t * (1 - b)
    }
}
