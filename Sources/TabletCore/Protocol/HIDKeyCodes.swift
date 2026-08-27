import Foundation

/// Translation between HID keyboard usages and the virtual key codes macOS puts in
/// `CGEvent`s.
///
/// Needed to recognise, in the event stream, the keystroke a tablet button has just
/// caused. The two numbering schemes are unrelated: HID usage `0x05` is the letter B,
/// while macOS virtual key code `0x05` is the letter G.
public enum HIDKeyCodes {

    /// HID keyboard usage → macOS virtual key code.
    ///
    /// Covers the printable keys and the few others a tablet's buttons are bound to.
    /// The layout is positional on both sides, so this holds regardless of the keyboard
    /// layout the user has selected.
    public static let usageToVirtual: [UInt8: UInt16] = [
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02,  // a b c d
        0x08: 0x0E, 0x09: 0x03, 0x0A: 0x05, 0x0B: 0x04,  // e f g h
        0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25,  // i j k l
        0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23,  // m n o p
        0x14: 0x0C, 0x15: 0x0F, 0x16: 0x01, 0x17: 0x11,  // q r s t
        0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,  // u v w x
        0x1C: 0x10, 0x1D: 0x06,                          // y z
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15,  // 1 2 3 4
        0x22: 0x17, 0x23: 0x16, 0x24: 0x1A, 0x25: 0x1C,  // 5 6 7 8
        0x26: 0x19, 0x27: 0x1D,                          // 9 0
        0x28: 0x24,  // Return
        0x29: 0x35,  // Escape
        0x2A: 0x33,  // Delete
        0x2B: 0x30,  // Tab
        0x2C: 0x31,  // Space
        0x2D: 0x1B,  // -
        0x2E: 0x18,  // =
        0x2F: 0x21,  // [
        0x30: 0x1E,  // ]
        0x31: 0x2A,  // backslash
        0x33: 0x29,  // ;
        0x34: 0x27,  // '
        0x35: 0x32,  // `
        0x36: 0x2B,  // ,
        0x37: 0x2F,  // .
        0x38: 0x2C,  // /
        0x39: 0x39,  // Caps Lock
        0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77,  // Home PageUp FwdDel End
        0x4E: 0x79,                                      // PageDown
        0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,  // arrows: right left down up
        0x56: 0x4E,  // Keypad -
        0x57: 0x45,  // Keypad +
    ]

    /// Whether a virtual key code could have come from the given HID usage.
    public static func matches(usage: UInt8, virtualKey: UInt16) -> Bool {
        usageToVirtual[usage] == virtualKey
    }

    /// A readable name for a HID usage, for menus and diagnostics.
    public static func name(usage: UInt8, modifiers: UInt8) -> String {
        var parts: [String] = []
        if modifiers & 0x01 != 0 || modifiers & 0x10 != 0 { parts.append("Ctrl") }
        if modifiers & 0x02 != 0 || modifiers & 0x20 != 0 { parts.append("Shift") }
        if modifiers & 0x04 != 0 || modifiers & 0x40 != 0 { parts.append("Opt") }
        if modifiers & 0x08 != 0 || modifiers & 0x80 != 0 { parts.append("Cmd") }
        if let key = keyName(usage) { parts.append(key) }
        return parts.isEmpty ? "—" : parts.joined(separator: "+")
    }

    private static func keyName(_ usage: UInt8) -> String? {
        switch usage {
        case 0: return nil
        case 0x04...0x1D:
            return String(UnicodeScalar(UInt8(0x61 + usage - 0x04)))
        case 0x1E...0x26:
            return String(usage - 0x1E + 1)
        case 0x27: return "0"
        case 0x28: return "Return"
        case 0x29: return "Esc"
        case 0x2A: return "Delete"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x31: return "\\"
        case 0x4F: return "Right"
        case 0x50: return "Left"
        case 0x51: return "Down"
        case 0x52: return "Up"
        case 0x56: return "Keypad −"
        case 0x57: return "Keypad +"
        default: return String(format: "usage 0x%02X", usage)
        }
    }
}
