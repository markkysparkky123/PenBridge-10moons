import CoreGraphics
import Foundation
import Testing
@testable import TabletCore

/// A stand-in for the T501's declared geometry, so the mapping tests do not depend
/// on re-parsing a descriptor.
private func makeLayout() -> PenReportLayout {
    let descriptor: [UInt8] = [
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
    return PenReportLayout(fields: HIDReportDescriptor.parse(descriptor))!
}

private let fullHD = CGRect(x: 0, y: 0, width: 1920, height: 1080)

@Suite("Area mapping")
struct AreaMapperTests {

    @Test("Full area maps corner to corner")
    func corners() {
        let layout = makeLayout()
        let mapper = AreaMapper(screen: fullHD)

        let topLeft = mapper.map(x: 0, y: 0, layout: layout)
        #expect(topLeft.x == 0)
        #expect(topLeft.y == 0)

        let bottomRight = mapper.map(x: 4096, y: 4096, layout: layout)
        #expect(bottomRight.x == 1920)
        #expect(bottomRight.y == 1080)

        let centre = mapper.map(x: 2048, y: 2048, layout: layout)
        #expect(abs(centre.x - 960) < 0.001)
        #expect(abs(centre.y - 540) < 0.001)
    }

    @Test("Preserving proportions trims the tablet's taller axis")
    func proportional() {
        let layout = makeLayout()
        let area = AreaMapper.proportionalArea(layout: layout, screen: fullHD)

        // Tablet is 203.2 x 135.6 mm (1.498:1); the screen is 1.778:1. The tablet is
        // relatively taller, so its height is the axis that gets trimmed.
        #expect(area.width == 1.0)
        #expect(area.height < 1.0)

        let expected = (203.2 / 135.636) / (1920.0 / 1080.0)
        #expect(abs(area.height - expected) < 0.001)
        // The trimmed band stays centred.
        #expect(abs(area.minY - (1 - area.height) / 2) < 0.0001)
    }

    @Test("A circle stays a circle when proportions are preserved")
    func circleIsNotAnEllipse() {
        let layout = makeLayout()
        let mapper = AreaMapper.proportional(layout: layout, screen: fullHD)

        // Step the same physical distance along each axis and compare what it covers
        // on screen. mm per logical unit differs per axis, so use the physical extents.
        let widthMM = layout.widthMM!
        let heightMM = layout.heightMM!
        let unitsPerMMX = 4096.0 / widthMM
        let unitsPerMMY = 4096.0 / heightMM

        let origin = mapper.map(x: 2048, y: 2048, layout: layout)
        let movedX = mapper.map(x: 2048 + Int(10 * unitsPerMMX), y: 2048, layout: layout)
        let movedY = mapper.map(x: 2048, y: 2048 + Int(10 * unitsPerMMY), layout: layout)

        let dx = movedX.x - origin.x
        let dy = movedY.y - origin.y
        // 10 mm of pen travel should cover the same number of pixels on both axes.
        #expect(abs(dx - dy) < 1.0)
    }

    @Test("Rotation remaps the axes")
    func rotation() {
        let layout = makeLayout()

        let upsideDown = AreaMapper(rotation: .oneEighty, screen: fullHD)
        let point = upsideDown.map(x: 0, y: 0, layout: layout)
        #expect(point.x == 1920)
        #expect(point.y == 1080)

        let quarter = AreaMapper(rotation: .ninety, screen: fullHD)
        // 90 degrees sends the tablet's top-left to the screen's bottom-left.
        let rotated = quarter.map(x: 0, y: 0, layout: layout)
        #expect(rotated.x == 1920)
        #expect(rotated.y == 0)
    }

    @Test("Coordinates outside the configured area are clamped to the screen")
    func clamping() {
        let layout = makeLayout()
        let mapper = AreaMapper(
            area: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), screen: fullHD
        )
        let outside = mapper.map(x: 0, y: 0, layout: layout)
        #expect(outside.x == 0)
        #expect(outside.y == 0)

        let inside = mapper.map(x: 2048, y: 2048, layout: layout)
        #expect(abs(inside.x - 960) < 0.001)
    }

    @Test("Proportions are preserved inside a chosen area, not instead of it")
    func proportionalWithinChosenArea() {
        let layout = makeLayout()
        // The lower half of the tablet, as someone might pick to keep the pen near
        // their hand.
        let chosen = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let trimmed = AreaMapper.proportionalArea(layout: layout, screen: fullHD, within: chosen)

        // The result stays inside what was chosen.
        #expect(trimmed.minX >= chosen.minX - 0.0001)
        #expect(trimmed.maxX <= chosen.maxX + 0.0001)
        #expect(trimmed.minY >= chosen.minY - 0.0001)
        #expect(trimmed.maxY <= chosen.maxY + 0.0001)

        // 203.2 x 67.8 mm is wider than 16:9, so width is the axis trimmed here —
        // the opposite of what happens with the full tablet.
        #expect(trimmed.height == chosen.height)
        #expect(trimmed.width < chosen.width)

        // And it is centred within the chosen area.
        #expect(abs(trimmed.midX - chosen.midX) < 0.0001)
        #expect(abs(trimmed.midY - chosen.midY) < 0.0001)
    }

    @Test("A chosen area still fills the screen edge to edge")
    func chosenAreaReachesEdges() {
        let layout = makeLayout()
        let chosen = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let mapper = AreaMapper(area: chosen, screen: fullHD)

        // The corners of the chosen area are the corners of the screen.
        let topLeft = mapper.map(
            x: Int(chosen.minX * 4096), y: Int(chosen.minY * 4096), layout: layout
        )
        #expect(abs(topLeft.x) < 1)
        #expect(abs(topLeft.y) < 1)

        let bottomRight = mapper.map(
            x: Int(chosen.maxX * 4096), y: Int(chosen.maxY * 4096), layout: layout
        )
        #expect(abs(bottomRight.x - 1920) < 1)
        #expect(abs(bottomRight.y - 1080) < 1)
    }

    @Test("Trimming the full tablet is unchanged by the new parameter")
    func defaultUnchanged() {
        let layout = makeLayout()
        let explicit = AreaMapper.proportionalArea(
            layout: layout, screen: fullHD, within: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let implicit = AreaMapper.proportionalArea(layout: layout, screen: fullHD)
        #expect(explicit == implicit)
    }

    @Test("An area already matching the screen's shape is left untouched")
    func alreadyProportional() {
        let layout = makeLayout()
        let heightMM = layout.heightMM!
        let widthMM = layout.widthMM!

        // Full tablet width, and exactly the height that matches 16:9, starting below
        // the soft-key strip along the top edge.
        let topStrip = 0.059
        let neededHeightMM = widthMM / (1920.0 / 1080.0)
        let chosen = CGRect(
            x: 0, y: topStrip, width: 1, height: neededHeightMM / heightMM
        )

        let trimmed = AreaMapper.proportionalArea(layout: layout, screen: fullHD, within: chosen)

        // Nothing is trimmed: the pen reaches the screen edge exactly at the edge of
        // the chosen area, with no dead band.
        #expect(abs(trimmed.width - chosen.width) < 0.0005)
        #expect(abs(trimmed.height - chosen.height) < 0.0005)
        #expect(abs(trimmed.minY - chosen.minY) < 0.0005)

        // And it stays on the tablet.
        #expect(chosen.maxY <= 1.0)
    }

    @Test("A sub-area covers the whole screen")
    func subArea() {
        let layout = makeLayout()
        let mapper = AreaMapper(
            area: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), screen: fullHD
        )
        let topLeft = mapper.map(x: 1024, y: 1024, layout: layout)
        #expect(abs(topLeft.x) < 0.001)
        #expect(abs(topLeft.y) < 0.001)

        let bottomRight = mapper.map(x: 3072, y: 3072, layout: layout)
        #expect(abs(bottomRight.x - 1920) < 0.001)
        #expect(abs(bottomRight.y - 1080) < 0.001)
    }
}

@Suite("Pressure curve")
struct PressureCurveTests {

    @Test("The default curve is a straight line")
    func linear() {
        let curve = PressureCurve.linear
        #expect(abs(curve.apply(0.0) - 0.0) < 0.001)
        #expect(abs(curve.apply(0.25) - 0.25) < 0.002)
        #expect(abs(curve.apply(0.5) - 0.5) < 0.002)
        #expect(abs(curve.apply(1.0) - 1.0) < 0.001)
    }

    @Test("Raw device values are normalized against the declared range")
    func rawValues() {
        let curve = PressureCurve.linear
        #expect(abs(curve.apply(0, range: 0...2047) - 0.0) < 0.001)
        #expect(abs(curve.apply(2047, range: 0...2047) - 1.0) < 0.001)
        #expect(abs(curve.apply(1023, range: 0...2047) - 0.5) < 0.002)
    }

    @Test("Thresholds cut off both ends of the usable range")
    func thresholds() {
        let curve = PressureCurve(lowerThreshold: 0.1, upperThreshold: 0.8)
        #expect(curve.apply(0.05) == 0)
        #expect(curve.apply(0.1) == 0)
        #expect(curve.apply(0.9) == 1)
        // Halfway through the usable 0.1…0.8 band.
        #expect(abs(curve.apply(0.45) - 0.5) < 0.005)
    }

    @Test("Soft reaches high pressure sooner than firm")
    func feel() {
        let soft = PressureCurve.soft.apply(0.5)
        let linear = PressureCurve.linear.apply(0.5)
        let firm = PressureCurve.firm.apply(0.5)
        #expect(soft > linear)
        #expect(firm < linear)
    }

    @Test("Output never leaves 0…1 even for out-of-range input")
    func bounded() {
        for curve in [PressureCurve.linear, .soft, .firm] {
            for input in [-1.0, -0.001, 0.0, 0.5, 1.0, 1.001, 5.0] {
                let output = curve.apply(input)
                #expect(output >= 0 && output <= 1)
            }
        }
    }

    @Test("Settings survive a round trip through JSON")
    func codable() throws {
        var settings = Settings()
        settings.rotation = .ninety
        settings.pressure = .firm
        settings.area = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored == settings)
    }
}
