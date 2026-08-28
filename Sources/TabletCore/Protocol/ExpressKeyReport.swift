import Foundation

/// One press or release of any of the tablet's own buttons.
///
/// The buttons do not all speak the same language. Most send keystrokes; the ones wired
/// to scrolling and to the touch strip send consumer-control usages instead, which macOS
/// turns into scroll wheel and media-key events rather than key presses. Anything that
/// wants to recognise "the user pressed a button on the tablet" has to handle both.
public enum TabletButtonEvent: Sendable, Equatable {
    case keyboard(ExpressKeyEvent)
    case consumer(ConsumerKeyEvent)
    /// The scroll buttons, which some tablets report as a mouse wheel on a second HID
    /// interface. See `MouseReportLayout`.
    case wheel(MouseReportEvent)

    public var isRelease: Bool {
        switch self {
        case .keyboard(let event): return event.isRelease
        case .consumer(let event): return event.isRelease
        case .wheel(let event): return event.isIdle
        }
    }
}

/// One press or release of the tablet's keyboard-type buttons.
///
/// These are wired to fixed shortcuts in firmware and arrive as ordinary keystrokes,
/// indistinguishable from the keyboard once macOS has processed them. Reading them here,
/// before that happens, is what makes it possible to tell the two apart later.
public struct ExpressKeyEvent: Sendable, Equatable {
    /// HID modifier bits: 1 = LeftCtrl, 2 = LeftShift, 4 = LeftAlt, 8 = LeftGUI, and
    /// the right-hand equivalents in the high nibble.
    public let modifiers: UInt8
    /// HID keyboard usages currently held, in report order.
    public let usages: [UInt8]

    public var isRelease: Bool { modifiers == 0 && usages.isEmpty }

    public init(modifiers: UInt8, usages: [UInt8]) {
        self.modifiers = modifiers
        self.usages = usages
    }
}

/// One press or release of the tablet's consumer-control buttons.
///
/// This is the path the scroll-wheel buttons and the touch strip take. macOS turns these
/// usages into scroll wheel and media-key events, neither of which is a key press — which
/// is why watching only the keyboard leaves them untouched.
public struct ConsumerKeyEvent: Sendable, Equatable {
    /// Consumer-page usages currently held. Empty means everything was let go.
    public let usages: [UInt16]

    public var isRelease: Bool { usages.isEmpty }

    public init(usages: [UInt16]) {
        self.usages = usages
    }
}

/// The layout of the tablet's keyboard report, found in the same descriptor as the pen.
public struct ExpressKeyLayout: Sendable {
    public let reportID: UInt8
    public let payloadSize: Int

    private let modifierFields: [HIDReportField]
    private let arrayFields: [HIDReportField]

    /// Locates the keyboard collection. A tablet publishes it alongside the pen so its
    /// buttons work without a driver; that is also why they cannot simply be turned off.
    public init?(fields: [HIDReportField]) {
        let keyboard = fields.filter {
            $0.kind == .input && $0.usagePage == HIDUsagePage.keyboard.rawValue
        }
        guard let reportID = keyboard.first?.reportID else { return nil }

        let mine = keyboard.filter { $0.reportID == reportID }
        // Modifiers are variable fields carrying usages 0xE0…0xE7, one bit each.
        modifierFields = mine.filter { $0.isVariable && (0xE0...0xE7).contains($0.usage) }
        // The pressed-key list is an array field: several entries sharing a usage range.
        arrayFields = mine.filter { !$0.isVariable && !$0.isConstant }
        guard !arrayFields.isEmpty else { return nil }

        self.reportID = reportID
        let bits = fields
            .filter { $0.kind == .input && $0.reportID == reportID }
            .map { $0.bitOffset + $0.bitSize }
            .max() ?? 0
        self.payloadSize = (bits + 7) / 8
    }

    public func decode(_ report: [UInt8]) -> ExpressKeyEvent? {
        guard report.count >= payloadSize else { return nil }

        var modifiers: UInt8 = 0
        for field in modifierFields
        where PenReportLayout.extract(report, bitOffset: field.bitOffset, bitSize: field.bitSize) != 0 {
            // Usage 0xE0 is bit 0, 0xE1 is bit 1, and so on.
            modifiers |= UInt8(1 << (field.usage - 0xE0))
        }

        let usages = arrayFields.compactMap { field -> UInt8? in
            let value = PenReportLayout.extract(
                report, bitOffset: field.bitOffset, bitSize: field.bitSize
            )
            return value == 0 ? nil : UInt8(truncatingIfNeeded: value)
        }

        return ExpressKeyEvent(modifiers: modifiers, usages: usages)
    }
}

/// The layout of the tablet's consumer-control report.
///
/// Declared alongside the pen and the keyboard, and easy to overlook, because nothing
/// about it looks like a button: the report carries a bare usage number from the consumer
/// page. macOS translates those into scroll wheel and media-key events, so a tablet whose
/// scroll buttons appear to be "keys that do not respond" is usually one whose buttons
/// were never keys in the first place.
public struct ConsumerKeyLayout: Sendable {
    public let reportID: UInt8
    public let payloadSize: Int

    /// The array form: one field whose *value* is the usage being pressed.
    private let arrayFields: [HIDReportField]
    /// The bitmap form: one bit per usage, each field carrying its own usage number.
    private let variableFields: [HIDReportField]

    public init?(fields: [HIDReportField]) {
        let consumer = fields.filter {
            $0.kind == .input && $0.usagePage == HIDUsagePage.consumer.rawValue && !$0.isConstant
        }
        guard let reportID = consumer.first?.reportID else { return nil }

        let mine = consumer.filter { $0.reportID == reportID }
        arrayFields = mine.filter { !$0.isVariable }
        variableFields = mine.filter { $0.isVariable }
        guard !arrayFields.isEmpty || !variableFields.isEmpty else { return nil }

        self.reportID = reportID
        let bits = fields
            .filter { $0.kind == .input && $0.reportID == reportID }
            .map { $0.bitOffset + $0.bitSize }
            .max() ?? 0
        self.payloadSize = (bits + 7) / 8
    }

    public func decode(_ report: [UInt8]) -> ConsumerKeyEvent? {
        guard report.count >= payloadSize else { return nil }

        func value(_ field: HIDReportField) -> Int {
            PenReportLayout.extract(report, bitOffset: field.bitOffset, bitSize: field.bitSize)
        }

        // An array field reports which usage is pressed; a variable field is one bit
        // standing for a usage the descriptor already named. Both shapes exist in the
        // wild, and a tablet may use either for its strip.
        var usages = arrayFields
            .map { UInt16(truncatingIfNeeded: value($0)) }
            .filter { $0 != 0 }
        usages += variableFields
            .filter { value($0) != 0 }
            .map { UInt16(truncatingIfNeeded: $0.usage) }

        return ConsumerKeyEvent(usages: usages)
    }
}
