import CoreGraphics
import Foundation
import Testing
@testable import TabletCore

@Suite("Calibration")
struct CalibrationTests {

    private let declared = 0...4096

    @Test("An empty calibration defers to the descriptor")
    func empty() {
        let calibration = Calibration()
        #expect(calibration.xRange(orDeclared: declared) == declared)
        #expect(calibration.yRange(orDeclared: declared) == declared)
    }

    @Test("Measured limits override the declared ones")
    func measured() {
        // What the T501 actually reports: one short of its declared maximum.
        let calibration = Calibration(xMin: 0, xMax: 4095, yMin: 0, yMax: 4095)
        #expect(calibration.xRange(orDeclared: declared) == 0...4095)
        #expect(calibration.yRange(orDeclared: declared) == 0...4095)
    }

    @Test("A partial calibration fills the rest from the descriptor")
    func partial() {
        let calibration = Calibration(xMax: 4000)
        #expect(calibration.xRange(orDeclared: declared) == 0...4000)
        #expect(calibration.yRange(orDeclared: declared) == declared)
    }

    @Test("An inverted range is rejected rather than breaking the mapping")
    func inverted() {
        let calibration = Calibration(xMin: 3000, xMax: 100)
        #expect(calibration.xRange(orDeclared: declared) == declared)
    }

    @Test("Calibrated limits reach the screen edge where declared ones fall short")
    func reachesTheEdge() {
        let layout = PenReportLayout(fields: HIDReportDescriptor.parse(penDescriptor))!
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mapper = AreaMapper(screen: screen)

        // The highest value the hardware ever produces is 4095.
        let uncalibrated = mapper.map(x: 4095, y: 4095, layout: layout)
        #expect(uncalibrated.x < 1920)

        let calibration = Calibration(xMin: 0, xMax: 4095, yMin: 0, yMax: 4095)
        let calibrated = mapper.map(
            x: 4095, y: 4095,
            xRange: calibration.xRange(orDeclared: layout.xRange),
            yRange: calibration.yRange(orDeclared: layout.yRange)
        )
        #expect(calibrated.x == 1920)
        #expect(calibrated.y == 1080)
    }

    @Test("Pressure thresholds let a hand that reaches 82% of scale still hit full")
    func pressureHeadroom() {
        // Measured on the T501: a firm press reads 1685 of a declared 2047.
        var curve = PressureCurve.linear
        curve.lowerThreshold = 5.0 / 2047.0
        curve.upperThreshold = 1685.0 / 2047.0

        #expect(curve.apply(1685, range: 0...2047) == 1.0)
        #expect(curve.apply(5, range: 0...2047) == 0.0)
        // Halfway up the usable band, not halfway up the raw scale.
        let middle = curve.apply(845, range: 0...2047)
        #expect(abs(middle - 0.5) < 0.01)

        // Without the calibration the same firm press falls well short of full.
        #expect(PressureCurve.linear.apply(1685, range: 0...2047) < 0.83)
    }

    @Test("A config written before calibration existed still loads")
    func forwardCompatibility() throws {
        let legacy = """
            {"area":{"x":0,"y":0,"width":1,"height":1},"isEnabled":true,"rotation":90}
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        #expect(settings.rotation == .ninety)
        #expect(settings.isEnabled)
        #expect(settings.calibration == Calibration())
        // Fields absent from the old file come back as defaults, not as nonsense.
        #expect(settings.preserveAspectRatio)
        #expect(settings.pressure == .linear)
    }
}

/// Just the digitizer collection of the T501 descriptor.
private let penDescriptor: [UInt8] = [
    0x05, 0x0D, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x05, 0x09, 0x20, 0xA1, 0x00,
    0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
    0x75, 0x01, 0x95, 0x05, 0x81, 0x01, 0x09, 0x32, 0x75, 0x01, 0x95, 0x01,
    0x81, 0x02, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x75, 0x10, 0x95, 0x01,
    0x55, 0x0D, 0x65, 0x13, 0x35, 0x00, 0x46, 0x40, 0x1F, 0x26, 0x00, 0x10, 0x81, 0x02,
    0x09, 0x31, 0x46, 0xDC, 0x14, 0x26, 0x00, 0x10, 0x81, 0x02,
    0x05, 0x0D, 0x09, 0x30, 0x26, 0xFF, 0x07, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
    0xC0, 0xC0,
]
