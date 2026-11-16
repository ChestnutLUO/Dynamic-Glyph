import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// The still grid shared by the header still skip and the panel settle cuts:
/// its cell rule, its comparison, and the same grid from packed RGB and from
/// the capture's planes in place.
@Suite("Still signature grid")
struct StillSignatureTests {
    /// Grey `value(x, y)` as packed RGB, `width` by `height`.
    private static func rgb(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let grey = value(x, y)
                for channel in 0..<3 { pixels[(y * width + x) * 3 + channel] = grey }
            }
        }
        return pixels
    }

    @Test("Cells have edges at index x size / count, at least one pixel, and truncated means")
    func cellRule() throws {
        // At 320 wide and 40 columns each cell holds eight columns of grey
        // x / 8 * 2 and one more, whose truncated mean is the lower one.
        let width = 320, height = 30
        let pixels = Self.rgb(width: width, height: height) { x, _ in UInt8(x / 8 * 2 + x % 2) }
        let grid = try #require(StillSignature(rgb: pixels, width: width, rows: 10..<30, frameWidth: width,
                                               frameHeight: 100, columns: 40, gridRows: 5))
        #expect(grid.cells.count == 200 && grid.columns == 40 && grid.rows == 5)
        #expect(grid.cells[0] == 0 && grid.cells[1] == 2 && grid.cells[39] == 78 && grid.cells[4 * 40 + 39] == 78)
        let tiny = try #require(StillSignature(rgb: Self.rgb(width: 3, height: 2) { _, _ in 9 }, width: 3, rows: 0..<2,
                                               frameWidth: 3, frameHeight: 2, columns: 8, gridRows: 4))
        #expect(tiny.cells.allSatisfy { $0 == 9 }, "Finer than the pixels: every cell still holds one")
        #expect(StillSignature(rgb: pixels, width: width, rows: 0..<31, frameWidth: width, frameHeight: 100,
                               columns: 40, gridRows: 5) == nil, "Rows beyond the pixels build nothing")
        #expect(StillSignature(rgb: pixels, width: width, rows: 4..<4, frameWidth: width, frameHeight: 100,
                               columns: 40, gridRows: 5) == nil)
        #expect(StillSignature(rgb: pixels, width: width, rows: 0..<4, frameWidth: width, frameHeight: 100,
                               columns: 0, gridRows: 5) == nil)
    }

    @Test("Only the same grid over frames of the same size compares; the mean difference is in grey levels")
    func comparison() throws {
        let width = 64, height = 16
        let base = Self.rgb(width: width, height: height) { x, y in UInt8(40 + (x + y) % 7) }
        let brighter = Self.rgb(width: width, height: height) { x, y in UInt8(43 + (x + y) % 7) }
        func grid(_ pixels: [UInt8], frameHeight: Int = 100, columns: Int = 16) -> StillSignature? {
            StillSignature(rgb: pixels, width: width, rows: 0..<height, frameWidth: width, frameHeight: frameHeight,
                           columns: columns, gridRows: 4)
        }
        let a = try #require(grid(base)), b = try #require(grid(brighter))
        #expect(a.meanDifference(from: a) == 0 && a.isStill(comparedWith: a, tolerance: 0))
        #expect(b.meanDifference(from: a) == 3)
        #expect(b.isStill(comparedWith: a, tolerance: 3) && !b.isStill(comparedWith: a, tolerance: 2.9))
        let otherFrame = try #require(grid(base, frameHeight: 101))
        let otherGrid = try #require(grid(base, columns: 8))
        #expect(otherFrame.meanDifference(from: a) == nil && !otherFrame.isStill(comparedWith: a, tolerance: 255))
        #expect(otherGrid.meanDifference(from: a) == nil)
    }

    @Test("A mask leaves out the cells a rectangle touches, by the grid's own cell edges")
    func maskCells() throws {
        // 64 x 16 pixels under 16 x 4 cells of 4 x 4.
        let mask = try #require(StillCellMask(columns: 16, rows: 4, width: 64, height: 16,
                                              left: 6, top: -3, right: 13, bottom: 5))
        // Columns 6..<13 touch cells 1 to 3; rows up to 5 touch cell rows 0 and 1.
        let excluded = (0..<64).filter { mask.excluded[$0] }
        #expect(excluded == [1, 2, 3, 17, 18, 19])
        #expect(mask.keptCount == 58 && mask.keptShare == 58.0 / 64.0)
        let edge = try #require(StillCellMask(columns: 16, rows: 4, width: 64, height: 16,
                                              left: 4, top: 4, right: 8, bottom: 8))
        #expect((0..<64).filter { edge.excluded[$0] } == [17], "Edges are exclusive on the right and bottom")
        #expect(StillCellMask(columns: 16, rows: 4, width: 64, height: 16, left: 0, top: 16, right: 64,
                              bottom: 30) == nil, "Below the region touches no cell")
        #expect(StillCellMask(columns: 16, rows: 4, width: 64, height: 16, left: 70, top: 0, right: 80,
                              bottom: 16) == nil)
        #expect(StillCellMask(columns: 0, rows: 4, width: 64, height: 16, left: 0, top: 0, right: 8,
                              bottom: 8) == nil)
        let all = try #require(StillCellMask(columns: 16, rows: 4, width: 64, height: 16, left: -1, top: -1,
                                             right: 65, bottom: 17))
        #expect(all.keptCount == 0 && all.keptShare == 0)
    }

    @Test("A masked comparison ignores changes under the mask, sees changes outside it, and needs enough cells")
    func maskedComparison() throws {
        let width = 64, height = 16
        func grid(_ value: @escaping (Int, Int) -> UInt8) throws -> StillSignature {
            try #require(StillSignature(rgb: Self.rgb(width: width, height: height, value), width: width,
                                        rows: 0..<height, frameWidth: width, frameHeight: 100, columns: 16,
                                        gridRows: 4))
        }
        let base = try grid { x, y in UInt8(40 + (x + y) % 7) }
        // The right half changes by 100 levels: the window over it.
        let windowChanged = try grid { x, y in UInt8(40 + (x + y) % 7 + (x >= 32 ? 100 : 0)) }
        // The left half's first column of cells changes too: the header.
        let headerChanged = try grid { x, y in UInt8(40 + (x + y) % 7 + (x >= 32 || x < 4 ? 100 : 0)) }
        let rightHalf = try #require(StillCellMask(columns: 16, rows: 4, width: width, height: height,
                                                   left: 32, top: 0, right: 64, bottom: 16))
        #expect(!windowChanged.isStill(comparedWith: base, tolerance: 1))
        #expect(windowChanged.meanDifference(from: base, excluding: rightHalf) == 0)
        #expect(windowChanged.isStill(comparedWith: base, tolerance: 1, excluding: rightHalf, minimumKeptShare: 0.5))
        #expect(!windowChanged.isStill(comparedWith: base, tolerance: 1, excluding: rightHalf, minimumKeptShare: 0.51),
                "Too few cells left: not still, so the look reads")
        #expect(headerChanged.meanDifference(from: base, excluding: rightHalf) == 12.5)
        #expect(!headerChanged.isStill(comparedWith: base, tolerance: 1, excluding: rightHalf, minimumKeptShare: 0.15))
        let all = try #require(StillCellMask(columns: 16, rows: 4, width: width, height: height, left: 0, top: 0,
                                             right: 64, bottom: 16))
        #expect(windowChanged.meanDifference(from: base, excluding: all) == nil, "No cell kept compares nothing")
        let otherGridMask = try #require(StillCellMask(columns: 8, rows: 4, width: width, height: height,
                                                       left: 32, top: 0, right: 64, bottom: 16))
        #expect(windowChanged.meanDifference(from: base, excluding: otherGridMask) == nil)
        let otherFrame = try #require(StillSignature(rgb: Self.rgb(width: width, height: height) { _, _ in 40 },
                                                     width: width, rows: 0..<height, frameWidth: width,
                                                     frameHeight: 101, columns: 16, gridRows: 4))
        #expect(otherFrame.meanDifference(from: base, excluding: rightHalf) == nil)
    }

    @Test("BGRA planes give the RGB grid; an NV12 grid averages its Y plane in place")
    func planes() throws {
        let width = 40, height = 24, padding = 12
        func colour(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            (UInt8((x * 37 + y * 11) % 256), UInt8((x * 13 + y * 29) % 256), UInt8((x * 7 + y * 53) % 256))
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var bgra = [UInt8](repeating: 0xEE, count: (width * 4 + padding) * height)
        var luma = [UInt8](repeating: 0xEE, count: (width + padding) * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = colour(x, y)
                rgb[(y * width + x) * 3] = r; rgb[(y * width + x) * 3 + 1] = g; rgb[(y * width + x) * 3 + 2] = b
                let offset = y * (width * 4 + padding) + x * 4
                bgra[offset] = b; bgra[offset + 1] = g; bgra[offset + 2] = r; bgra[offset + 3] = 255
                luma[y * (width + padding) + x] = r
            }
        }
        let rows = 6..<20, left = 4, regionWidth = 30
        var crop: [UInt8] = []
        for y in rows { crop += rgb[((y * width + left) * 3)..<((y * width + left + regionWidth) * 3)] }
        let fromRGB = try #require(StillSignature(rgb: crop, width: regionWidth, rows: 0..<rows.count,
                                                  frameWidth: width, frameHeight: height, columns: 10, gridRows: 7))
        let fromBGRA = bgra.withUnsafeBytes { buffer -> StillSignature? in
            guard let base = buffer.baseAddress else { return nil }
            let planes = FramePlanes(format: .bgra, width: width, height: height, base: base,
                                     bytesPerRow: width * 4 + padding)
            return StillSignature(planes: planes, left: left, top: rows.lowerBound, width: regionWidth,
                                  height: rows.count, columns: 10, rows: 7)
        }
        #expect(fromBGRA == fromRGB)
        let fromY = try #require(luma.withUnsafeBytes { buffer -> StillSignature? in
            guard let base = buffer.baseAddress else { return nil }
            let planes = FramePlanes(format: .nv12(videoRange: false), width: width, height: height, base: base,
                                     bytesPerRow: width + padding)
            return StillSignature(planes: planes, left: left, top: rows.lowerBound, width: regionWidth,
                                  height: rows.count, columns: 10, rows: 7)
        })
        // Each cell is 3 x 2 pixels of Y = R: its truncated mean, by hand.
        for row in 0..<7 {
            for column in 0..<10 {
                var sum = 0
                for y in (rows.lowerBound + row * 2)..<(rows.lowerBound + row * 2 + 2) {
                    for x in (left + column * 3)..<(left + column * 3 + 3) { sum += Int(colour(x, y).0) }
                }
                #expect(Int(fromY.cells[row * 10 + column]) == sum / 6)
            }
        }
        let outside = luma.withUnsafeBytes { buffer -> StillSignature? in
            guard let base = buffer.baseAddress else { return nil }
            let planes = FramePlanes(format: .nv12(videoRange: false), width: width, height: height, base: base,
                                     bytesPerRow: width + padding)
            return StillSignature(planes: planes, left: 20, top: 0, width: 21, height: 4, columns: 4, rows: 2)
        }
        #expect(outside == nil, "A rectangle past the frame's edge builds nothing")
    }
}
