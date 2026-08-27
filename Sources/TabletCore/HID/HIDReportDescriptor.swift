import Foundation

/// Kind of report a field belongs to.
public enum HIDReportKind: Sendable, Hashable {
    case input, output, feature
}

/// Well-known HID usage pages we care about.
public enum HIDUsagePage: UInt32, Sendable {
    case genericDesktop = 0x01
    case keyboard = 0x07
    case led = 0x08
    case consumer = 0x0C
    case digitizer = 0x0D
}

/// Usages within the digitizer page (0x0D).
public enum DigitizerUsage: UInt32, Sendable {
    case tipPressure = 0x30
    case xTilt = 0x3D
    case yTilt = 0x3E
    case inRange = 0x32
    case invert = 0x3C
    case tipSwitch = 0x42
    case barrelSwitch = 0x44
    case eraser = 0x45
}

/// Usages within the generic desktop page (0x01).
public enum GenericDesktopUsage: UInt32, Sendable {
    case x = 0x30
    case y = 0x31
}

/// One data field extracted from a report descriptor.
///
/// `bitOffset` is measured from the start of the report *payload*, i.e. it already
/// excludes the leading report-ID byte when the descriptor declares report IDs.
public struct HIDReportField: Sendable, Hashable {
    public let reportID: UInt8
    public let kind: HIDReportKind
    public let usagePage: UInt32
    public let usage: UInt32
    public let bitOffset: Int
    public let bitSize: Int
    public let logicalMin: Int
    public let logicalMax: Int
    public let physicalMin: Int
    public let physicalMax: Int
    public let unit: UInt32
    public let unitExponent: Int
    /// Bit 0 of the Input/Output/Feature item: 1 = constant (padding), 0 = data.
    public let isConstant: Bool
    /// Bit 1: 1 = variable, 0 = array.
    public let isVariable: Bool
    /// Bit 2: 1 = relative, 0 = absolute.
    public let isRelative: Bool

    /// Physical extent in the descriptor's declared unit, applying the unit exponent.
    /// Returns `nil` when the descriptor declares no meaningful physical range.
    public var physicalExtent: Double? {
        guard physicalMax != physicalMin else { return nil }
        return Double(physicalMax - physicalMin) * pow(10.0, Double(unitExponent))
    }
}

/// A minimal but spec-correct HID report descriptor parser.
///
/// It walks short items (and skips long items), maintaining the global/local item
/// state machine described in the HID 1.11 specification, and flattens every
/// Input/Output/Feature main item into a list of `HIDReportField`s.
public enum HIDReportDescriptor {

    public static func parse(_ bytes: [UInt8]) -> [HIDReportField] {
        var fields: [HIDReportField] = []
        var global = GlobalState()
        var globalStack: [GlobalState] = []
        var local = LocalState()
        // Bit cursor per (reportID, kind) — each report has its own independent layout.
        var cursors: [Cursor: Int] = [:]

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            i += 1

            // Long item: 0b1111_1110. Size byte, tag byte, then payload — we skip it.
            if prefix == 0xFE {
                guard i < bytes.count else { break }
                let dataSize = Int(bytes[i])
                i += 2 + dataSize
                continue
            }

            let rawSize = Int(prefix & 0b11)
            let size = rawSize == 3 ? 4 : rawSize
            let type = (prefix >> 2) & 0b11
            let tag = (prefix >> 4) & 0b1111

            guard i + size <= bytes.count else { break }
            let raw = unsigned(bytes[i..<i + size])
            i += size

            switch type {
            case 0: // Main
                switch tag {
                case 0x8, 0x9, 0xB:
                    let kind: HIDReportKind = tag == 0x8 ? .input : (tag == 0x9 ? .output : .feature)
                    let cursor = Cursor(reportID: global.reportID, kind: kind)
                    var offset = cursors[cursor] ?? 0
                    emit(
                        into: &fields, at: &offset, flags: raw,
                        kind: kind, global: global, local: local
                    )
                    cursors[cursor] = offset
                case 0xA: // Collection
                    break
                case 0xC: // End Collection
                    break
                default:
                    break
                }
                local = LocalState()

            case 1: // Global
                switch tag {
                case 0x0: global.usagePage = raw
                case 0x1: global.logicalMin = signed(raw, size: size)
                case 0x2: global.logicalMax = maybeSigned(raw, size: size, min: global.logicalMin)
                case 0x3: global.physicalMin = signed(raw, size: size)
                case 0x4: global.physicalMax = maybeSigned(raw, size: size, min: global.physicalMin)
                case 0x5: global.unitExponent = nibbleSigned(raw)
                case 0x6: global.unit = raw
                case 0x7: global.reportSize = Int(raw)
                case 0x8: global.reportID = UInt8(truncatingIfNeeded: raw)
                case 0x9: global.reportCount = Int(raw)
                case 0xA: globalStack.append(global)
                case 0xB: if let popped = globalStack.popLast() { global = popped }
                default: break
                }

            case 2: // Local
                switch tag {
                case 0x0: local.usages.append(qualify(raw, page: global.usagePage, size: size))
                case 0x1: local.usageMin = qualify(raw, page: global.usagePage, size: size)
                case 0x2: local.usageMax = qualify(raw, page: global.usagePage, size: size)
                default: break
                }

            default:
                break
            }
        }

        return fields
    }

    // MARK: - Emission

    private static func emit(
        into fields: inout [HIDReportField],
        at offset: inout Int,
        flags: UInt32,
        kind: HIDReportKind,
        global: GlobalState,
        local: LocalState
    ) {
        let isConstant = flags & 0b1 != 0
        let isVariable = flags & 0b10 != 0
        let isRelative = flags & 0b100 != 0

        for index in 0..<global.reportCount {
            // A variable item maps usages one-to-one onto its entries; an array item
            // shares the whole usage range across every entry.
            let usage: UInt32
            if isVariable {
                if index < local.usages.count {
                    usage = local.usages[index]
                } else if let last = local.usages.last, local.usageMin == nil {
                    usage = last
                } else if let min = local.usageMin {
                    usage = min + UInt32(index)
                } else {
                    usage = 0
                }
            } else {
                usage = local.usages.first ?? local.usageMin ?? 0
            }

            fields.append(
                HIDReportField(
                    reportID: global.reportID,
                    kind: kind,
                    usagePage: usage >> 16 != 0 ? usage >> 16 : global.usagePage,
                    usage: usage & 0xFFFF,
                    bitOffset: offset,
                    bitSize: global.reportSize,
                    logicalMin: global.logicalMin,
                    logicalMax: global.logicalMax,
                    physicalMin: global.physicalMin == 0 && global.physicalMax == 0
                        ? global.logicalMin : global.physicalMin,
                    physicalMax: global.physicalMin == 0 && global.physicalMax == 0
                        ? global.logicalMax : global.physicalMax,
                    unit: global.unit,
                    unitExponent: global.unitExponent,
                    isConstant: isConstant,
                    isVariable: isVariable,
                    isRelative: isRelative
                )
            )
            offset += global.reportSize
        }
    }

    // MARK: - Item state

    private struct Cursor: Hashable {
        let reportID: UInt8
        let kind: HIDReportKind
    }

    private struct GlobalState {
        var usagePage: UInt32 = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var physicalMin: Int = 0
        var physicalMax: Int = 0
        var unit: UInt32 = 0
        var unitExponent: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: UInt8 = 0
    }

    private struct LocalState {
        var usages: [UInt32] = []
        var usageMin: UInt32?
        var usageMax: UInt32?
    }

    // MARK: - Value decoding

    private static func unsigned(_ slice: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0
        for (shift, byte) in slice.enumerated() {
            value |= UInt32(byte) << (8 * shift)
        }
        return value
    }

    private static func signed(_ raw: UInt32, size: Int) -> Int {
        switch size {
        case 1: return Int(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case 2: return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case 4: return Int(Int32(bitPattern: raw))
        default: return Int(raw)
        }
    }

    /// Logical/physical maximums are signed per spec, but devices routinely write
    /// `0xFF` meaning 255. When the corresponding minimum is non-negative, a negative
    /// maximum is nonsense, so reinterpret it as unsigned.
    private static func maybeSigned(_ raw: UInt32, size: Int, min: Int) -> Int {
        let value = signed(raw, size: size)
        if min >= 0 && value < 0 { return Int(raw) }
        return value
    }

    /// Unit Exponent is a 4-bit two's-complement nibble: 0x0…0x7 map to 0…7, 0x8…0xF to -8…-1.
    private static func nibbleSigned(_ raw: UInt32) -> Int {
        let nibble = raw & 0xF
        return nibble > 7 ? Int(nibble) - 16 : Int(nibble)
    }

    /// A 4-byte usage item carries the page in its high half; 1- and 2-byte items
    /// inherit the current global usage page.
    private static func qualify(_ raw: UInt32, page: UInt32, size: Int) -> UInt32 {
        size == 4 ? raw : (page << 16) | (raw & 0xFFFF)
    }
}
