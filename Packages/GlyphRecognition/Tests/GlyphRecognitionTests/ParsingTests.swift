import Testing
@testable import GlyphRecognition

/// Both parsers are strict. A silently dropped or silently rewritten row turns
/// into a recognition failure that looks like a vision bug, which is the most
/// expensive kind of error to chase.
@Suite("Parsing")
struct ParsingTests {
    // MARK: Line endings

    /// The reference files disagree: the shape table is LF, the sequence table
    /// is CRLF. Swift treats CRLF as one grapheme cluster, so splitting on a
    /// `"\n"` Character silently matches nothing and the whole file parses as a
    /// single row.
    @Test("LF and CRLF parse identically", arguments: ["\n", "\r\n", "\r"])
    func lineEndings(separator: String) throws {
        let shapes = try GlyphTable.parse(csv: ["advance,038", "clear,05a"].joined(separator: separator))
        #expect(shapes.count == 2)
        let sequences = try SequenceTable.parse(csv: ["a,b,,,", "c,d,e,,"].joined(separator: separator))
        #expect(sequences.count == 2)
        #expect(sequences.sequences[1].count == 3)
    }

    // MARK: Shape table

    @Test("Surplus columns are rejected")
    func surplusColumns() {
        #expect(throws: GlyphTable.ParseError.wrongColumnCount(line: 1, found: 3)) {
            try GlyphTable.parse(csv: "advance,038,extra")
        }
    }

    @Test("An unparseable shape is rejected")
    func invalidShape() {
        #expect(throws: GlyphTable.ParseError.invalidShape(line: 1, shape: "0z8")) {
            try GlyphTable.parse(csv: "advance,0z8")
        }
    }

    @Test("A repeated name is rejected")
    func duplicateName() {
        #expect(throws: GlyphTable.ParseError.duplicateName(line: 2, name: GlyphID("advance"))) {
            try GlyphTable.parse(csv: "advance,038\nadvance,05a")
        }
    }

    /// A header is only a header on line 1. The previous implementation skipped
    /// any row whose shape began with "shape", anywhere in the file, which
    /// silently discarded data.
    @Test("A header is accepted only as the first line")
    func headerOnlyFirst() throws {
        let withHeader = try GlyphTable.parse(csv: "name,shape(using 0..9 and a)\nadvance,038")
        #expect(withHeader.count == 1)

        #expect(throws: GlyphTable.ParseError.invalidShape(line: 2, shape: "shapefile")) {
            try GlyphTable.parse(csv: "advance,038\nmid,shapefile")
        }
    }

    // MARK: Sequence table

    @Test("Trailing padding is stripped")
    func trailingPadding() throws {
        let t = try SequenceTable.parse(csv: "gain,safety,,,")
        #expect(t.sequences == [[GlyphID("gain"), GlyphID("safety")]])
    }

    /// The regression the review found: an empty field *between* two names was
    /// silently closed up, inventing a sequence that does not exist.
    @Test("An interior gap is rejected rather than closed up")
    func interiorGap() {
        #expect(throws: SequenceTable.ParseError.interiorGap(line: 1, contents: "advance,,attack,,,")) {
            try SequenceTable.parse(csv: "advance,,attack,,,")
        }
    }

    @Test("A sequence longer than five Glyphs is rejected")
    func tooManyGlyphs() {
        #expect(throws: SequenceTable.ParseError.tooManyGlyphs(line: 1, found: 6)) {
            try SequenceTable.parse(csv: "a,b,c,d,e,f")
        }
    }

    @Test("An entirely empty input is rejected")
    func emptyInput() {
        #expect(throws: SequenceTable.ParseError.empty) { try SequenceTable.parse(csv: "\n\n") }
        #expect(throws: GlyphTable.ParseError.empty) { try GlyphTable.parse(csv: "\n\n") }
    }
}
