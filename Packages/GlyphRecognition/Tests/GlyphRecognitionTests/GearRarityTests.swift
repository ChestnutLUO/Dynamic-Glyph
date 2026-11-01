import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Gear rarity")
struct GearRarityTests {
    typealias RGB = (UInt8, UInt8, UInt8)
    let common: RGB = (65, 185, 150), rare: RGB = (170, 115, 245), veryRare: RGB = (240, 70, 185)
    let inactive: RGB = (80, 80, 85)

    func meter(_ bars: [RGB], width: Int = 42, height: Int = 32,
               shiftX: Double = 0, shiftY: Double = 0, solid: Bool = false) throws -> ColorImage {
        var pixels = [UInt8](repeating: 15, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let fy = Double(y) / Double(height) - shiftY
                for (index, center) in [0.216, 0.459, 0.702].enumerated() where index < bars.count {
                    let barX = (center + shiftX) * Double(width) + (0.5 - fy) * Double(height) * 0.35
                    if solid || ((0.23...0.77).contains(fy) && abs(Double(x) - barX) <= Double(width) * 0.065) {
                        let rgb = bars[index], offset = (y * width + x) * 3
                        pixels[offset] = rgb.0; pixels[offset + 1] = rgb.1; pixels[offset + 2] = rgb.2
                    }
                }
            }
        }
        return try ColorImage(width: width, height: height, pixels: pixels)
    }

    @Test("Colour and the full three-bar pattern must agree at different capture scales")
    func patterns() throws {
        for (bars, expected) in [([common, inactive, inactive], GearDropEntry.Rarity.common),
                                 ([rare, rare, inactive], .rare), ([veryRare, veryRare, veryRare], .veryRare)] {
            for scale in [1, 2, 3] {
                for shift in [-0.04, 0, 0.04] {
                    let pixels = try meter(bars, width: 42 * scale, height: 32 * scale, shiftX: shift, shiftY: shift)
                    #expect(GearRarityReader().read(pixels) == expected)
                }
            }
        }
    }

    @Test("Occlusion, mixed colours, wrong bar counts and flat colour stay unreadable")
    func rejectsAmbiguity() throws {
        for bars in [[inactive, inactive, inactive], [rare, inactive, inactive], [common, common, inactive],
                     [veryRare, veryRare, inactive], [common, rare, veryRare], [common], [rare, rare],
                     [(UInt8(220), UInt8(220), UInt8(220)), inactive, inactive]] {
            #expect(try GearRarityReader().read(meter(bars)) == nil)
        }
        #expect(try GearRarityReader().read(meter([veryRare, veryRare, veryRare], solid: true)) == nil)
    }

    func frame(_ time: Double, rarity: GearDropEntry.Rarity?, row: Int = 0) -> GearDropFrameEvidence {
        .init(sourceTime: time, stage: .portal, entries: [
            .init(column: 0, row: row, item: "Portal Shield", levelState: .notApplicable, level: nil,
                  quantity: 2, rarity: rarity)])
    }

    @Test("Rarity must agree twice over 100 ms; missing bars never add votes")
    func agreement() {
        // Unread meters between two rarity reads too far apart do not bridge them.
        let late = GearDropTracker.Policy().maximumReadingGap + 0.1
        for times in [[0.0], [0.0, 0.05], [0.0, late]] {
            var tracker = GearDropTracker()
            for time in (times + [0.5, 0.7]).sorted() {
                _ = tracker.accept(frame(time, rarity: times.contains(time) ? .veryRare : .unreadable))
            }
            let panel = tracker.finish(at: late + 0.1, reason: "test")?.panels.first
            // Unread rarity is shown on the item; it does not make the panel partial.
            #expect(panel?.entries.first?.rarity == .unreadable && panel?.partial == false)
        }
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0, rarity: .rare)); _ = tracker.accept(frame(0.2, rarity: .rare))
        _ = tracker.accept(frame(0.4, rarity: .unreadable))
        let panel = tracker.finish(at: 0.5, reason: "test")?.panels.first
        #expect(panel?.entries.first?.rarity == .rare && panel?.partial == false)
    }

    @Test("Contradicting confirmed rarities do not become a confident shield")
    func conflicts() {
        var tracker = GearDropTracker()
        for (time, rarity) in [(0.0, GearDropEntry.Rarity.rare), (0.2, .rare), (0.4, .veryRare), (0.6, .veryRare)] {
            _ = tracker.accept(frame(time, rarity: rarity))
        }
        let panel = tracker.finish(at: 0.7, reason: "test")?.panels.first
        #expect(panel?.partial == true && panel?.entries.isEmpty == true)
    }

    @Test("Two shields of different rarity keep separate positions and quantities")
    func distinctRows() {
        var tracker = GearDropTracker()
        for time in [0.0, 0.2] {
            _ = tracker.accept(.init(sourceTime: time, stage: .portal,
                entries: frame(time, rarity: .rare).entries + frame(time, rarity: .veryRare, row: 1).entries))
        }
        let group = tracker.finish(at: 0.3, reason: "test")
        #expect(group?.panels.first?.entries.map(\.rarity) == [.rare, .veryRare])
        #expect(group?.recognizedQuantity == 4)
    }

    @Test("Older entries decode without rarity and new rarity survives log serialization")
    func coding() throws {
        let old = Data(#"{"column":0,"row":0,"item":"Portal Shield","levelState":"notApplicable","quantity":2}"#.utf8)
        #expect(try JSONDecoder().decode(GearDropEntry.self, from: old).rarity == nil)
        let entry = frame(0, rarity: .veryRare).entries[0]
        #expect(try JSONDecoder().decode(GearDropEntry.self, from: JSONEncoder().encode(entry)) == entry)
        let levelled = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: 1)
        #expect(!levelled.hasRarityMeter)
        let key = GearDropEntry(column: 0, row: 0, item: "Portal Key", levelState: .notApplicable, level: nil, quantity: 1)
        #expect(!key.hasRarityMeter)
    }

    @Test("An item with one rarity takes it from its identity but still needs two item reads", arguments: [
        ("Aegis Shield", GearDropEntry.Rarity.veryRare), ("Hypercube", .veryRare), ("ADA Refactor", .veryRare),
        ("JARVIS Virus", .veryRare), ("SoftBank Ultra Link", .veryRare), ("ITO EN Transmuter (+)", .veryRare),
        ("ITO EN Transmuter (-)", .veryRare), ("Turret", .rare), ("Force Amp", .rare)])
    func fixedRarityIdentity(_ sample: (String, GearDropEntry.Rarity)) throws {
        let (item, rarity) = sample
        let parser = GearDropTextParser()
        let entry = try #require(parser.parseEntry("x1 \(item)", row: 0, column: 0))
        #expect(entry.rarity == rarity && entry.intrinsicRarity == rarity)
        // Items with several rarities, and truncations, still need their meter.
        for name in ["Portal Shield", "Heat Sink", "Multi-Hack", "Link Amp", "Kinetic Capsule", "Capsule",
                     "Unknown"] {
            let other = try #require(parser.parseEntry("x1 \(name)", row: 0, column: 0))
            #expect(other.rarity == nil && other.intrinsicRarity == nil)
        }
        for times in [[0.0], [0.0, 0.05], [0.0, 0.2]] {
            var tracker = GearDropTracker()
            for time in times { _ = tracker.accept(.init(sourceTime: time, stage: .bonus, entries: [entry])) }
            let panel = tracker.finish(at: 0.3, reason: "test")?.panels.first
            if times.last == 0.2 {
                #expect(panel?.entries.first?.rarity == rarity && panel?.partial == false)
                let data = try JSONEncoder().encode(panel)
                #expect(try JSONDecoder().decode(GearDropSummary.Panel.self, from: data).entries.first?.rarity == rarity)
            } else {
                #expect(panel?.entries.isEmpty == true && panel?.partial == true)
            }
        }
    }
}
