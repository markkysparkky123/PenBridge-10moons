import Foundation

/// The layout of the pen's input report, derived from a parsed HID report descriptor.
///
/// Nothing here is hardcoded for a particular tablet: the offsets, sizes and ranges all
/// come from the descriptor the device itself publishes. That is what lets the same code
/// pick up a different model without a new build.
public struct PenReportLayout: Sendable {
    public let reportID: UInt8
    /// Total payload size in bytes, excluding the leading report-ID byte.
    public let payloadSize: Int

    public let xRange: ClosedRange<Int>
    public let yRange: ClosedRange<Int>
    public let pressureRange: ClosedRange<Int>

    /// Active area in millimetres, if the descriptor declares a physical extent.
    public let widthMM: Double?
    public let heightMM: Double?

    /// True when the device reports pen tilt. This tablet does not.
    public let hasTilt: Bool

    public let xField: HIDReportField
    public let yField: HIDReportField
    public let pressureField: HIDReportField
    public let tipField: HIDReportField?
    public let barrelField: HIDReportField?
    public let eraserField: HIDReportField?
    public let invertField: HIDReportField?
    public let inRangeField: HIDReportField?

    /// Finds the digitizer's pen report among all the fields of a descriptor.
    ///
    /// A tablet typically publishes several unrelated reports (keyboard, consumer
    /// control, vendor config); the pen is the one carrying X, Y and tip pressure.
    public init?(fields: [HIDReportField]) {
        let inputs = fields.filter { $0.kind == .input && !$0.isConstant }
        let byReport = Dictionary(grouping: inputs, by: \.reportID)

        func find(_ candidates: [HIDReportField], page: UInt32, usage: UInt32) -> HIDReportField? {
            candidates.first { $0.usagePage == page && $0.usage == usage }
        }

        let match = byReport.compactMap { id, candidates -> (UInt8, HIDReportField, HIDReportField, HIDReportField)? in
            guard
                let x = find(candidates, page: HIDUsagePage.genericDesktop.rawValue, usage: GenericDesktopUsage.x.rawValue),
                let y = find(candidates, page: HIDUsagePage.genericDesktop.rawValue, usage: GenericDesktopUsage.y.rawValue),
                let pressure = find(candidates, page: HIDUsagePage.digitizer.rawValue, usage: DigitizerUsage.tipPressure.rawValue)
            else { return nil }
            return (id, x, y, pressure)
        }.min { $0.0 < $1.0 }

        guard let (id, x, y, pressure) = match else { return nil }

        let candidates = byReport[id] ?? []
        let digitizer = HIDUsagePage.digitizer.rawValue

        self.reportID = id
        self.xField = x
        self.yField = y
        self.pressureField = pressure
        self.tipField = find(candidates, page: digitizer, usage: DigitizerUsage.tipSwitch.rawValue)
        self.barrelField = find(candidates, page: digitizer, usage: DigitizerUsage.barrelSwitch.rawValue)
        self.eraserField = find(candidates, page: digitizer, usage: DigitizerUsage.eraser.rawValue)
        self.invertField = find(candidates, page: digitizer, usage: DigitizerUsage.invert.rawValue)
        self.inRangeField = find(candidates, page: digitizer, usage: DigitizerUsage.inRange.rawValue)

        self.xRange = x.logicalMin...max(x.logicalMax, x.logicalMin + 1)
        self.yRange = y.logicalMin...max(y.logicalMax, y.logicalMin + 1)
        self.pressureRange = pressure.logicalMin...max(pressure.logicalMax, pressure.logicalMin + 1)

        self.hasTilt =
            find(candidates, page: digitizer, usage: DigitizerUsage.xTilt.rawValue) != nil
            || find(candidates, page: digitizer, usage: DigitizerUsage.yTilt.rawValue) != nil

        // The descriptor states the physical extent in inches with a unit exponent;
        // everything downstream is easier to reason about in millimetres.
        self.widthMM = x.physicalExtent.map { $0 * 25.4 }
        self.heightMM = y.physicalExtent.map { $0 * 25.4 }

        // All fields of this report, including padding, determine the payload length.
        let allBits = fields
            .filter { $0.kind == .input && $0.reportID == id }
            .map { $0.bitOffset + $0.bitSize }
            .max() ?? 0
        self.payloadSize = (allBits + 7) / 8
    }

    /// Decodes one raw HID input report.
    ///
    /// `report` is the payload *without* the report-ID byte, which is how
    /// `IOHIDDeviceRegisterInputReportCallback` delivers it.
    public func decode(_ report: [UInt8]) -> PenReport? {
        guard report.count >= payloadSize else { return nil }

        func bits(_ field: HIDReportField) -> Int {
            Self.extract(report, bitOffset: field.bitOffset, bitSize: field.bitSize)
        }
        func flag(_ field: HIDReportField?) -> Bool {
            guard let field else { return false }
            return bits(field) != 0
        }

        return PenReport(
            x: bits(xField),
            y: bits(yField),
            pressure: bits(pressureField),
            tipSwitch: flag(tipField),
            barrelSwitch: flag(barrelField),
            eraser: flag(eraserField),
            invert: flag(invertField),
            // A descriptor without an explicit in-range bit means the device only
            // reports while the pen is tracked at all.
            inRange: inRangeField.map { bits($0) != 0 } ?? true
        )
    }

    /// Reads an little-endian bit field of arbitrary offset and width.
    static func extract(_ bytes: [UInt8], bitOffset: Int, bitSize: Int) -> Int {
        guard bitSize > 0, bitSize <= 32 else { return 0 }
        var value: UInt32 = 0
        for index in 0..<bitSize {
            let bit = bitOffset + index
            let byte = bit / 8
            guard byte < bytes.count else { break }
            if bytes[byte] & (1 << UInt8(bit % 8)) != 0 {
                value |= 1 << UInt32(index)
            }
        }
        return Int(value)
    }
}
