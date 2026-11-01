import Testing
@testable import GlyphRecognition

/// Recognition must not depend on which way the stroke was drawn.
///
/// The vocabulary permits this: no two Glyphs share an undirected edge set, so
/// the edge set is a complete key. These tests check both halves — that the
/// property holds of the data, *and* that `GlyphTable` actually exploits it.
/// An earlier version of this suite only checked the first half while the API
/// still matched ordered walks, so a reversed stroke resolved to the wrong
/// Glyph or to nothing at all.
@Suite("Direction independence", .enabled(if: ReferenceData.shapesAvailable))
struct DirectionIndependenceTests {
    @Test("No Glyph is another Glyph's exact reversal")
    func noReversalPairs() throws {
        let table = try ReferenceData.glyphTable()
        #expect(table.mirrorPairs.isEmpty, "found reversal pairs: \(table.mirrorPairs)")
    }

    @Test("Every Glyph is uniquely identified by its undirected edge set")
    func edgeSetsAreUnique() throws {
        let table = try ReferenceData.glyphTable()
        #expect(table.edgeSetCollisions.isEmpty,
                "direction-blind collisions: \(table.edgeSetCollisions)")
    }

    /// The behavioural test the old suite was missing.
    @Test("Every Glyph resolves from its reversed walk")
    func reversedWalksResolve() throws {
        let table = try ReferenceData.glyphTable()
        var checked = 0
        for id in table.glyphs {
            let path = try #require(table.path(for: id))
            #expect(table.glyph(matchingEdges: path) == id, "\(id) forward")
            #expect(table.glyph(matchingEdges: path.reversed) == id, "\(id) reversed")
            checked += 1
        }
        #expect(checked == 142)
    }

    /// Spelled out on the two cases from the review, because a sweep passing is
    /// easy to believe for the wrong reason.
    @Test("advance and balance both resolve either way round")
    func namedCases() throws {
        let table = try ReferenceData.glyphTable()

        let advance = try #require(table.path(for: GlyphID("advance")))
        #expect(advance.encoded == "038")
        #expect(advance.reversed.encoded == "830")
        #expect(table.glyph(matchingEdges: advance.reversed) == GlyphID("advance"))

        let balance = try #require(table.path(for: GlyphID("balance")))
        #expect(table.glyph(matchingEdges: balance.reversed) == GlyphID("balance"))
    }

    /// Ordered lookup remains available and remains order-sensitive. That is
    /// not a bug, but it is why it must not be the recognition path.
    @Test("Ordered lookup still fails on a reversed walk, by design")
    func orderedLookupIsOrderSensitive() throws {
        let table = try ReferenceData.glyphTable()
        let advance = try #require(table.path(for: GlyphID("advance")))
        #expect(table.glyph(matching: advance) == GlyphID("advance"))
        #expect(table.glyph(matching: advance.reversed) == nil)
    }

    @Test("Edge distance tolerates a missing or spurious segment")
    func edgeDistance() throws {
        let table = try ReferenceData.glyphTable()
        let advance = try #require(table.path(for: GlyphID("advance")))   // 0-3, 3-8
        let exact = try #require(table.nearestByEdges(to: advance, maxDistance: 0).first)
        #expect(exact.id == GlyphID("advance"))
        #expect(exact.distance == 0)

        // Drop the second segment: one edge missing, so distance 1.
        let truncated = try #require(GlyphPath(encoded: "03"))
        let near = table.nearestByEdges(to: truncated, maxDistance: 1)
        #expect(near.contains { $0.id == GlyphID("advance") && $0.distance == 1 })
    }
}
