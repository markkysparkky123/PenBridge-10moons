import Foundation

/// One press or release of the tablet's own buttons.
///
/// The buttons are wired to fixed shortcuts in firmware and arrive as ordinary
/// keystrokes, indistinguishable from the keyboard once macOS has processed them.
/// Reading them here, before that happens, is what makes it possible to tell the two
/// apart later.
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
