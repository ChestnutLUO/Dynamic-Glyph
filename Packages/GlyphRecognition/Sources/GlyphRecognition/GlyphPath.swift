/// The ordered walk of nodes that draws a single Glyph.
///
/// Order is how the data set writes a Glyph, but it is **not** what identifies
/// one. No two Glyphs in the vocabulary share an undirected edge set, so the
/// set of connected node pairs is a complete key on its own — see
/// `undirectedEdges` and `GlyphTable.glyph(matchingEdges:)`. Recognition should
/// use that key, because stroke direction is the part of an extracted stroke
/// that is hardest to recover reliably.
///
/// The wiki describes "mirror image" antonym pairs such as ATTACK/DEFEND. Those
/// are spatial reflections onto *different* nodes, not the same walk traced
/// backwards, so they do not collide under either key.
public struct GlyphPath: Hashable, Sendable, CustomStringConvertible {
    public let nodes: [NodeIndex]

    public init(nodes: [NodeIndex]) {
        self.nodes = nodes
    }

    /// Parses the data set's encoding, e.g. `"038"` or `"0568a975"`.
    public init?(encoded: String) {
        var parsed: [NodeIndex] = []
        parsed.reserveCapacity(encoded.count)
        for character in encoded {
            guard let node = NodeIndex(character: character) else { return nil }
            parsed.append(node)
        }
        guard !parsed.isEmpty else { return nil }
        self.nodes = parsed
    }

    public var encoded: String { String(nodes.map(\.character)) }

    public var description: String { encoded }

    /// The same walk traced backwards.
    ///
    /// No Glyph is another Glyph's reversal, so this never names a different
    /// Glyph -- it is the same Glyph drawn the other way, which is exactly the
    /// case ordered lookup gets wrong and edge-set lookup gets right.
    public var reversed: GlyphPath { GlyphPath(nodes: nodes.reversed()) }

    /// The set of node pairs the stroke connects, ignoring direction.
    ///
    /// This is the identifying key for a Glyph. It is unique across the whole
    /// vocabulary, so recognition never has to recover which way the stroke was
    /// drawn -- see `DirectionIndependenceTests`.
    public var undirectedEdges: Set<Edge> {
        var edges: Set<Edge> = []
        for (from, to) in zip(nodes, nodes.dropFirst()) {
            edges.insert(Edge(from, to))
        }
        return edges
    }

    public struct Edge: Hashable, Sendable {
        public let lower: NodeIndex
        public let upper: NodeIndex
        public init(_ a: NodeIndex, _ b: NodeIndex) {
            (lower, upper) = a <= b ? (a, b) : (b, a)
        }
    }
}
