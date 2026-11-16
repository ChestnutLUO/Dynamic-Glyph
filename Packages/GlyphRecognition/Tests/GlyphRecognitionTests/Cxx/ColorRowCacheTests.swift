import Foundation
import Testing
import GlyphCoreCxx
@testable import GlyphRecognitionCxx

/// The NV12 colour rows the C++ arm's checks read: the converter against the
/// scalar formula it replaced, and the per-frame cache against a conversion
/// of each check's own rows.
@Suite("C++ engine: NV12 colour rows, converted once per frame")
struct ColorRowCacheTests {
    /// One NV12 frame's planes of random bytes, rows padded as a capture's.
    struct Planes {
        let width: Int, height: Int, yStride: Int, chromaStride: Int
        let luma: [UInt8], chroma: [UInt8]

        init(width: Int, height: Int, seed: UInt64) {
            self.width = width; self.height = height
            yStride = (width + 63) / 64 * 64
            chromaStride = ((width + 1) / 2 * 2 + 63) / 64 * 64
            var generator = SplitMix(state: seed)
            luma = (0..<(yStride * height)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            chroma = (0..<(chromaStride * ((height + 1) / 2))).map { _ in
                UInt8(truncatingIfNeeded: generator.next())
            }
        }

        func convert(_ rows: Range<Int32>, videoRange: Bool, into out: UnsafeMutablePointer<UInt8>) {
            luma.withUnsafeBufferPointer { y in
                chroma.withUnsafeBufferPointer { c in
                    gc_rgb_from_nv12(y.baseAddress, Int32(yStride), c.baseAddress, Int32(chromaStride), Int32(width),
                                     Int32(height), rows.lowerBound, Int32(rows.count), videoRange, out)
                }
            }
        }

        /// The library's conversion of `rows` into a buffer of its own.
        func converted(_ rows: Range<Int32>, videoRange: Bool) -> [UInt8] {
            var out = [UInt8](repeating: 0x5A, count: width * rows.count * 3)
            out.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress { convert(rows, videoRange: videoRange, into: base) }
            }
            return out
        }

        /// The scalar formula `gc_rgb_from_nv12` had before it was
        /// vectorised, written out again: BT.709 in 16.16 fixed point, rows
        /// outside the frame black.
        func reference(_ rows: Range<Int32>, videoRange: Bool) -> [UInt8] {
            let yScale = videoRange ? 76309 : 65536, yOffset = videoRange ? 16 : 0
            let rCr = videoRange ? 117489 : 103206, gCb = videoRange ? 13975 : 12276
            let gCr = videoRange ? 34925 : 30679, bCb = videoRange ? 138438 : 121608
            func clamp(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }
            var out = [UInt8](repeating: 0, count: width * rows.count * 3)
            for (index, row) in rows.enumerated() where row >= 0 && Int(row) < height {
                let y = Int(row)
                for x in 0..<width {
                    let l = (Int(luma[y * yStride + x]) - yOffset) * yScale
                    let pair = y / 2 * chromaStride + x / 2 * 2
                    let cb = Int(chroma[pair]) - 128, cr = Int(chroma[pair + 1]) - 128
                    let pixel = (index * width + x) * 3
                    out[pixel] = clamp((l + rCr * cr + 32768) >> 16)
                    out[pixel + 1] = clamp((l - gCb * cb - gCr * cr + 32768) >> 16)
                    out[pixel + 2] = clamp((l + bCb * cb + 32768) >> 16)
                }
            }
            return out
        }
    }

    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The bands the engine's colour checks read at a frame height.
    static func bands(height: Int) -> (gear: Range<Int32>, portal: Range<Int32>) {
        var gearTop: Int32 = 0, gearBottom: Int32 = 0, portalTop: Int32 = 0, portalBottom: Int32 = 0
        gc_gear_band(Int32(height), &gearTop, &gearBottom)
        gc_portal_band(Int32(height), &portalTop, &portalBottom)
        return (gearTop..<gearBottom, portalTop..<portalBottom)
    }

    @Test("The converter gives the scalar formula's bytes at every width, both ranges, any rows",
          arguments: [(603, 1311), (602, 1310), (1206, 2622), (1, 3), (15, 4), (16, 4), (17, 5), (31, 3), (33, 7)])
    func converterMatchesFormula(_ width: Int, _ height: Int) {
        let planes = Planes(width: width, height: height, seed: UInt64(width * 10_000 + height))
        let (gear, portal) = Self.bands(height: height)
        let h = Int32(height)
        var ranges: [Range<Int32>] = [0..<h, (h - 3)..<(h + 4), -2..<3, 1..<min(h, 4)]
        ranges += [gear, portal]
        if gear.lowerBound + 1 < portal.upperBound { ranges.append((gear.lowerBound + 1)..<portal.upperBound) }
        for videoRange in [false, true] {
            for rows in ranges where !rows.isEmpty {
                let actual = planes.converted(rows, videoRange: videoRange)
                let expected = planes.reference(rows, videoRange: videoRange)
                let differing = zip(actual, expected).filter { $0 != $1 }.count
                #expect(differing == 0, "\(width)x\(height) rows \(rows) video \(videoRange): \(differing) bytes")
            }
        }
    }

    @Test("Every check's rows from the cache equal a conversion of those rows alone, each row converted once",
          arguments: [(603, 1311), (602, 1310), (1206, 2622)])
    func cacheMatchesOwnConversion(_ width: Int, _ height: Int) {
        let (gear, portal) = Self.bands(height: height)
        let window = min(gear.lowerBound, portal.lowerBound)..<max(gear.upperBound, portal.upperBound)
        #expect(gear.overlaps(portal), "the bands overlap, which is what the cache saves")
        var cache = ColorRowCache()
        // Two frames through one cache: nothing of the first may reach the second.
        for (frame, videoRange) in [(0, false), (1, true), (2, false)] {
            let planes = Planes(width: width, height: height, seed: UInt64(frame + 1) * 7919)
            var convertedRows = 0
            let convert: ColorRowCache.Convert = { rows, out in
                convertedRows += rows.count
                planes.convert(rows, videoRange: videoRange, into: out)
            }
            cache.begin(width: Int32(width), window: window)
            let odd = (gear.lowerBound + 1)..<(gear.lowerBound + 8)
            for rows in [portal, gear, odd, portal] {
                let bytes = cache.withRows(rows, width: Int32(width), convert: convert) { pixels in
                    Array(UnsafeBufferPointer(start: pixels, count: width * rows.count * 3))
                }
                #expect(bytes == planes.converted(rows, videoRange: videoRange),
                        "frame \(frame) rows \(rows) at \(width)x\(height)")
            }
            #expect(convertedRows == window.count, "each row once: \(convertedRows) of \(window.count)")
            cache.end()
        }
    }

    @Test("Rows outside the window widen it, and rows asked for after the frame are converted afresh")
    func outsideTheWindow() {
        let planes = Planes(width: 40, height: 30, seed: 5)
        var cache = ColorRowCache()
        var convertedRows = 0
        let convert: ColorRowCache.Convert = { rows, out in
            convertedRows += rows.count
            planes.convert(rows, videoRange: false, into: out)
        }
        func read(_ rows: Range<Int32>) -> [UInt8]? {
            cache.withRows(rows, width: 40, convert: convert) {
                Array(UnsafeBufferPointer(start: $0, count: 40 * rows.count * 3))
            }
        }
        cache.begin(width: 40, window: 10..<20)
        #expect(read(12..<18) == planes.converted(12..<18, videoRange: false))
        #expect(read(5..<25) == planes.converted(5..<25, videoRange: false))
        #expect(cache.window == 5..<25)
        #expect(read(12..<18) == planes.converted(12..<18, videoRange: false))
        #expect(convertedRows == 6 + 20, "the widened window starts empty, then serves what it holds")
        #expect(read(14..<14) == nil)
        cache.end()
        #expect(read(12..<14) == planes.converted(12..<14, videoRange: false))
        #expect(convertedRows == 28)
        // Another width is another frame's layout: nothing is reused.
        let narrow = Planes(width: 20, height: 30, seed: 6)
        let rows = cache.withRows(12..<14, width: 20, convert: { range, out in
            narrow.convert(range, videoRange: true, into: out)
        }) { Array(UnsafeBufferPointer(start: $0, count: 20 * 2 * 3)) }
        #expect(rows == narrow.converted(12..<14, videoRange: true))
    }
}
