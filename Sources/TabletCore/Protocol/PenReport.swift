import Foundation

/// One decoded sample from the pen.
public struct PenReport: Sendable, Equatable {
    /// Raw device coordinates, in the range declared by `PenReportLayout.xRange`.
    public var x: Int
    public var y: Int
    /// Raw pressure, in the range declared by `PenReportLayout.pressureRange`.
    public var pressure: Int

    public var tipSwitch: Bool
    public var barrelSwitch: Bool
    public var eraser: Bool
    /// The pen is being held upside down.
    public var invert: Bool
    /// The pen is close enough to the surface to be tracked.
    public var inRange: Bool

    public init(
        x: Int, y: Int, pressure: Int,
        tipSwitch: Bool = false, barrelSwitch: Bool = false,
        eraser: Bool = false, invert: Bool = false, inRange: Bool = false
    ) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tipSwitch = tipSwitch
        self.barrelSwitch = barrelSwitch
        self.eraser = eraser
        self.invert = invert
        self.inRange = inRange
    }
}

/// Which physical tool is in use — this maps onto the tablet-event pointer type.
public enum PenTool: Sendable, Equatable {
    case pen
    case eraser
}

extension PenReport {
    public var tool: PenTool {
        (eraser || invert) ? .eraser : .pen
    }
}
