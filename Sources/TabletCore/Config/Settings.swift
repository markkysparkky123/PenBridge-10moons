import CoreGraphics
import Foundation

/// Measured coordinate limits, overriding what the descriptor claims.
///
/// Tablets are routinely inaccurate about their own range — this one declares
/// `0…4096` on both axes but never reports above 4095. Left unchecked that shows up as
/// a cursor that cannot quite reach one edge of the screen, or that runs out of tablet
/// before it gets there. `penbridge-cli calibrate --apply` fills these in from a
/// measurement; `nil` means "trust the descriptor".
public struct Calibration: Codable, Equatable, Sendable {
    public var xMin: Int?
    public var xMax: Int?
    public var yMin: Int?
    public var yMax: Int?

    public init(xMin: Int? = nil, xMax: Int? = nil, yMin: Int? = nil, yMax: Int? = nil) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    public func xRange(orDeclared declared: ClosedRange<Int>) -> ClosedRange<Int> {
        Self.range(xMin, xMax, declared)
    }

    public func yRange(orDeclared declared: ClosedRange<Int>) -> ClosedRange<Int> {
        Self.range(yMin, yMax, declared)
    }

    private static func range(
        _ low: Int?, _ high: Int?, _ declared: ClosedRange<Int>
    ) -> ClosedRange<Int> {
        let lower = low ?? declared.lowerBound
        let upper = high ?? declared.upperBound
        // A calibration that survived a bad measurement must not produce an invalid
        // range and take the cursor with it.
        guard upper > lower else { return declared }
        return lower...upper
    }
}

/// User-visible configuration, persisted as JSON next to the app's support files.
public struct Settings: Codable, Equatable, Sendable {

    /// Portion of the tablet's active area to use, normalized 0…1 from the top-left.
    public var area: NormalizedRect
    /// Trim `area` to the screen's shape so proportions are preserved.
    public var preserveAspectRatio: Bool
    public var rotation: TabletRotation
    /// Display to map onto, by `CGDirectDisplayID`. `nil` means the main display.
    public var displayID: UInt32?
    public var pressure: PressureCurve
    /// Measured coordinate limits; empty means trust the descriptor.
    public var calibration: Calibration
    /// Send the barrel switch as a right-click.
    public var barrelSwitchRightClicks: Bool
    /// Master switch for the menu-bar item.
    public var isEnabled: Bool

    public init(
        area: NormalizedRect = .full,
        preserveAspectRatio: Bool = true,
        rotation: TabletRotation = .none,
        displayID: UInt32? = nil,
        pressure: PressureCurve = .linear,
        calibration: Calibration = Calibration(),
        barrelSwitchRightClicks: Bool = true,
        isEnabled: Bool = true
    ) {
        self.area = area
        self.preserveAspectRatio = preserveAspectRatio
        self.rotation = rotation
        self.displayID = displayID
        self.pressure = pressure
        self.calibration = calibration
        self.barrelSwitchRightClicks = barrelSwitchRightClicks
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case area, preserveAspectRatio, rotation, displayID, pressure
        case calibration, barrelSwitchRightClicks, isEnabled
    }

    /// Decoded field by field so a config written by an older build — one without
    /// `calibration`, say — still loads instead of falling back to defaults wholesale.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        area = try container.decodeIfPresent(NormalizedRect.self, forKey: .area) ?? defaults.area
        preserveAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .preserveAspectRatio)
            ?? defaults.preserveAspectRatio
        rotation = try container.decodeIfPresent(TabletRotation.self, forKey: .rotation) ?? defaults.rotation
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        pressure = try container.decodeIfPresent(PressureCurve.self, forKey: .pressure) ?? defaults.pressure
        calibration = try container.decodeIfPresent(Calibration.self, forKey: .calibration)
            ?? defaults.calibration
        barrelSwitchRightClicks = try container.decodeIfPresent(Bool.self, forKey: .barrelSwitchRightClicks)
            ?? defaults.barrelSwitchRightClicks
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
    }

    // MARK: - Persistence

    public static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PenBridge/config.json")
    }

    /// Loads saved settings, falling back to defaults when the file is missing or
    /// unreadable — a corrupt config should never stop the tablet from working.
    public static func load(from url: URL = storeURL) -> Settings {
        guard
            let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    public func save(to url: URL = storeURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// `CGRect` is not `Codable` in a form worth persisting, and normalized coordinates
/// deserve a name that says they are fractions rather than points.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
