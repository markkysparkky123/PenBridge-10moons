import Testing
@testable import TabletCore

/// The report descriptor published by the `SZ PING-IT [T501]` digitizer interface,
/// captured from the live device via `IORegistry`'s `ReportDescriptor` property.
private let t501Descriptor: [UInt8] = decodeHex(
    """
    06a0ff0901a10185010902150025ff750895078102150025019540750105081901294091020900\
    150026ff00750895078508b102c005010906a1018502050719e029e715002501750195088102\
    95017508810195057501050819012905910295017503910195057508150025650507190029\
    658100c0050d0901a10185050920a100094209440945093c15002501750195048102750195\
    028101093275019501810281010501093075109501a4550d6513350046401f2600108102\
    093146dc142600108102b4050d093026ff0746ff0755006611e175108102c0c0050c0901\
    a101850419002a3c021500263c02950175108100c0
    """
)

/// The descriptor published by the tablet's *second* HID interface, read out of the same
/// I/O Registry entry. It declares the vendor configuration channel and — the part that is
/// easy to miss and matters a great deal — an ordinary mouse with a wheel, which is where
/// this tablet's scroll buttons report.
private let t501AuxDescriptor: [UInt8] = decodeHex(
    """
    06a0ff0901a10185069508753f150026ff00090119002aff008100c0\
    05010902a10185030901a1000509190129081500250195087501810205011581257f750895030930093109388106c0c0
    """
)

private func decodeHex(_ string: String) -> [UInt8] {
    let cleaned = string.filter(\.isHexDigit)
    return stride(from: 0, to: cleaned.count, by: 2).map { offset in
        let start = cleaned.index(cleaned.startIndex, offsetBy: offset)
        let end = cleaned.index(start, offsetBy: 2)
        return UInt8(cleaned[start..<end], radix: 16)!
    }
}

@Suite("T501 report descriptor")
struct DescriptorTests {

    @Test("The pen report is report ID 5 with a 7-byte payload")
    func penReportShape() throws {
        let layout = try #require(PenReportLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
        #expect(layout.reportID == 5)
        #expect(layout.payloadSize == 7)
    }

    @Test("Field offsets match the hand-decoded protocol table")
    func fieldOffsets() throws {
        let layout = try #require(PenReportLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
        #expect(layout.tipField?.bitOffset == 0)
        #expect(layout.barrelField?.bitOffset == 1)
        #expect(layout.eraserField?.bitOffset == 2)
        #expect(layout.invertField?.bitOffset == 3)
        #expect(layout.inRangeField?.bitOffset == 6)
        #expect(layout.xField.bitOffset == 8)
        #expect(layout.xField.bitSize == 16)
        #expect(layout.yField.bitOffset == 24)
        #expect(layout.pressureField.bitOffset == 40)
        #expect(layout.pressureField.bitSize == 16)
    }

    @Test("Declared ranges and physical size")
    func ranges() throws {
        let layout = try #require(PenReportLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
        #expect(layout.xRange == 0...4096)
        #expect(layout.yRange == 0...4096)
        #expect(layout.pressureRange == 0...2047)

        // 8.000in x 5.340in, declared with unit exponent -3 on the inch unit.
        let width = try #require(layout.widthMM)
        let height = try #require(layout.heightMM)
        #expect(abs(width - 203.2) < 0.01)
        #expect(abs(height - 135.636) < 0.01)
    }

    @Test("This tablet has no tilt support")
    func noTilt() throws {
        let layout = try #require(PenReportLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
        #expect(layout.hasTilt == false)
    }

    @Test("The descriptor also declares keyboard and consumer reports")
    func otherReports() {
        let fields = HIDReportDescriptor.parse(t501Descriptor)
        let inputIDs = Set(fields.filter { $0.kind == .input }.map(\.reportID))
        #expect(inputIDs.contains(2))  // express keys, sent as keyboard usages
        #expect(inputIDs.contains(4))  // consumer control
        #expect(inputIDs.contains(5))  // pen
    }
}

@Suite("Pen report decoding")
struct DecodeTests {

    private func layout() throws -> PenReportLayout {
        try #require(PenReportLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
    }

    @Test("Pen hovering at the centre with no pressure")
    func hovering() throws {
        // in-range set, tip clear; X = 0x0800, Y = 0x0800, pressure = 0.
        let payload: [UInt8] = [0b0100_0000, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00]
        let report = try #require(layout().decode(payload))
        #expect(report.inRange)
        #expect(!report.tipSwitch)
        #expect(report.x == 2048)
        #expect(report.y == 2048)
        #expect(report.pressure == 0)
        #expect(report.tool == .pen)
    }

    @Test("Pen pressed near full scale")
    func pressed() throws {
        // in-range + tip; X = 0x0FFF, Y = 0x0001, pressure = 0x07FF.
        let payload: [UInt8] = [0b0100_0001, 0xFF, 0x0F, 0x01, 0x00, 0xFF, 0x07]
        let report = try #require(layout().decode(payload))
        #expect(report.tipSwitch)
        #expect(report.x == 4095)
        #expect(report.y == 1)
        #expect(report.pressure == 2047)
    }

    @Test("Barrel button and eraser are distinct bits")
    func buttons() throws {
        let barrel: [UInt8] = [0b0100_0010, 0, 0, 0, 0, 0, 0]
        let eraser: [UInt8] = [0b0100_0100, 0, 0, 0, 0, 0, 0]

        let barrelReport = try #require(layout().decode(barrel))
        #expect(barrelReport.barrelSwitch)
        #expect(!barrelReport.eraser)
        #expect(barrelReport.tool == .pen)

        let eraserReport = try #require(layout().decode(eraser))
        #expect(eraserReport.eraser)
        #expect(!eraserReport.barrelSwitch)
        #expect(eraserReport.tool == .eraser)
    }

    @Test("Pen lifted out of range")
    func outOfRange() throws {
        let payload: [UInt8] = [0b0000_0000, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00]
        let report = try #require(layout().decode(payload))
        #expect(!report.inRange)
    }

    @Test("A truncated report is rejected rather than decoded as garbage")
    func truncated() throws {
        let decoded = try layout().decode([0x40, 0x00, 0x08])
        #expect(decoded == nil)
    }
}

@Suite("Tablet button decoding")
struct ButtonDecodeTests {

    private func expressKeys() throws -> ExpressKeyLayout {
        try #require(ExpressKeyLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
    }

    private func consumerKeys() throws -> ConsumerKeyLayout {
        try #require(ConsumerKeyLayout(fields: HIDReportDescriptor.parse(t501Descriptor)))
    }

    @Test("The keyboard buttons are report ID 2, boot-keyboard shaped")
    func expressKeyShape() throws {
        let layout = try expressKeys()
        #expect(layout.reportID == 2)
        // One modifier byte, one reserved byte, five key slots.
        #expect(layout.payloadSize == 7)
    }

    @Test("A keyboard button press decodes to its usage and modifiers")
    func expressKeyPress() throws {
        // Button 3 of the measured set: Ctrl + Keypad −.
        let event = try #require(expressKeys().decode([0x01, 0x00, 0x56, 0, 0, 0, 0]))
        #expect(event.modifiers == 0x01)
        #expect(event.usages == [0x56])
        #expect(!event.isRelease)
    }

    @Test("An all-zero keyboard report is a release")
    func expressKeyRelease() throws {
        let event = try #require(expressKeys().decode([0, 0, 0, 0, 0, 0, 0]))
        #expect(event.isRelease)
    }

    @Test("The scroll and touch-strip buttons are a separate consumer report")
    func consumerShape() throws {
        let layout = try consumerKeys()
        // Report ID 4, a single 16-bit usage. This is the path that carries the buttons
        // macOS turns into scrolling and media keys — not keystrokes, which is why
        // watching only the keyboard misses them.
        #expect(layout.reportID == 4)
        #expect(layout.payloadSize == 2)
    }

    @Test("A consumer usage decodes little-endian, and zero is a release")
    func consumerPress() throws {
        let layout = try consumerKeys()

        // Volume Up, usage 0x00E9.
        let pressed = try #require(layout.decode([0xE9, 0x00]))
        #expect(pressed.usages == [0x00E9])
        #expect(!pressed.isRelease)

        // Browser Home, usage 0x0223 — two bytes wide, so it catches a byte-order slip.
        let wide = try #require(layout.decode([0x23, 0x02]))
        #expect(wide.usages == [0x0223])

        let released = try #require(layout.decode([0x00, 0x00]))
        #expect(released.isRelease)
    }

    @Test("A truncated consumer report is rejected")
    func consumerTruncated() throws {
        #expect(try consumerKeys().decode([0xE9]) == nil)
    }
}

@Suite("The tablet's second interface")
struct AuxInterfaceTests {

    private func mouse() throws -> MouseReportLayout {
        try #require(MouseReportLayout(fields: HIDReportDescriptor.parse(t501AuxDescriptor)))
    }

    @Test("The scroll buttons are a mouse wheel, not keys")
    func shape() throws {
        let layout = try mouse()
        // Report ID 3: eight buttons, then X, Y and Wheel as signed bytes.
        #expect(layout.reportID == 3)
        #expect(layout.payloadSize == 4)
    }

    @Test("This interface carries no digitizer usage, which is why it goes unnoticed")
    func noDigitizer() {
        let fields = HIDReportDescriptor.parse(t501AuxDescriptor)
        #expect(!fields.contains { $0.usagePage == HIDUsagePage.digitizer.rawValue })
        // Matching tablets by their digitizer usage — the sensible thing to do — therefore
        // never opens it, and the scroll buttons look like they send nothing at all.
        #expect(PenReportLayout(fields: fields) == nil)
    }

    @Test("Wheel movement is signed, so scrolling back is not a huge scroll forward")
    func wheelDirection() throws {
        let layout = try mouse()

        let up = try #require(layout.decode([0x00, 0x00, 0x00, 0x01]))
        #expect(up.wheel == 1)
        #expect(up.buttons == 0)

        let down = try #require(layout.decode([0x00, 0x00, 0x00, 0xFF]))
        #expect(down.wheel == -1)

        let idle = try #require(layout.decode([0x00, 0x00, 0x00, 0x00]))
        #expect(idle.isIdle)
    }

    @Test("Buttons on that interface decode to a bitmap")
    func buttons() throws {
        let event = try #require(mouse().decode([0b0000_0101, 0x00, 0x00, 0x00]))
        #expect(event.buttons == 0b0000_0101)
        #expect(!event.isIdle)
    }

    @Test("A plain mouse descriptor with no wheel is not adopted")
    func requiresWheel() {
        // Buttons and axes only — nothing a tablet driver needs, and adopting it would
        // mean opening the user's actual mouse.
        let noWheel = decodeHex(
            """
            05010902a10185030901a100\
            0509190129081500250195087501810205011581257f75089502093009318106c0c0
            """
        )
        #expect(MouseReportLayout(fields: HIDReportDescriptor.parse(noWheel)) == nil)
    }
}
