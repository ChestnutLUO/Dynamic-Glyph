import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Multiplied gear quantities")
struct GearQuantityColorTests {
    typealias RGB = (UInt8, UInt8, UInt8)
    /// Measured in the supplied first-hack-of-the-day panels and normal ones.
    let red: RGB = (200, 0, 35), faintRed: RGB = (117, 0, 18), white: RGB = (235, 235, 240)
    /// An L5 level sits beside a quantity and is itself close to red.
    let levelFive: RGB = (186, 0, 52), levelEight: RGB = (150, 40, 244)
    let background: RGB = (17, 17, 32)

    /// A quantity box: vertical strokes of `ink` over the panel background,
    /// and optionally a stroke of `other` at its left edge.
    func box(_ ink: RGB, other: RGB? = nil, strokes: Int = 3) throws -> ColorImage {
        let width = 36, height = 22
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                var rgb = background
                if (3..<19).contains(y), x % 10 < 3, x / 10 < strokes { rgb = ink }
                if let other, x < 6, (3..<19).contains(y) { rgb = other }
                let offset = (y * width + x) * 3
                pixels[offset] = rgb.0; pixels[offset + 1] = rgb.1; pixels[offset + 2] = rgb.2
            }
        }
        return try ColorImage(width: width, height: height, pixels: pixels)
    }

    @Test("Red is multiplied and white is not, even while fading in")
    func colours() throws {
        let reader = GearQuantityColorReader()
        #expect(reader.read(try box(red)) == true)
        #expect(reader.read(try box(faintRed)) == true)
        #expect(reader.read(try box(white)) == false)
    }

    @Test("A box that takes in a level, or holds too little text, stays unread")
    func unclear() throws {
        let reader = GearQuantityColorReader()
        #expect(reader.read(try box(white, other: levelFive)) == nil)
        #expect(reader.read(try box(red, other: levelEight)) == nil)
        #expect(reader.read(try box(levelEight)) == nil)
        #expect(reader.read(try box(red, strokes: 0)) == nil)
        #expect(reader.read(try box((60, 0, 10))) == nil)
    }

    func frame(_ time: Double, quantity: Int = 2, multiplied: Bool?) -> GearDropFrameEvidence {
        .init(sourceTime: time, stage: .portal, entries: [
            GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 8,
                          quantity: quantity, multiplied: multiplied)
        ])
    }

    func settled(_ reads: [(Double, Int, Bool?)]) throws -> GearDropEntry? {
        var tracker = GearDropTracker()
        for (time, quantity, multiplied) in reads { _ = tracker.accept(frame(time, quantity: quantity, multiplied: multiplied)) }
        let finished = tracker.finish(at: 1, reason: "test")
        let summary = try #require(finished)
        return summary.panels.first?.entries.first
    }

    @Test("Two agreeing reads mark a drop multiplied; one read or a contradiction leaves it unmarked")
    func voting() throws {
        #expect(try settled([(0, 2, true), (0.1, 2, true)])?.multiplied == true)
        #expect(try settled([(0, 2, false), (0.1, 2, false)])?.multiplied == false)
        #expect(try settled([(0, 2, true), (0.1, 2, nil)])?.multiplied == nil)
        let contradicted = try settled([(0, 2, true), (0.1, 2, false), (0.2, 2, true)])
        // The item itself still counts: colour never makes a row unread.
        #expect(contradicted?.quantity == 2 && contradicted?.multiplied == nil)
    }

    @Test("Only reads of the settled quantity vote on its colour")
    func otherQuantity() throws {
        let entry = try settled([(0, 1, false), (0.05, 1, false), (0.3, 2, true), (0.4, 2, true), (0.5, 2, nil)])
        #expect(entry?.quantity == 2 && entry?.multiplied == true)
    }

    @Test("The colour round-trips in logs, and older entries decode without it")
    func coding() throws {
        let entry = GearDropEntry(column: 1, row: 2, item: "Resonator", levelState: .known, level: 8,
                                  quantity: 6, multiplied: true)
        #expect(try JSONDecoder().decode(GearDropEntry.self, from: JSONEncoder().encode(entry)) == entry)
        let old = Data(#"{"column":0,"row":0,"item":"Resonator","levelState":"known","level":8,"quantity":1}"#.utf8)
        #expect(try JSONDecoder().decode(GearDropEntry.self, from: old).multiplied == nil)
        let unread = try JSONEncoder().encode(entry.withMultiplied(nil))
        #expect(String(decoding: unread, as: UTF8.self).contains("multiplied") == false)
        #expect(entry.withRarity(.rare).multiplied == true)
    }
}
