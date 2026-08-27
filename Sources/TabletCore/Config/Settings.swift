import CoreGraphics
import Foundation

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
        barrelSwitchRightClicks: Bool = true,
        isEnabled: Bool = true
    ) {
        self.area = area
        self.preserveAspectRatio = preserveAspectRatio
        self.rotation = rotation
        self.displayID = displayID
        self.pressure = pressure
        self.barrelSwitchRightClicks = barrelSwitchRightClicks
        self.isEnabled = isEnabled
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
