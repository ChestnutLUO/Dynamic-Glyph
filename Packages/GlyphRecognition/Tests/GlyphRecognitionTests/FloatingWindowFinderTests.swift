import CoreGraphics
import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// The app's own Picture in Picture window found in a top band, as the
/// `headerWindowMask` cut looks for it. The window is drawn by the app's own
/// renderer at the size it shows on a phone, over a synthetic game screen:
/// the scene makes no claim about any recording, only about the window's
/// shape.
@Suite("Floating window finder")
struct FloatingWindowFinderTests {
    /// A 602-wide capture of a 1310-tall frame, as the replay decodes the
    /// measured recordings; the band reaches `GameUILayout.topBandBottom`.
    static let width = 602
    static let frameHeight = 1310
    static let bandRows = 323
    /// Where the window stood over the header in the measured 602-wide
    /// recordings: 0.94 of the width, aspect 10, 15 of the header's rows
    /// left above it.
    static let headerWindow = CGRect(x: 17, y: 93, width: 566, height: 57)

    /// The band: a dark, noisy game screen with header text in its rows,
    /// and the app's window at `window` showing the setup demo `elapsed`
    /// seconds in, unless nil. `extra` draws more of the game on top.
    static func band(window: CGRect? = headerWindow, elapsed: Double = 3.5,
                     extra: (CGContext) -> Void = { _ in }) throws -> FrameTopBand {
        let width = Self.width, rows = Self.bandRows
        var rgba = [UInt8](repeating: 255, count: width * rows * 4)
        for y in 0..<rows {
            for x in 0..<width {
                let header = (78..<136).contains(y) && (x / 6) % 4 == 0 && (y / 5) % 3 != 2
                let value = header ? 210 : UInt8(18 + (x * 13 + y * 7) % 31)
                let offset = (y * width + x) * 4
                rgba[offset] = value; rgba[offset + 1] = value &+ 4; rgba[offset + 2] = value &+ 10
            }
        }
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: rows,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .high
            // Bitmap rows run top down; the context's y runs bottom up.
            context.translateBy(x: 0, y: CGFloat(rows))
            context.scaleBy(x: 1, y: -1)
            extra(context)
            if let window {
                let demo = SetupDemo(table: nil)
                let picture = try #require(GlyphDisplayRenderer(table: demo.table).image(
                    demo.snapshot(at: elapsed, uptime: 100), canvas: .standard, atUptime: 100,
                    windowWidth: Double(window.width) / 2))
                context.saveGState()
                context.translateBy(x: 0, y: window.maxY + window.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(picture, in: window)
                context.restoreGState()
            }
            context.flush()
        }
        var rgb = [UInt8](repeating: 0, count: width * rows * 3)
        for index in 0..<(width * rows) {
            rgb[index * 3] = rgba[index * 4]; rgb[index * 3 + 1] = rgba[index * 4 + 1]
            rgb[index * 3 + 2] = rgba[index * 4 + 2]
        }
        return FrameTopBand(image: try ColorImage(width: width, height: rows, pixels: rgb),
                            frameHeight: Self.frameHeight)
    }

    static func expectNear(_ found: FloatingWindowFinder.Window?, _ drawn: CGRect,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = FloatingWindowFinder.Window(left: Int(drawn.minX), top: Int(drawn.minY),
                                                   right: Int(drawn.maxX), bottom: Int(drawn.maxY))
        guard let found else {
            Issue.record("No window found at \(drawn)", sourceLocation: sourceLocation)
            return
        }
        #expect(found.shift(from: expected) <= 2, "found \(found), drawn \(expected)", sourceLocation: sourceLocation)
    }

    @Test("The window over the header is found where it was drawn, whatever it shows")
    func coveredHeader() throws {
        // The setup demo's loop: waiting, presenting, input and the result,
        // each in its own status colour.
        var found: [FloatingWindowFinder.Window] = []
        for elapsed in [0.5, 3.5, 7.5, 10.5, 11.5] {
            let window = FloatingWindowFinder.find(in: try Self.band(elapsed: elapsed))
            Self.expectNear(window, Self.headerWindow)
            if let window { found.append(window) }
        }
        let first = try #require(found.first)
        #expect(found.allSatisfy { $0.shift(from: first) <= 2 }, "Content changes do not move it: \(found)")
    }

    @Test("A screen without the window has none")
    func uncovered() throws {
        #expect(FloatingWindowFinder.find(in: try Self.band(window: nil)) == nil)
    }

    @Test("A window moved below the header is found there; one cut by the band's edge is not found")
    func movedAndPartly() throws {
        let below = CGRect(x: 17, y: 180, width: 566, height: 57)
        Self.expectNear(FloatingWindowFinder.find(in: try Self.band(window: below)), below)
        let narrower = CGRect(x: 100, y: 60, width: 400, height: 40)
        Self.expectNear(FloatingWindowFinder.find(in: try Self.band(window: narrower)), narrower)
        let cut = CGRect(x: 17, y: 290, width: 566, height: 57)
        #expect(FloatingWindowFinder.find(in: try Self.band(window: cut)) == nil,
                "Its lower ring is outside the band")
        let atTop = CGRect(x: 17, y: 0, width: 566, height: 57)
        #expect(FloatingWindowFinder.find(in: try Self.band(window: atTop)) == nil,
                "A ring on the band's first rows may be cut off")
        let offSide = CGRect(x: -20, y: 93, width: 566, height: 57)
        #expect(FloatingWindowFinder.find(in: try Self.band(window: offSide)) == nil, "A side off the screen")
    }

    @Test("Game boxes, bars and panels that look alike are not the window")
    func lookAlikes() throws {
        func box(_ rect: CGRect, line: CGFloat, colour: CGColor, fill: CGColor?) -> (CGContext) -> Void {
            { context in
                if let fill { context.setFillColor(fill); context.fill(rect) }
                context.setStrokeColor(colour)
                context.setLineWidth(line)
                context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
            }
        }
        let teal = CGColor(red: 0.45, green: 0.85, blue: 0.95, alpha: 1)
        let dark = CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        let wide = CGRect(x: 17, y: 93, width: 566, height: 57)
        // A game box of a thin line, as the store and status boxes are.
        #expect(FloatingWindowFinder.find(in: try Self.band(window: nil,
                                                            extra: box(wide, line: 1, colour: teal, fill: dark))) == nil)
        // A solid bar of the ring's colour: no dark interior.
        #expect(FloatingWindowFinder.find(in: try Self.band(window: nil,
                                                            extra: box(wide, line: 4, colour: teal, fill: teal))) == nil)
        // A frame as wide as the screen leaves no margin.
        let full = CGRect(x: 0, y: 93, width: 602, height: 57)
        #expect(FloatingWindowFinder.find(in: try Self.band(window: nil,
                                                            extra: box(full, line: 4, colour: teal, fill: dark))) == nil)
        // A ring box far wider than tall is a bar, not the window.
        let flat = CGRect(x: 17, y: 93, width: 566, height: 30)
        #expect(FloatingWindowFinder.find(in: try Self.band(window: nil,
                                                            extra: box(flat, line: 2, colour: teal, fill: dark))) == nil)
    }

    @Test("Bands too small or pixels missing find nothing")
    func malformed() {
        #expect(FloatingWindowFinder.find(rgb: [], width: 0, rows: 0, frameHeight: 0) == nil)
        #expect(FloatingWindowFinder.find(rgb: [UInt8](repeating: 0, count: 30), width: 10, rows: 2,
                                          frameHeight: 2) == nil, "Fewer pixels than the rows hold")
    }

    @Test("Shift is the largest edge distance; union holds both rectangles")
    func geometry() {
        let a = FloatingWindowFinder.Window(left: 10, top: 20, right: 300, bottom: 50)
        let b = FloatingWindowFinder.Window(left: 12, top: 19, right: 297, bottom: 50)
        #expect(a.shift(from: b) == 3 && b.shift(from: a) == 3)
        #expect(a.union(b) == FloatingWindowFinder.Window(left: 10, top: 19, right: 300, bottom: 50))
    }
}
