import Testing
@testable import GlyphRecognition

struct NameRegionFingerprintTests {
    func image(width: Int, height: Int, pixel: (Int, Int) -> UInt8) throws -> LuminanceImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = pixel(x, y) } }
        return try LuminanceImage(width: width, height: height, pixels: pixels)
    }

    @Test("Two readings of one strip correlate as the same card")
    func identical() throws {
        let image = try image(width: 120, height: 40) { x, y in UInt8((x * 3 + y * 5) % 251) }
        let first = NameRegionFingerprint(image: image)
        let second = NameRegionFingerprint(image: image)
        #expect(first.correlation(with: second) > 0.99)
    }

    @Test("A uniform brightness shift keeps the correlation")
    func brightnessShift() throws {
        let first = try image(width: 120, height: 40) { x, y in UInt8((x * 3 + y * 5) % 251) }
        let second = try image(width: 120, height: 40) { x, y in UInt8(min(255, Int((x * 3 + y * 5) % 251) + 30)) }
        #expect(NameRegionFingerprint(image: first)
            .correlation(with: NameRegionFingerprint(image: second)) > 0.9)
    }

    @Test("A different strip does not read as the same card")
    func different() throws {
        let first = try image(width: 120, height: 40) { x, y in UInt8((x * 3 + y * 5) % 251) }
        let second = try image(width: 120, height: 40) { x, y in UInt8(((x - 60) * 5 + y * 2 + 200) % 251) }
        #expect(NameRegionFingerprint(image: first)
            .correlation(with: NameRegionFingerprint(image: second)) < 0.75)
    }

    @Test("A blank strip correlates with nothing, even itself")
    func blank() throws {
        let blank = try image(width: 120, height: 40) { _, _ in 40 }
        let strip = try image(width: 120, height: 40) { x, y in UInt8((x * 3 + y * 5) % 251) }
        let blankPrint = NameRegionFingerprint(image: blank)
        #expect(blankPrint.correlation(with: blankPrint) == 0)
        #expect(blankPrint.correlation(with: NameRegionFingerprint(image: strip)) == 0)
    }

    @Test("Scroll drift of a few pixels stays above the same-card threshold")
    func drift() throws {
        let width = 120, height = 40
        let still = try image(width: width, height: height) { x, y in UInt8((x * 7 / 3 + y * 11) % 251) }
        // Two pixels of vertical drift, the way the strip sits after a
        // small scroll.
        let moved = try image(width: width, height: height) { x, y in
            UInt8((x * 7 / 3 + max(0, y - 2) * 11) % 251)
        }
        #expect(NameRegionFingerprint(image: still).correlation(with: NameRegionFingerprint(image: moved)) > 0.75)
    }
}
