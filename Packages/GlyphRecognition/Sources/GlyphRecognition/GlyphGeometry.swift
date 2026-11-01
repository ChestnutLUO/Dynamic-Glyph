/// Splits a rendered segment at every intervening lattice node. A long edge
/// and adjacent collinear edges produce identical pixels (notably imperfect).
public enum GlyphGeometry {
    public static func normalizedEdges(_ edges: Set<GlyphPath.Edge>) -> Set<GlyphPath.Edge> {
        let array = NodeArray.canonical
        var result: Set<GlyphPath.Edge> = []
        for edge in edges where edge.lower != edge.upper {
            let a = array.position(of: edge.lower), b = array.position(of: edge.upper)
            let delta = b - a
            let nodes = NodeIndex.all.filter {
                $0 == edge.lower || $0 == edge.upper || array.segment(edge.lower, edge.upper, passesThrough: $0)
            }.sorted {
                ((array.position(of: $0) - a) * delta).sum() <
                ((array.position(of: $1) - a) * delta).sum()
            }
            for (from, to) in zip(nodes, nodes.dropFirst()) { result.insert(.init(from, to)) }
        }
        return result
    }

    public static let elementaryEdges: [GlyphPath.Edge] = {
        var edges: [GlyphPath.Edge] = []
        for a in NodeIndex.all {
            for b in NodeIndex.all where a < b {
                if !NodeIndex.all.contains(where: { NodeArray.canonical.segment(a, b, passesThrough: $0) }) {
                    edges.append(.init(a, b))
                }
            }
        }
        return edges
    }()
}
