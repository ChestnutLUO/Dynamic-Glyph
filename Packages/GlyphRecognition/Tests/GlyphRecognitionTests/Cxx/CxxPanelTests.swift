import CoreGraphics
import Foundation
import Testing
@testable import GlyphRecognition
import GlyphRecognitionImages
import GlyphCoreCxx

@Suite("C++ panels: result, gear, portal and the command box")
struct CxxPanelTests {
    /// The band's rows of a frame as the colour image the Swift detectors read.
    static func colorBand(_ image: CGImage, rows: Range<Int>) throws -> ColorImage {
        try ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: rows.lowerBound, width: image.width,
                                                        height: rows.count))
    }

    /// The same band as a capture would hold it: 32-bit BGRA with padded rows.
    static func withBGRA<R>(_ band: ColorImage, _ body: (gc_color_image) throws -> R) throws -> R {
        let bytesPerRow = band.width * 4 + 8
        var bytes = [UInt8](repeating: 0x5A, count: bytesPerRow * band.height)
        for y in 0..<band.height {
            for x in 0..<band.width {
                let pixel = band[x, y], base = y * bytesPerRow + x * 4
                bytes[base] = pixel.blue
                bytes[base + 1] = pixel.green
                bytes[base + 2] = pixel.red
                bytes[base + 3] = 255
            }
        }
        return try bytes.withUnsafeBufferPointer { buffer in
            try body(gc_color_image(data: buffer.baseAddress, width: Int32(band.width), height: Int32(band.height),
                                    bytesPerRow: Int32(bytesPerRow), bytesPerPixel: 4, redOffset: 2, greenOffset: 1,
                                    blueOffset: 0))
        }
    }

    @Test("Result candidate equals ResultPanelDetector on every fixture, and some fixture is one")
    func resultCandidate() throws {
        var positives = 0
        for fixture in try LumaPanelFixtures.all() {
            let luma = try ImageDecoder.decode(fixture.image)
            let oracle = ResultPanelDetector().isCandidate(luma)
            let candidate = try LumaPanelFixtures.withGray(luma) { gc_result_candidate($0) }
            #expect(candidate == oracle, "\(fixture.folder)/\(fixture.name)")
            if oracle { positives += 1 }
        }
        #expect(positives > 0, "no fixture exercises the candidate path")
    }

    @Test("Gear and portal bands equal the Swift detectors' for every frame height up to 4000")
    func bands() {
        for frameHeight in 1...4000 {
            var top: Int32 = -1, bottom: Int32 = -1
            gc_gear_band(Int32(frameHeight), &top, &bottom)
            let gear = GearDropPanelDetector.band(frameHeight: frameHeight)
            #expect(Int(top) == gear.lowerBound && Int(bottom) == gear.upperBound, "gear band at \(frameHeight)")
            gc_portal_band(Int32(frameHeight), &top, &bottom)
            let portal = PortalScreenDetector.band(frameHeight: frameHeight)
            #expect(Int(top) == portal.lowerBound && Int(bottom) == portal.upperBound, "portal band at \(frameHeight)")
        }
    }

    @Test("Command band equals CommandNoticeDetector.band for every frame size the phones deliver")
    func commandBand() {
        for frameHeight in 1...4000 {
            let frameWidth = max(1, frameHeight * 9 / 20)
            var top: Int32 = -1, bottom: Int32 = -1
            gc_command_band(Int32(frameWidth), Int32(frameHeight), &top, &bottom)
            let rect = CommandNoticeDetector.band(width: frameWidth, height: frameHeight)
            #expect(Int(top) == Int(rect.minY) && Int(bottom) == Int(rect.maxY), "command band at \(frameHeight)")
        }
    }

    @Test("Gear candidate equals GearDropPanelDetector on every fixture's band, as RGB and as padded BGRA")
    func gearCandidate() throws {
        var positives = 0
        for fixture in try LumaPanelFixtures.all() where fixture.image.height > fixture.image.width {
            let frameHeight = fixture.image.height
            let rows = GearDropPanelDetector.band(frameHeight: frameHeight)
            let band = try Self.colorBand(fixture.image, rows: rows)
            let oracle = GearDropPanelDetector().candidate(in: band, frameHeight: frameHeight, bandTop: rows.lowerBound)
            let label = "\(fixture.folder)/\(fixture.name)"
            var bounds = gc_panel_bounds()
            let rgb = try LumaPanelFixtures.withColor(band) {
                gc_gear_candidate($0, Int32(frameHeight), Int32(rows.lowerBound), &bounds)
            }
            #expect(rgb == (oracle != nil), "\(label)")
            if let oracle, rgb {
                #expect(bounds.top == oracle.top && bounds.bottom == oracle.bottom, "\(label)")
                positives += 1
            }
            var fromBGRA = gc_panel_bounds()
            let bgra = try Self.withBGRA(band) {
                gc_gear_candidate($0, Int32(frameHeight), Int32(rows.lowerBound), &fromBGRA)
            }
            #expect(bgra == rgb, "\(label) from BGRA")
            if bgra, rgb { #expect(fromBGRA.top == bounds.top && fromBGRA.bottom == bounds.bottom, "\(label)") }
            // The whole frame, as the Swift tests read it.
            let whole = try Self.colorBand(fixture.image, rows: 0..<frameHeight)
            let wholeOracle = GearDropPanelDetector().candidate(in: whole)
            var wholeBounds = gc_panel_bounds()
            let wholeFound = try LumaPanelFixtures.withColor(whole) {
                gc_gear_candidate($0, Int32(frameHeight), 0, &wholeBounds)
            }
            #expect(wholeFound == (wholeOracle != nil), "\(label) whole frame")
            if let wholeOracle, wholeFound {
                #expect(wholeBounds.top == wholeOracle.top && wholeBounds.bottom == wholeOracle.bottom, "\(label)")
            }
        }
        #expect(positives >= 4, "the Gear fixtures should show panels: \(positives)")
    }

    /// `band` with the columns in each of `spans` (fractions of its width)
    /// painted black, as sparks or the key list's cards leave a panel side.
    static func covering(_ band: ColorImage, _ spans: [(Double, Double)]) throws -> ColorImage {
        var pixels = band.pixels
        for (left, right) in spans {
            let from = max(0, Int(left * Double(band.width))), to = min(band.width, Int(right * Double(band.width)) + 1)
            guard from < to else { continue }
            for y in 0..<band.height {
                for x in from..<to { let base = (y * band.width + x) * 3; pixels[base...base + 2] = [0, 0, 0] }
            }
        }
        return try ColorImage(width: band.width, height: band.height, pixels: pixels)
    }

    @Test("Gear candidate equals GearDropPanelDetector with either, both or parts of the panel sides covered")
    func gearCandidateSides() throws {
        let covers: [[(Double, Double)]] = [
            [(0.0, 0.045)], [(0.955, 1.0)], [(0.0, 0.045), (0.955, 1.0)],
            [(0.0, 0.029)], [(0.971, 1.0)], [(0.0, 0.029), (0.971, 1.0)],
            [(0.014, 0.016)], [(0.027, 0.029)], [(0.041, 0.043)], [(0.957, 0.959)], [(0.971, 0.973)],
            [(0.984, 0.986)], [(0.0, 0.5)], [(0.5, 1.0)], [(0.0, 0.03), (0.97, 1.0)], [(0.03, 0.97)],
        ]
        var found = 0, lost = 0
        for fixture in try LumaPanelFixtures.all() where fixture.image.height > fixture.image.width {
            let frameHeight = fixture.image.height
            let rows = GearDropPanelDetector.band(frameHeight: frameHeight)
            let band = try Self.colorBand(fixture.image, rows: rows)
            let shown = GearDropPanelDetector().candidate(in: band, frameHeight: frameHeight, bandTop: rows.lowerBound)
            // Covering a side only matters where a panel or a box-like screen is.
            guard shown != nil || fixture.folder == "Gear" else { continue }
            for (index, cover) in covers.enumerated() {
                let covered = try Self.covering(band, cover)
                let oracle = GearDropPanelDetector().candidate(in: covered, frameHeight: frameHeight,
                                                               bandTop: rows.lowerBound)
                var bounds = gc_panel_bounds()
                let candidate = try LumaPanelFixtures.withColor(covered) {
                    gc_gear_candidate($0, Int32(frameHeight), Int32(rows.lowerBound), &bounds)
                }
                let label = "\(fixture.folder)/\(fixture.name) cover \(index)"
                #expect(candidate == (oracle != nil), "\(label)")
                if let oracle, candidate {
                    #expect(bounds.top == oracle.top && bounds.bottom == oracle.bottom, "\(label)")
                }
                if shown != nil { if oracle != nil { found += 1 } else { lost += 1 } }
            }
        }
        // The covers must both keep and lose panels, or the side rule goes untested.
        #expect(found > 10 && lost > 10, "\(found) kept, \(lost) lost")
    }

    @Test("Portal faction equals PortalScreenDetector on every fixture's band, as RGB and as padded BGRA")
    func portalFaction() throws {
        func code(_ faction: PortalFaction?) -> gc_faction {
            switch faction {
            case nil: return GC_FACTION_NONE
            case .resistance: return GC_FACTION_RESISTANCE
            case .enlightened: return GC_FACTION_ENLIGHTENED
            case .machina: return GC_FACTION_MACHINA
            }
        }
        var factions: Set<PortalFaction> = []
        for fixture in try LumaPanelFixtures.all() where fixture.image.height > fixture.image.width {
            let frameHeight = fixture.image.height
            let rows = PortalScreenDetector.band(frameHeight: frameHeight)
            let band = try Self.colorBand(fixture.image, rows: rows)
            let oracle = PortalScreenDetector().faction(band, frameHeight: frameHeight, bandTop: rows.lowerBound)
            if let oracle { factions.insert(oracle) }
            let label = "\(fixture.folder)/\(fixture.name)"
            let rgb = try LumaPanelFixtures.withColor(band) {
                gc_portal_faction($0, Int32(frameHeight), Int32(rows.lowerBound))
            }
            #expect(rgb == code(oracle), "\(label)")
            let bgra = try Self.withBGRA(band) { gc_portal_faction($0, Int32(frameHeight), Int32(rows.lowerBound)) }
            #expect(bgra == code(oracle), "\(label) from BGRA")
            let whole = try Self.colorBand(fixture.image, rows: 0..<frameHeight)
            let wholeOracle = PortalScreenDetector().faction(whole, frameHeight: frameHeight, bandTop: 0)
            let wholeFound = try LumaPanelFixtures.withColor(whole) { gc_portal_faction($0, Int32(frameHeight), 0) }
            #expect(wholeFound == code(wholeOracle), "\(label) whole frame")
        }
        #expect(factions.count >= 2, "the PortalLevel fixtures should show more than one faction: \(factions)")
    }

    @Test("Command box equals CommandNoticeDetector on every band fixture and every frame's band")
    func commandBox() throws {
        var positives = 0
        for fixture in try LumaPanelFixtures.all() {
            let image: CGImage
            if fixture.image.height > fixture.image.width {
                let band = CommandNoticeDetector.band(width: fixture.image.width, height: fixture.image.height)
                image = try #require(fixture.image.cropping(to: band))
            } else {
                image = fixture.image
            }
            let luma = try ImageDecoder.decode(image)
            let oracle = CommandNoticeDetector().detect(luma)
            var box = gc_command_box()
            let found = try LumaPanelFixtures.withGray(luma) { gc_command_box_detect($0, &box) }
            let label = "\(fixture.folder)/\(fixture.name)"
            #expect(found == (oracle != nil), "\(label)")
            guard let oracle, found else { continue }
            positives += 1
            #expect(Int(box.x) == Int(oracle.rect.minX) && Int(box.y) == Int(oracle.rect.minY)
                    && Int(box.width) == Int(oracle.rect.width) && Int(box.height) == Int(oracle.rect.height),
                    "\(label): rect \(box.x) \(box.y) \(box.width) \(box.height) vs \(oracle.rect)")
            let signature = withUnsafeBytes(of: &box.signature) { Array($0) }
            #expect(signature == oracle.signature, "\(label): signature")
        }
        #expect(positives >= 4, "the Commands fixtures should show notice boxes: \(positives)")
    }

    static func commandBox(_ luma: LuminanceImage) throws -> gc_command_box? {
        var box = gc_command_box()
        return try LumaPanelFixtures.withGray(luma) { gc_command_box_detect($0, &box) } ? box : nil
    }

    static func expectEqual(_ box: gc_command_box?, _ oracle: CommandNoticeDetector.Box?, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((box == nil) == (oracle == nil), Comment(rawValue: label), sourceLocation: sourceLocation)
        guard var box, let oracle else { return }
        #expect(Int(box.x) == Int(oracle.rect.minX) && Int(box.y) == Int(oracle.rect.minY)
                && Int(box.width) == Int(oracle.rect.width) && Int(box.height) == Int(oracle.rect.height),
                Comment(rawValue: "\(label): rect \(box.x) \(box.y) \(box.width) \(box.height) vs \(oracle.rect)"),
                sourceLocation: sourceLocation)
        let signature = withUnsafeBytes(of: &box.signature) { Array($0) }
        #expect(signature == oracle.signature, Comment(rawValue: "\(label): signature"), sourceLocation: sourceLocation)
    }

    @Test("Command box beside the edge tab equals CommandNoticeDetector", arguments: EdgeTab.Side.allCases)
    func commandBoxEdgeTab(side: EdgeTab.Side) throws {
        var positives = 0
        for band in try EdgeTab.commandBands() {
            let luma = try ImageDecoder.decode(EdgeTab.draw(band.image, side: side, frameHeight: band.frameHeight,
                                                            top: band.top))
            let oracle = CommandNoticeDetector().detect(luma)
            Self.expectEqual(try Self.commandBox(luma), oracle, "Commands/\(band.name)")
            if oracle != nil { positives += 1 }
        }
        #expect(positives >= 7, "the command bands with the tab must include boxes: \(positives)")
        for scene in EdgeTab.NoticeScene.allCases {
            let luma = try scene.band()
            Self.expectEqual(try Self.commandBox(luma), CommandNoticeDetector().detect(luma), scene.rawValue)
        }
    }

    @Test("Command box on a padded band equals the packed one")
    func commandBoxPaddedRows() throws {
        for fixture in try LumaPanelFixtures.fixtures(in: "Commands") {
            let luma = try ImageDecoder.decode(fixture.image)
            let bytesPerRow = luma.width + 13
            var padded = [UInt8](repeating: 0xFF, count: bytesPerRow * luma.height)
            for y in 0..<luma.height {
                for x in 0..<luma.width { padded[y * bytesPerRow + x] = luma[x, y] }
            }
            var packedBox = gc_command_box(), paddedBox = gc_command_box()
            let packed = try LumaPanelFixtures.withGray(luma) { gc_command_box_detect($0, &packedBox) }
            let found = padded.withUnsafeBufferPointer { buffer in
                gc_command_box_detect(gc_gray_image(data: buffer.baseAddress, width: Int32(luma.width),
                                                    height: Int32(luma.height), bytesPerRow: Int32(bytesPerRow)),
                                      &paddedBox)
            }
            #expect(found == packed, "\(fixture.name)")
            guard found, packed else { continue }
            #expect(packedBox.x == paddedBox.x && packedBox.y == paddedBox.y && packedBox.width == paddedBox.width
                    && packedBox.height == paddedBox.height, "\(fixture.name)")
            let a = withUnsafeBytes(of: &packedBox.signature) { Array($0) }
            let b = withUnsafeBytes(of: &paddedBox.signature) { Array($0) }
            #expect(a == b, "\(fixture.name)")
        }
    }

    @Test("Empty and degenerate images are never a panel")
    func degenerate() {
        var bounds = gc_panel_bounds()
        var box = gc_command_box()
        let emptyGray = gc_gray_image(data: nil, width: 0, height: 0, bytesPerRow: 0)
        let emptyColor = gc_color_image(data: nil, width: 0, height: 0, bytesPerRow: 0, bytesPerPixel: 3,
                                        redOffset: 0, greenOffset: 1, blueOffset: 2)
        #expect(!gc_result_candidate(emptyGray))
        #expect(!gc_command_box_detect(emptyGray, &box))
        #expect(!gc_gear_candidate(emptyColor, 1310, 0, &bounds))
        #expect(gc_portal_faction(emptyColor, 1310, 0) == GC_FACTION_NONE)
        // A band with pixels but a frame that is no phone, a band outside the
        // frame rows the detector samples, and a stride too short for the width.
        let pixels = [UInt8](repeating: 200, count: 300 * 4 * 3)
        pixels.withUnsafeBufferPointer { buffer in
            let band = gc_color_image(data: buffer.baseAddress, width: 300, height: 4, bytesPerRow: 900,
                                      bytesPerPixel: 3, redOffset: 0, greenOffset: 1, blueOffset: 2)
            #expect(!gc_gear_candidate(band, 300, 0, &bounds))
            #expect(gc_portal_faction(band, 300, 0) == GC_FACTION_NONE)
            #expect(!gc_gear_candidate(band, 660, 0, &bounds))
            #expect(gc_portal_faction(band, 660, 0) == GC_FACTION_NONE)
            #expect(!gc_gear_candidate(band, 660, 100_000, &bounds))
            let short = gc_color_image(data: buffer.baseAddress, width: 300, height: 4, bytesPerRow: 100,
                                       bytesPerPixel: 3, redOffset: 0, greenOffset: 1, blueOffset: 2)
            #expect(!gc_gear_candidate(short, 660, 0, &bounds))
            #expect(gc_portal_faction(short, 660, 0) == GC_FACTION_NONE)
            let gray = gc_gray_image(data: buffer.baseAddress, width: 300, height: 12, bytesPerRow: 300)
            #expect(!gc_result_candidate(gray))
            #expect(!gc_command_box_detect(gray, &box))
        }
        var top: Int32 = -1, bottom: Int32 = -1
        gc_gear_band(0, &top, &bottom)
        #expect(top == 0 && bottom == 0)
        gc_portal_band(-5, &top, &bottom)
        #expect(top == 0 && bottom == 0)
        gc_command_band(0, 0, &top, &bottom)
        #expect(top == 0 && bottom == 0)
    }
}
