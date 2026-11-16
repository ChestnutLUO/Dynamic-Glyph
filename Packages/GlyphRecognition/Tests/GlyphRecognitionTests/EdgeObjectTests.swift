import CoreGraphics
import Foundation
import Testing
import GlyphCoreCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// The tucked floating-window tab of the `Fixtures/EdgeTab` crops, drawn over
/// other fixtures where a field report showed it, or mirrored at the left
/// edge.
enum EdgeTab {
    enum Side: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case right, left
        var testDescription: String { rawValue }
    }

    /// The recorded frame: black except the tab.
    static func frame() throws -> ColorImage {
        let url = try ReferenceData.fixturesDirectory.appendingPathComponent("EdgeTab/tab-frame.png")
        let image = try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
        return try ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func image(_ path: String) throws -> CGImage {
        let url = try ReferenceData.fixturesDirectory.appendingPathComponent(path)
        return try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)), "\(path) does not decode")
    }

    /// `image` redrawn as RGB, with the tab's pixels over it when `side` is
    /// set. `image` holds rows `top...` of a frame `frameHeight` tall (the
    /// whole frame by default); the tab is scaled to that frame and moved
    /// `shift` of its height down. Without a side this is the baseline the
    /// tab is compared against, decoded through the same drawing.
    static func draw(_ image: CGImage, side: Side?, frameHeight: Int? = nil, top: Int = 0,
                     shift: Double = 0) throws -> CGImage {
        let width = image.width, height = image.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let side {
            let tab = try frame()
            let frameHeight = Double(frameHeight ?? height)
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
            for y in 0..<height {
                let fraction = Double(y + top) / frameHeight - shift
                guard fraction >= 0 else { continue }
                let sourceY = Int(fraction * Double(tab.height))
                guard sourceY < tab.height else { continue }
                for x in 0..<width {
                    let column = x * tab.width / width
                    let pixel = tab[side == .right ? column : tab.width - 1 - column, sourceY]
                    guard max(pixel.red, pixel.green, pixel.blue) > 0 else { continue }
                    let offset = y * width * 4 + x * 4
                    bytes[offset] = pixel.red
                    bytes[offset + 1] = pixel.green
                    bytes[offset + 2] = pixel.blue
                }
            }
        }
        return try #require(context.makeImage())
    }

    /// Every full frame in the folders the slot strip is checked on.
    static func frames() throws -> [(label: String, image: CGImage)] {
        try CxxSlotStripTests.fixtureFolders.flatMap { folder in
            try CxxSlotStripTests.fixtureImages(in: folder).compactMap { url in
                let image = try image("\(folder)/\(url.lastPathComponent)")
                return image.height > image.width ? ("\(folder)/\(url.lastPathComponent)", image) : nil
            }
        }
    }

    /// The command band crops, each with the frame it was cut from: the
    /// older crops from 1310-row frames, the edge-tab report's crop from 1311.
    static func commandBands() throws -> [(name: String, image: CGImage, frameHeight: Int, top: Int)] {
        try CxxSlotStripTests.fixtureImages(in: "Commands").map { url in
            let image = try image("Commands/\(url.lastPathComponent)")
            let frameHeight = image.width == 603 ? 1311 : 1310
            let top = Int(CommandNoticeDetector.band(width: image.width, height: frameHeight).minY)
            return (url.lastPathComponent, image, frameHeight, top)
        }
    }

    /// A frame's command band, decoded as `CommandNoticeReader` decodes it.
    static func commandBand(of frame: CGImage) throws -> LuminanceImage {
        let rect = CommandNoticeDetector.band(width: frame.width, height: frame.height)
        return try ImageDecoder.decode(try #require(frame.cropping(to: rect)))
    }

    /// A 603 × 172 command band authored by hand: a notice box with a bright
    /// phrase inside, a recorded tab's lower end at either edge, and other
    /// objects that must still keep the box from being read.
    enum NoticeScene: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case box, boxTabRight, boxTabLeft, boxBothTabs, tabOnly, boxLitRow, boxObjectTouching, boxWideEdgeObject

        var testDescription: String { rawValue }

        /// Whether the box must be found, with the rectangle and signature it
        /// has on its own.
        var findsBox: Bool {
            switch self {
            case .box, .boxTabRight, .boxTabLeft, .boxBothTabs: return true
            case .tabOnly, .boxLitRow, .boxObjectTouching, .boxWideEdgeObject: return false
            }
        }

        func band() throws -> LuminanceImage {
            let width = 603, height = 172
            var pixels = [UInt8](repeating: 0, count: width * height)
            func fill(_ ys: Range<Int>, _ xs: Range<Int>, _ value: UInt8) {
                for y in ys { for x in xs { pixels[y * width + x] = value } }
            }
            if self != .tabOnly {
                fill(36..<117, 192..<412, 120)
                fill(39..<114, 195..<409, 20)
                fill(60..<96, 230..<380, 230)
            }
            // The tab's lower end as the reported band shows it: grey to
            // the edge, from its first antialiased column at 0.939 of the width.
            let tabRight = 566..<width, tabLeft = 0..<(width - 566)
            switch self {
            case .boxTabRight, .tabOnly: fill(0..<30, tabRight, 137)
            case .boxTabLeft: fill(0..<30, tabLeft, 137)
            case .boxBothTabs: fill(0..<30, tabRight, 137); fill(0..<30, tabLeft, 137)
            case .boxLitRow: fill(140..<143, 0..<width, 90)
            case .boxObjectTouching: fill(50..<62, 412..<width, 137)
            case .boxWideEdgeObject: fill(0..<30, 280..<width, 137)
            case .box: break
            }
            return try LuminanceImage(width: width, height: height, pixels: pixels)
        }
    }

    /// What the tab may change in a slot strip reading: nothing in a read
    /// strip, and nothing in a window's or banner's `coveredByOverlay`. A
    /// frame without a strip stays without one, though its reason may change:
    /// the tab can be drawn over other content at the edge, cutting it, and
    /// on a busy screen its columns can make a row count as lit across.
    static func keeps(_ tabbed: gc_slot_status, plain: gc_slot_status) -> Bool {
        if plain == GC_SLOT_OK || plain == GC_SLOT_COVERED_BY_OVERLAY { return tabbed == plain }
        return tabbed != GC_SLOT_OK
    }

    static func expectSameBox(_ found: CommandNoticeDetector.Box?, _ expected: CommandNoticeDetector.Box?,
                              _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((found == nil) == (expected == nil), Comment(rawValue: label), sourceLocation: sourceLocation)
        guard let found, let expected else { return }
        #expect(found.rect == expected.rect, Comment(rawValue: "\(label): \(found.rect) vs \(expected.rect)"),
                sourceLocation: sourceLocation)
        #expect(found.signature == expected.signature, Comment(rawValue: "\(label): signature"),
                sourceLocation: sourceLocation)
    }
}

/// An object at the left or right screen edge, beside the game's slot
/// indicators and its command notice, as in a field report: the readers must
/// answer as they do without it. Objects inside the playing area must still
/// be rejected as before.
@Suite("Objects at the screen's side edges")
struct EdgeObjectTests {
    @Test("The edge tab keeps every fixture's strip reading and overlay verdict, and makes no strip",
          arguments: EdgeTab.Side.allCases)
    func stripReadings(side: EdgeTab.Side) throws {
        let reader = SlotStripReader()
        var readings = 0, fiveSlots = 0
        for (label, image) in try EdgeTab.frames() {
            let plain = reader.read(try ImageDecoder.topBand(EdgeTab.draw(image, side: nil)))
            let tabbed = reader.read(try ImageDecoder.topBand(EdgeTab.draw(image, side: side)))
            #expect(EdgeTab.keeps(CxxSlotStripTests.status(of: tabbed), plain: CxxSlotStripTests.status(of: plain)),
                    Comment(rawValue: "\(label): \(tabbed) with the tab, \(plain) without"))
            if case .success = plain { #expect(tabbed == plain, Comment(rawValue: label)) }
            if case .success(let reading) = plain {
                readings += 1
                if reading.slotCount == 5 { fiveSlots += 1 }
            }
        }
        #expect(readings >= 20 && fiveSlots >= 5, "the fixtures must include read strips: \(readings), \(fiveSlots)")
    }

    @Test("The edge tab across the countdown's rows leaves the countdown found as it was",
          arguments: EdgeTab.Side.allCases)
    func timerBar(side: EdgeTab.Side) throws {
        let reader = SlotStripReader()
        var timers = 0
        for (label, image) in try EdgeTab.frames() {
            let plain = reader.hasTimerBar(try ImageDecoder.topBand(EdgeTab.draw(image, side: nil)))
            // The tab's 0.069-0.182 moved to 0.199-0.312, over the track's rows.
            let tabbed = reader.hasTimerBar(try ImageDecoder.topBand(EdgeTab.draw(image, side: side, shift: 0.13)))
            #expect(tabbed == plain, Comment(rawValue: label))
            if plain { timers += 1 }
        }
        #expect(timers >= 3, "the fixtures must include countdowns: \(timers)")
    }

    @Test("The recorded notice is found under the edge tab, with the box it has without the tab")
    func recordedNotice() throws {
        let crop = try EdgeTab.image("Commands/complex-edge-tab.png")
        let luma = try ImageDecoder.decode(crop)
        let detector = CommandNoticeDetector()
        // Columns from 0.9 of the width hold only the tab.
        var plainPixels = luma.pixels, mirroredPixels = luma.pixels
        let edge = luma.width * 9 / 10
        for y in 0..<luma.height {
            for x in edge..<luma.width {
                plainPixels[y * luma.width + x] = 0
                mirroredPixels[y * luma.width + x] = 0
                mirroredPixels[y * luma.width + luma.width - 1 - x] = luma[x, y]
            }
        }
        let plain = try #require(detector.detect(LuminanceImage(width: luma.width, height: luma.height,
                                                                pixels: plainPixels)))
        #expect(plain.rect.minX > 150 && plain.rect.maxX < 450, "\(plain.rect)")
        EdgeTab.expectSameBox(detector.detect(luma), plain, "recorded tab at the right")
        EdgeTab.expectSameBox(detector.detect(try LuminanceImage(width: luma.width, height: luma.height,
                                                                 pixels: mirroredPixels)),
                              plain, "recorded tab mirrored at the left")
    }

    @Test("The edge tab leaves every command band's box as it was", arguments: EdgeTab.Side.allCases)
    func noticeBoxes(side: EdgeTab.Side) throws {
        let detector = CommandNoticeDetector()
        var boxes = 0
        for band in try EdgeTab.commandBands() {
            let plain = detector.detect(try ImageDecoder.decode(EdgeTab.draw(band.image, side: nil)))
            let tabbed = detector.detect(try ImageDecoder.decode(EdgeTab.draw(
                band.image, side: side, frameHeight: band.frameHeight, top: band.top)))
            EdgeTab.expectSameBox(tabbed, plain, "Commands/\(band.name)")
            if plain != nil { boxes += 1 }
        }
        #expect(boxes >= 6, "the command bands must include boxes: \(boxes)")
        for (label, image) in try EdgeTab.frames() {
            let plain = detector.detect(try EdgeTab.commandBand(of: EdgeTab.draw(image, side: nil)))
            let tabbed = detector.detect(try EdgeTab.commandBand(of: EdgeTab.draw(image, side: side)))
            EdgeTab.expectSameBox(tabbed, plain, label)
        }
    }

    @Test("A box is found beside edge objects and never under objects reaching it or the centre",
          arguments: EdgeTab.NoticeScene.allCases)
    func noticeScenes(scene: EdgeTab.NoticeScene) throws {
        let detector = CommandNoticeDetector()
        let alone = try #require(detector.detect(EdgeTab.NoticeScene.box.band()))
        EdgeTab.expectSameBox(detector.detect(try scene.band()), scene.findsBox ? alone : nil, scene.rawValue)
    }
}
