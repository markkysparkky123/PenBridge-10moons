import Foundation

/// What the driver should do when one of the tablet's own buttons is pressed.
public enum ButtonAction: String, Codable, CaseIterable, Sendable {
    /// Leave the firmware shortcut alone.
    case passThrough
    /// Discard it and do nothing in its place.
    case ignore
    case rightClick
    case middleClick

    public var title: String {
        switch self {
        case .passThrough: return "Leave alone"
        case .ignore: return "Do nothing"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        }
    }
}

/// Which button, as far as anything can tell.
///
/// A tablet does not say "this is the pen's upper button". It says a key was pressed, or a
/// consumer usage, or that a wheel turned — so a binding can only be keyed by that
/// signature. It is enough, because every button on this hardware sends a distinct one.
public enum ButtonSource: Codable, Equatable, Hashable, Sendable {
    case key(modifiers: UInt8, usage: UInt8)
    case consumer(usage: UInt16)
    case wheel(up: Bool)
}

/// One button and what it should do.
public struct ButtonBinding: Codable, Equatable, Sendable {
    public var source: ButtonSource
    public var action: ButtonAction

    public init(source: ButtonSource, action: ButtonAction) {
        self.source = source
        self.action = action
    }
}

/// Facts about particular models that cannot be read off their descriptors.
///
/// Kept deliberately small and separate. Everything else in this driver is derived from
/// what the device reports about itself, which is what lets it work on tablets nobody has
/// tested; this is the exception, and marking it as such keeps the two from blurring.
public enum KnownTablets {

    /// The signatures the pen's side buttons send, where they are known.
    ///
    /// The pen's buttons cannot be told from the ones on the case by anything in the
    /// report: both arrive as ordinary keystrokes on the same keyboard report. Only
    /// pressing them and writing down what came out distinguishes them, so that is what
    /// this table is.
    public static func penButtons(
        vendorID: Int, productID: Int
    ) -> (plus: ButtonSource, minus: ButtonSource)? {
        switch (vendorID, productID) {
        case (0x08F2, 0x6811):
            // 10moons 1060Plus. Measured with `penbridge-cli buttons`: the pen's `+`
            // sends Ctrl+Y and `−` sends Ctrl+Z, hovering and with the tip down alike.
            // Its barrel-switch bit is declared in the descriptor and never set.
            return (plus: .key(modifiers: 0x01, usage: 0x1C),
                    minus: .key(modifiers: 0x01, usage: 0x1D))
        default:
            return nil
        }
    }
}
