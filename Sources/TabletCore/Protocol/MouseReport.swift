import Foundation

/// One sample from a tablet's mouse-shaped interface.
public struct MouseReportEvent: Sendable, Equatable {
    /// Button bitmap, bit 0 being button 1.
    public let buttons: UInt8
    public let deltaX: Int
    public let deltaY: Int
    /// Wheel movement, positive up. This is what a tablet's scroll buttons send.
    public let wheel: Int

    public var isIdle: Bool { buttons == 0 && deltaX == 0 && deltaY == 0 && wheel == 0 }

    public init(buttons: UInt8, deltaX: Int, deltaY: Int, wheel: Int) {
        self.buttons = buttons
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.wheel = wheel
    }
}

/// The layout of a mouse collection, as some tablets publish on a second HID interface.
///
/// Worth stating plainly, because it is not what anyone expects to find on a graphics
/// tablet and it hides an entire class of buttons: this tablet's scroll buttons are not
/// keys and not consumer controls. They are a *mouse wheel*, declared on an interface of
/// its own that carries no digitizer usage at all. macOS turns that wheel into ordinary
/// scroll events, and a driver that matches tablets by their digitizer usage — the
/// sensible thing to do, and what `TabletDeviceMonitor` does — never opens that interface
/// and so never learns those buttons exist.
///
/// The symptom is a button that plainly works while the driver swears nothing was pressed.
public struct MouseReportLayout: Sendable {
    public let reportID: UInt8
    public let payloadSize: Int

    private let buttonFields: [HIDReportField]
    private let xField: HIDReportField?
    private let yField: HIDReportField?
    private let wheelField: HIDReportField?

    public init?(fields: [HIDReportField]) {
        let inputs = fields.filter { $0.kind == .input && !$0.isConstant }

        // The buttons carry the button usage page; the axes are generic desktop. Both live
        // under the same report, which is what identifies it.
        let buttons = inputs.filter { $0.usagePage == HIDUsagePage.button.rawValue }
        let axes = inputs.filter {
            $0.usagePage == HIDUsagePage.genericDesktop.rawValue
                && [GenericDesktopUsage.x.rawValue,
                    GenericDesktopUsage.y.rawValue,
                    GenericDesktopUsage.wheel.rawValue].contains($0.usage)
        }
        guard let reportID = (buttons.first ?? axes.first)?.reportID else { return nil }

        let mine = inputs.filter { $0.reportID == reportID }
        buttonFields = mine.filter { $0.usagePage == HIDUsagePage.button.rawValue }
        func axis(_ usage: GenericDesktopUsage) -> HIDReportField? {
            mine.first {
                $0.usagePage == HIDUsagePage.genericDesktop.rawValue && $0.usage == usage.rawValue
            }
        }
        xField = axis(.x)
        yField = axis(.y)
        wheelField = axis(.wheel)

        // A wheel is the whole reason for reading this interface. Without one there is
        // nothing here a tablet driver needs, and opening it would only risk grabbing an
        // ordinary mouse.
        guard wheelField != nil else { return nil }

        self.reportID = reportID
        let bits = fields
            .filter { $0.kind == .input && $0.reportID == reportID }
            .map { $0.bitOffset + $0.bitSize }
            .max() ?? 0
        self.payloadSize = (bits + 7) / 8
    }

    public func decode(_ report: [UInt8]) -> MouseReportEvent? {
        guard report.count >= payloadSize else { return nil }

        var buttons: UInt8 = 0
        for (index, field) in buttonFields.enumerated() where index < 8 {
            if PenReportLayout.extract(report, bitOffset: field.bitOffset, bitSize: field.bitSize) != 0 {
                buttons |= UInt8(1 << index)
            }
        }

        return MouseReportEvent(
            buttons: buttons,
            deltaX: signed(report, xField),
            deltaY: signed(report, yField),
            wheel: signed(report, wheelField)
        )
    }

    /// Movement is relative and therefore signed: the descriptor declares −127…127, and
    /// reading it unsigned turns every backwards scroll into a large forwards one.
    private func signed(_ report: [UInt8], _ field: HIDReportField?) -> Int {
        guard let field else { return 0 }
        let raw = PenReportLayout.extract(report, bitOffset: field.bitOffset, bitSize: field.bitSize)
        guard field.logicalMin < 0, field.bitSize > 0, field.bitSize < 64 else { return raw }
        let half = 1 << (field.bitSize - 1)
        return raw >= half ? raw - (half << 1) : raw
    }
}
