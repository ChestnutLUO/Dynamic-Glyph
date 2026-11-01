import Testing
@testable import GlyphRecognition

@Suite("Reference tables")
struct ReferenceTableTests {
    @Test("The shape table parses to the expected vocabulary", .enabled(if: ReferenceData.shapesAvailable))
    func shapeTable() throws {
        let table = try ReferenceData.glyphTable()
        #expect(table.count == 142)
        let advance = try #require(table.path(for: GlyphID("advance")))
        #expect(advance.encoded == "038")
        let balance = try #require(table.path(for: GlyphID("balance")))
        #expect(balance.encoded == "0568a975")
    }

    @Test("Exact lookup recovers the name from the walk", .enabled(if: ReferenceData.shapesAvailable))
    func exactLookup() throws {
        let table = try ReferenceData.glyphTable()
        let path = try #require(GlyphPath(encoded: "038"))
        #expect(table.glyph(matching: path) == GlyphID("advance"))
        #expect(table.glyph(matching: try #require(GlyphPath(encoded: "01"))) == nil)
    }

    @Test("Nearest-match ranks an exact hit at distance zero", .enabled(if: ReferenceData.shapesAvailable))
    func nearestMatch() throws {
        let table = try ReferenceData.glyphTable()
        let exact = try #require(GlyphPath(encoded: "038"))
        let first = try #require(table.nearest(to: exact).first)
        #expect(first.id == GlyphID("advance"))
        #expect(first.distance == 0)
    }

    @Test("The sequence table parses and every referenced Glyph is defined", .enabled(if: ReferenceData.isAvailable))
    func sequenceTable() throws {
        let sequences = try ReferenceData.sequenceTable()
        let shapes = try ReferenceData.glyphTable()
        // 542 rows in the file, two of which are repeats of earlier rows.
        // Both numbers are asserted: the row count catches dropped lines (it is
        // what would have caught the CRLF parsing failure), and the distinct
        // count catches a regression in deduplication.
        #expect(sequences.rowCount == 542)
        #expect(sequences.count == 540)

        let referenced = Set(sequences.sequences.flatMap { $0 })
        let defined = Set(shapes.glyphs)
        #expect(referenced.subtracting(defined).isEmpty,
                "Sequence table references Glyphs with no shape")
        #expect(referenced.count == 140)

        let lengths = Set(sequences.sequences.map(\.count))
        #expect(lengths == [2, 3, 4, 5])
    }
}
