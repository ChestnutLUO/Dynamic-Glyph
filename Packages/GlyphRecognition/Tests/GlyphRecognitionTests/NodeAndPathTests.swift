import Testing
@testable import GlyphRecognition

@Suite("Node and path encoding")
struct NodeAndPathTests {
    @Test("The array has exactly eleven nodes, written 0-9 and a")
    func nodeAlphabet() {
        #expect(NodeIndex.count == 11)
        #expect(NodeIndex.all.map(\.character) == Array("0123456789a"))
        #expect(NodeIndex(character: "b") == nil)
        #expect(NodeIndex(character: "A") != nil)      // hexDigitValue is case-insensitive
        #expect(NodeIndex(rawValue: 11) == nil)
    }

    @Test("Paths round-trip through the data set's encoding")
    func pathRoundTrip() throws {
        let path = try #require(GlyphPath(encoded: "0568a975"))
        #expect(path.encoded == "0568a975")
        #expect(path.nodes.count == 8)
        #expect(GlyphPath(encoded: "") == nil)
        #expect(GlyphPath(encoded: "0z8") == nil)
    }

    @Test("Reversing a path preserves its edges but not its order")
    func reversal() throws {
        let path = try #require(GlyphPath(encoded: "038"))
        #expect(path.reversed.encoded == "830")
        #expect(path.reversed.undirectedEdges == path.undirectedEdges)
        #expect(path.reversed != path)
    }

    @Test("Edit distance counts node substitutions")
    func editDistance() throws {
        let a = try #require(GlyphPath(encoded: "038"))
        let b = try #require(GlyphPath(encoded: "039"))
        let c = try #require(GlyphPath(encoded: "0389"))
        #expect(a.editDistance(to: a) == 0)
        #expect(a.editDistance(to: b) == 1)
        #expect(a.editDistance(to: c) == 1)
    }
}
