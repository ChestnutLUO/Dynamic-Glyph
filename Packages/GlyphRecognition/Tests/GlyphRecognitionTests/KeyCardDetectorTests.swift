import Testing
@testable import GlyphRecognition

/// Synthetic frames: a dark screen with one dark card rectangle bounded by
/// brighter pixels, the way a key inventory shows on the game's dark theme.
struct KeyCardDetectorTests {
    /// Builds a frame with a dark card interior at `card`, bright border
    /// pixels around it, and optional bright strips inside the card. The
    /// surrounding screen is dark with sparse bright noise, so the frame
    /// holds more than the policy's minimum region count.
    func frame(width: Int, height: Int, card: (x: Int, y: Int, width: Int, height: Int),
               strips: ((Int, Int) -> Bool)? = nil) throws -> LuminanceImage {
        var pixels = [UInt8](repeating: 20, count: width * height)
        // Sparse bright noise outside the card, so the dark mask is split
        // into many regions like a real screen's.
        for y in stride(from: 0, to: height, by: 37) {
            for x in stride(from: 0, to: width, by: 23) {
                let insideCard = x >= card.x && x < card.x + card.width
                    && y >= card.y && y < card.y + card.height
                if !insideCard { pixels[y * width + x] = 200 }
            }
        }
        // The card's bright border.
        for y in card.y..<(card.y + card.height) {
            for x in card.x..<(card.x + card.width) {
                let edge = x == card.x || x == card.x + card.width - 1
                    || y == card.y || y == card.y + card.height - 1
                if edge { pixels[y * width + x] = 220 }
            }
        }
        // Bright strips inside the card, for the count and name text.
        if let strips {
            for y in card.y..<(card.y + card.height) where strips(y - card.y, card.height) {
                for x in (card.x + 8)..<(card.x + card.width - 8) where (x - card.x) % 7 != 3 {
                    pixels[y * width + x] = 180
                }
            }
        }
        return try LuminanceImage(width: width, height: height, pixels: pixels)
    }

    /// The detector's geometry tests run with a relaxed region count: these
    /// synthetic frames show only the background and the card, where a real
    /// inventory screen always shows more bounded regions (neighbouring
    /// cards). The region-count policy itself is pinned by `noCard`.
    func detector() -> KeyCardDetector {
        var policy = KeyCardDetector.Policy()
        policy.minimumRegions = 2
        return KeyCardDetector(policy: policy)
    }

    @Test("A tall card reads as an Inventory card at its bounds")
    func inventoryCard() throws {
        let image = try frame(width: 600, height: 1200, card: (x: 150, y: 200, width: 300, height: 500),
                              strips: { row, _ in row < 50 || row > 430 })
        let card = try #require(detector().detect(in: image))
        #expect(card.kind == .inventory)
        #expect(card.x == 151 && card.y == 201)
        #expect(card.width == 298 && card.height == 498)
        #expect((1.35...1.85).contains(card.aspectRatio))
    }

    @Test("A near-square card reads as a Capsule card")
    func capsuleCard() throws {
        let image = try frame(width: 600, height: 1200, card: (x: 100, y: 300, width: 400, height: 380),
                              strips: { row, _ in row < 60 || row > 300 })
        let card = try #require(detector().detect(in: image))
        #expect(card.kind == .capsule)
    }

    @Test("An aspect ratio between the two bands reads no card")
    func betweenBands() throws {
        // 500 x 550 is 1.1 tall over wide: outside both bands.
        let image = try frame(width: 700, height: 1200, card: (x: 100, y: 300, width: 500, height: 550))
        #expect(detector().detect(in: image) == nil)
    }

    @Test("A frame with no card reads none")
    func noCard() throws {
        var pixels = [UInt8](repeating: 20, count: 600 * 1200)
        for y in stride(from: 0, to: 1200, by: 41) {
            for x in stride(from: 0, to: 600, by: 29) { pixels[y * 600 + x] = 200 }
        }
        let image = try LuminanceImage(width: 600, height: 1200, pixels: pixels)
        #expect(KeyCardDetector().detect(in: image) == nil)
    }

    @Test("A card no larger than a sliver reads none")
    func tinyCard() throws {
        let image = try frame(width: 600, height: 1200, card: (x: 200, y: 500, width: 60, height: 90))
        #expect(detector().detect(in: image) == nil)
    }

    @Test("Regions follow the measured strip fractions")
    func regions() throws {
        let card = KeyCardBounds(x: 10, y: 20, width: 300, height: 500, kind: .inventory)
        let count = card.countRegion()
        #expect(count.y == card.y)
        #expect(count.height == 50) // a tenth of the card's height
        let name = card.nameRegion()
        #expect(name.y == card.y + 437) // H - H/8 from the card's top
        #expect(name.height == 33) // H/15, rounded down
        let capsule = KeyCardBounds(x: 0, y: 0, width: 400, height: 380, kind: .capsule)
        #expect(capsule.countRegion().height == 61) // H/6.2
        #expect(capsule.nameRegion().y == 295) // H - H/4.5
        #expect(capsule.nameRegion().height == 47) // H/8
    }
}
