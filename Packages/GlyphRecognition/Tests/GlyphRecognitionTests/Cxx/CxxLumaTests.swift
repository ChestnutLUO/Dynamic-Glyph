import CoreGraphics
import Foundation
import Testing
@testable import GlyphRecognition
import GlyphRecognitionImages
import GlyphCoreCxx

/// The image fixtures the C++ luma and panel functions are held to, folder by
/// folder, with the decodes the Swift oracle runs on.
enum LumaPanelFixtures {
    static let folders = ["Frames", "Recording", "Phases", "Covered", "Banner", "WindowEdge", "AssistiveTouch",
                          "OneGlyph", "Results", "Gear", "PortalLevel", "Commands", "EdgeTab"]

    struct Fixture {
        let folder: String
        let name: String
        let image: CGImage
    }

    static func fixtures(in folder: String) throws -> [Fixture] {
        let directory = try ReferenceData.fixturesDirectory.appendingPathComponent(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { ["png", "jpg"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        return try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let image = try #require(ImageDecoder.cgImage(from: data), "\(folder)/\(name) does not decode")
            return Fixture(folder: folder, name: name, image: image)
        }
    }

    static func all() throws -> [Fixture] {
        try folders.flatMap { try fixtures(in: $0) }
    }

    /// Packed 32-bit BGRA, as a capture delivers it, with `padding` spare
    /// bytes at the end of every row.
    static func bgra(_ image: CGImage, padding: Int) throws -> (bytes: [UInt8], bytesPerRow: Int) {
        let width = image.width, height = image.height, bytesPerRow = width * 4 + padding
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, bytesPerRow)
    }

    static func withGray<R>(_ image: LuminanceImage, _ body: (gc_gray_image) throws -> R) throws -> R {
        try image.pixels.withUnsafeBufferPointer { pixels in
            try body(gc_gray_image(data: pixels.baseAddress, width: Int32(image.width), height: Int32(image.height),
                                   bytesPerRow: Int32(image.width)))
        }
    }

    static func withColor<R>(_ image: ColorImage, _ body: (gc_color_image) throws -> R) throws -> R {
        try image.pixels.withUnsafeBufferPointer { pixels in
            try body(gc_color_image(data: pixels.baseAddress, width: Int32(image.width), height: Int32(image.height),
                                    bytesPerRow: Int32(image.width * 3), bytesPerPixel: 3, redOffset: 0,
                                    greenOffset: 1, blueOffset: 2))
        }
    }

    static func cells(_ reading: gc_gate_reading) -> [UInt8] {
        var reading = reading
        return withUnsafeBytes(of: &reading.cells) { Array($0) }
    }

    static func expectEqual(_ gate: gc_gate_reading, _ oracle: LumaGateReading, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(gate.darkFraction == oracle.darkFraction, "\(label): dark", sourceLocation: sourceLocation)
        #expect(gate.brightFraction == oracle.brightFraction, "\(label): bright", sourceLocation: sourceLocation)
        #expect(gate.isCandidate == oracle.isCandidate, "\(label): candidate", sourceLocation: sourceLocation)
        #expect(cells(gate) == oracle.cells, "\(label): cells", sourceLocation: sourceLocation)
    }
}

@Suite("C++ luma: conversions and the gate")
struct CxxLumaTests {
    @Test("The gate on every fixture's Core Graphics grey equals LumaGate, at steps 1, 3 and 4")
    func gateOnFixtures() throws {
        let fixtures = try LumaPanelFixtures.all()
        #expect(fixtures.count >= 60, "fixtures went missing: \(fixtures.count)")
        for fixture in fixtures {
            let luma = try ImageDecoder.decode(fixture.image)
            for step in [1, 3, 4] {
                let oracle = try #require(LumaGate(step: step).read(luma))
                var reading = gc_gate_reading()
                let found = try LumaPanelFixtures.withGray(luma) { gc_gate_read($0, Int32(step), &reading) }
                #expect(found, "\(fixture.folder)/\(fixture.name) step \(step)")
                LumaPanelFixtures.expectEqual(reading, oracle, "\(fixture.folder)/\(fixture.name) step \(step)")
            }
        }
    }

    @Test("The gate straight from BGRA equals LumaGate.read(bgra:) on every fixture, with padded rows")
    func gateFromBGRA() throws {
        for fixture in try LumaPanelFixtures.all() {
            let (bytes, bytesPerRow) = try LumaPanelFixtures.bgra(fixture.image, padding: 12)
            let width = fixture.image.width, height = fixture.image.height
            let oracle = try bytes.withUnsafeBytes { buffer in
                try #require(LumaGate().read(bgra: buffer.baseAddress!, width: width, height: height,
                                             bytesPerRow: bytesPerRow))
            }
            var reading = gc_gate_reading()
            let found = bytes.withUnsafeBufferPointer { buffer in
                gc_gate_read_bgra(gc_color_image(data: buffer.baseAddress, width: Int32(width), height: Int32(height),
                                                 bytesPerRow: Int32(bytesPerRow), bytesPerPixel: 4, redOffset: 2,
                                                 greenOffset: 1, blueOffset: 0), 4, &reading)
            }
            #expect(found, "\(fixture.folder)/\(fixture.name)")
            LumaPanelFixtures.expectEqual(reading, oracle, "\(fixture.folder)/\(fixture.name) from BGRA")
        }
    }

    @Test("A padded Y plane packs byte for byte, and video range through LumaGate's table")
    func lumaFromPlane() throws {
        let width = 37, height = 11, bytesPerRow = 64
        var plane = [UInt8](repeating: 0xEE, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width { plane[y * bytesPerRow + x] = UInt8((x * 7 + y * 23) & 0xFF) }
        }
        var full = [UInt8](repeating: 0, count: width * height)
        var video = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeBufferPointer { source in
            gc_luma_from_plane(source.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), false, &full)
            gc_luma_from_plane(source.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), true, &video)
        }
        let table = LumaGate.videoRangeTable
        for y in 0..<height {
            for x in 0..<width {
                let source = plane[y * bytesPerRow + x]
                #expect(full[y * width + x] == source, "full range at \(x),\(y)")
                #expect(video[y * width + x] == table[Int(source)], "video range at \(x),\(y)")
            }
        }
        // Every byte of the table, not just the ones the pattern reaches.
        let ramp = (0..<256).map { UInt8($0) }
        var stretched = [UInt8](repeating: 0, count: 256)
        ramp.withUnsafeBufferPointer { gc_luma_from_plane($0.baseAddress, 256, 1, 256, true, &stretched) }
        #expect(stretched == table)
        #expect(stretched[0] == 0 && stretched[16] == 0 && stretched[235] == 255 && stretched[255] == 255)
    }

    @Test("Luma from padded BGRA uses LumaGate.read(bgra:)'s fixed-point weights")
    func lumaFromBGRA() throws {
        let width = 29, height = 7, bytesPerRow = width * 4 + 20
        var bgra = [UInt8](repeating: 0xAB, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let base = y * bytesPerRow + x * 4
                bgra[base] = UInt8((x * 31 + y) & 0xFF)
                bgra[base + 1] = UInt8((x * 3 + y * 50) & 0xFF)
                bgra[base + 2] = UInt8((255 - x * 8 + y * 2) & 0xFF)
                bgra[base + 3] = 255
            }
        }
        var luma = [UInt8](repeating: 0, count: width * height)
        bgra.withUnsafeBufferPointer {
            gc_luma_from_bgra($0.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), &luma)
        }
        for y in 0..<height {
            for x in 0..<width {
                let base = y * bytesPerRow + x * 4
                let expected = UInt8(truncatingIfNeeded:
                    (29 * Int(bgra[base]) + 150 * Int(bgra[base + 1]) + 77 * Int(bgra[base + 2])) >> 8)
                #expect(luma[y * width + x] == expected, "at \(x),\(y)")
            }
        }
    }

    @Test("NV12 to RGB: grey stays grey, red comes back red, and only the asked rows are written")
    func rgbFromNV12() throws {
        let width = 8, frameHeight = 6, yBytesPerRow = 16, cbcrBytesPerRow = 16
        func convert(y: UInt8, cb: UInt8, cr: UInt8, videoRange: Bool, rowTop: Int = 0,
                     rowCount: Int = 6) -> [UInt8] {
            let yPlane = [UInt8](repeating: y, count: yBytesPerRow * frameHeight)
            var chroma = [UInt8](repeating: 0, count: cbcrBytesPerRow * (frameHeight / 2))
            for row in 0..<(frameHeight / 2) {
                for column in 0..<(width / 2) {
                    chroma[row * cbcrBytesPerRow + column * 2] = cb
                    chroma[row * cbcrBytesPerRow + column * 2 + 1] = cr
                }
            }
            var out = [UInt8](repeating: 0x77, count: width * rowCount * 3)
            yPlane.withUnsafeBufferPointer { luma in
                chroma.withUnsafeBufferPointer { cbcr in
                    gc_rgb_from_nv12(luma.baseAddress, Int32(yBytesPerRow), cbcr.baseAddress, Int32(cbcrBytesPerRow),
                                     Int32(width), Int32(frameHeight), Int32(rowTop), Int32(rowCount), videoRange,
                                     &out)
                }
            }
            return out
        }
        func within(_ rgb: [UInt8], _ expected: (Int, Int, Int), _ tolerance: Int, _ label: String) {
            for pixel in 0..<(rgb.count / 3) {
                let r = Int(rgb[pixel * 3]), g = Int(rgb[pixel * 3 + 1]), b = Int(rgb[pixel * 3 + 2])
                #expect(abs(r - expected.0) <= tolerance && abs(g - expected.1) <= tolerance
                        && abs(b - expected.2) <= tolerance, "\(label) pixel \(pixel): \(r) \(g) \(b)")
            }
        }
        // Full-range grey: luma passes straight through.
        within(convert(y: 128, cb: 128, cr: 128, videoRange: false), (128, 128, 128), 0, "full grey")
        // Video-range grey: 128 stretches to ((128 - 16) * 255 + 109) / 219 = 130.
        within(convert(y: 128, cb: 128, cr: 128, videoRange: true), (130, 130, 130), 1, "video grey")
        within(convert(y: 16, cb: 128, cr: 128, videoRange: true), (0, 0, 0), 0, "video black")
        within(convert(y: 235, cb: 128, cr: 128, videoRange: true), (255, 255, 255), 0, "video white")
        // BT.709 red (255, 0, 0): Y 54, Cb 99, Cr 255 in full range; Y 63, Cb 102, Cr 240 in video range.
        within(convert(y: 54, cb: 99, cr: 255, videoRange: false), (255, 0, 0), 3, "full red")
        within(convert(y: 63, cb: 102, cr: 240, videoRange: true), (255, 0, 0), 3, "video red")
        // BT.709 green (0, 255, 0): Y 182, Cb 30, Cr 12 full range.
        within(convert(y: 182, cb: 30, cr: 12, videoRange: false), (0, 255, 0), 3, "full green")
        // BT.709 blue (0, 0, 255): Y 18, Cb 255, Cr 116 full range.
        within(convert(y: 18, cb: 255, cr: 116, videoRange: false), (0, 0, 255), 3, "full blue")
        // Two rows asked for: both converted, nothing past the buffer's rows.
        let rows = convert(y: 200, cb: 128, cr: 128, videoRange: false, rowTop: 2, rowCount: 2)
        #expect(rows.count == width * 2 * 3)
        within(rows, (200, 200, 200), 0, "rows 2-3")
        // Rows outside the frame come back black, not stale bytes.
        let outside = convert(y: 200, cb: 128, cr: 128, videoRange: false, rowTop: 5, rowCount: 2)
        within(Array(outside[0..<(width * 3)]), (200, 200, 200), 0, "row 5")
        within(Array(outside[(width * 3)...]), (0, 0, 0), 0, "row 6, past the frame")
    }

    @Test("Empty and degenerate images read as nothing")
    func degenerate() throws {
        var reading = gc_gate_reading()
        #expect(!gc_gate_read(gc_gray_image(data: nil, width: 0, height: 0, bytesPerRow: 0), 4, &reading))
        #expect(!gc_gate_read_bgra(gc_color_image(data: nil, width: 0, height: 0, bytesPerRow: 0, bytesPerPixel: 4,
                                                  redOffset: 2, greenOffset: 1, blueOffset: 0), 4, &reading))
        let pixel: [UInt8] = [10, 20, 30, 255]
        pixel.withUnsafeBufferPointer { buffer in
            #expect(!gc_gate_read(gc_gray_image(data: buffer.baseAddress, width: 0, height: 1, bytesPerRow: 4), 4,
                                  &reading))
            #expect(!gc_gate_read(gc_gray_image(data: buffer.baseAddress, width: 4, height: 1, bytesPerRow: 2), 4,
                                  &reading))
            // A single pixel is a frame: the gate reads it even at a huge step.
            #expect(gc_gate_read(gc_gray_image(data: buffer.baseAddress, width: 1, height: 1, bytesPerRow: 1), 1000,
                                 &reading))
            #expect(gc_gate_read(gc_gray_image(data: buffer.baseAddress, width: 1, height: 1, bytesPerRow: 1), 0,
                                 &reading))
        }
        let oracle = try #require(LumaGate(step: 0).read(LuminanceImage(width: 1, height: 1, pixels: [10])))
        LumaPanelFixtures.expectEqual(reading, oracle, "one pixel")
        var out = [UInt8](repeating: 1, count: 4)
        gc_luma_from_plane(nil, 2, 2, 2, false, &out)
        gc_luma_from_bgra(nil, 1, 1, 4, &out)
        gc_rgb_from_nv12(nil, 2, nil, 2, 2, 2, 0, 1, false, &out)
        #expect(out == [1, 1, 1, 1])
    }

    @Test("Report: Core Graphics grey against the C++ luma from the same pixels as BGRA")
    func greyDifferenceReport() throws {
        for folder in LumaPanelFixtures.folders {
            var total = 0, worst = 0, pixels = 0
            let fixtures = try LumaPanelFixtures.fixtures(in: folder)
            for fixture in fixtures {
                let grey = try ImageDecoder.decode(fixture.image)
                let (bytes, bytesPerRow) = try LumaPanelFixtures.bgra(fixture.image, padding: 0)
                var luma = [UInt8](repeating: 0, count: grey.width * grey.height)
                bytes.withUnsafeBufferPointer {
                    gc_luma_from_bgra($0.baseAddress, Int32(grey.width), Int32(grey.height), Int32(bytesPerRow), &luma)
                }
                for index in luma.indices {
                    let difference = abs(Int(luma[index]) - Int(grey.pixels[index]))
                    total += difference
                    worst = max(worst, difference)
                }
                pixels += luma.count
            }
            let mean = pixels > 0 ? Double(total) / Double(pixels) : 0
            print(String(format: "grey-diff %@: %d images, mean %.3f, max %d", folder, fixtures.count, mean, worst))
        }
    }
}
