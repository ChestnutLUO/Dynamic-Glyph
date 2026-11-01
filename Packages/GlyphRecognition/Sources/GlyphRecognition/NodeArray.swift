/// The eleven-node Glyph array, in normalised coordinates.
///
/// Measured, not remembered. The positions were derived from a real capture
/// (`Apps/DynamicGlyph/Results/.../frame-02389.jpg`, a 603×1311 frame of
/// the "Incoming glyph sequence" screen) by thresholding and taking the
/// centroid of each node ring, then normalising within the array's bounding
/// box. The lattice came out exact:
///
///     x ∈ { 0, ¼, ½, ¾, 1 }        y ∈ { 0, ¼, ⅜, ½, ⅝, ¾, 1 }
///
/// Origin is the top-left of the array's bounding box, y increasing downward,
/// matching image coordinates. Real frames are fitted onto this space rather
/// than the other way round, so the layout is resolution independent.
public struct NodeArray: Sendable {
    /// Node `i` is at `positions[i]`, indexed by `NodeIndex.rawValue`.
    public let positions: [SIMD2<Double>]

    public init(positions: [SIMD2<Double>]) {
        precondition(positions.count == NodeIndex.count,
                     "The array has exactly \(NodeIndex.count) nodes")
        self.positions = positions
    }

    /// The layout the game draws.
    ///
    /// Label assignment — which physical node is `0`, which is `a` — is reading
    /// order: top to bottom, then left to right. That is inferred, not
    /// documented. What the evidence does and does not establish:
    ///
    /// - **Established.** No single pair of labels can be swapped without
    ///   producing geometric nonsense. Under this assignment exactly one Glyph
    ///   (`imperfect`, the documented backtracking exception) draws a segment
    ///   that passes through a node it does not visit; swapping the inner pair
    ///   3/4 raises that to 103 and swapping 6/7 to 105. `NodeArrayTests`
    ///   asserts it, so any single-pair error fails loudly.
    /// - **Not established.** A *whole-array* left-right reflection —
    ///   simultaneously swapping 1/2, 3/4, 6/7 and 8/9 — is geometrically
    ///   indistinguishable, because the vocabulary is closed under reflection.
    ///   Only an independently labelled capture can rule it out, and we do not
    ///   have one yet. If the mapping is reflected, every recognised Glyph will
    ///   be its mirror partner.
    ///
    /// The axis nodes 0, 5 and `a` are pinned independently by `clear` = `05a`.
    public static let canonical = NodeArray(positions: [
        SIMD2(0.50, 0.000),   // 0  apex
        SIMD2(0.00, 0.250),   // 1  upper left, outer
        SIMD2(1.00, 0.250),   // 2  upper right, outer
        SIMD2(0.25, 0.375),   // 3  upper left, inner
        SIMD2(0.75, 0.375),   // 4  upper right, inner
        SIMD2(0.50, 0.500),   // 5  centre
        SIMD2(0.25, 0.625),   // 6  lower left, inner
        SIMD2(0.75, 0.625),   // 7  lower right, inner
        SIMD2(0.00, 0.750),   // 8  lower left, outer
        SIMD2(1.00, 0.750),   // 9  lower right, outer
        SIMD2(0.50, 1.000)    // a  base
    ])

    public func position(of node: NodeIndex) -> SIMD2<Double> {
        positions[node.rawValue]
    }

    /// The six vertices of the outer hexagon: the nodes on the bounding box
    /// edge, genuinely derived from the positions rather than listed by hand,
    /// so a test using them is evidence about the layout rather than a
    /// restatement of it.
    public var outerHexagon: Set<NodeIndex> {
        Set(positions.enumerated().compactMap { index, p in
            (p.x == 0 || p.x == 1 || p.y == 0 || p.y == 1) ? NodeIndex(rawValue: index) : nil
        })
    }

    /// Nodes strictly inside the hexagon.
    public var interior: Set<NodeIndex> {
        Set(NodeIndex.all).subtracting(outerHexagon)
    }

    /// Whether the segment `a`–`b` passes through some other node.
    ///
    /// A drawn stroke should not silently traverse a node it does not claim to
    /// visit; where that happens in bulk, the labelling is wrong. This is the
    /// only independent geometric check available on the inner nodes.
    public func segment(_ a: NodeIndex, _ b: NodeIndex, passesThrough c: NodeIndex) -> Bool {
        guard c != a, c != b else { return false }
        let p = position(of: a), q = position(of: b), r = position(of: c)
        let cross = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        guard abs(cross) < 1e-9 else { return false }
        let dot = (r.x - p.x) * (q.x - p.x) + (r.y - p.y) * (q.y - p.y)
        let lengthSquared = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
        return dot > 1e-9 && dot < lengthSquared - 1e-9
    }

    /// Nodes a path crosses without listing.
    public func unvisitedNodesCrossed(by path: GlyphPath) -> [(NodeIndex, NodeIndex, NodeIndex)] {
        var found: [(NodeIndex, NodeIndex, NodeIndex)] = []
        for (a, b) in zip(path.nodes, path.nodes.dropFirst()) {
            for c in NodeIndex.all where segment(a, b, passesThrough: c) {
                found.append((a, b, c))
            }
        }
        return found
    }

    /// The node closest to a normalised point, if one lies within `radius`.
    ///
    /// Returns `nil` rather than a far-away best guess — an unsnappable point
    /// means the stroke left the lattice, which is information.
    public func nearest(to point: SIMD2<Double>, within radius: Double) -> (node: NodeIndex, distance: Double)? {
        var best: (node: NodeIndex, distance: Double)?
        for (index, position) in positions.enumerated() {
            let delta = position - point
            let distance = (delta * delta).sum().squareRoot()
            if distance <= radius, best == nil || distance < best!.distance {
                best = (NodeIndex(rawValue: index)!, distance)
            }
        }
        return best
    }

    /// Fits this layout onto a detected array bounding box in pixel space.
    ///
    /// Deliberately an axis-aligned fit: the array is drawn upright and the
    /// capture is not rotated, so a full affine solve would add failure modes
    /// without buying anything. Revisit if landscape capture is ever supported.
    public func fitted(to boundingBox: (origin: SIMD2<Double>, size: SIMD2<Double>)) -> [SIMD2<Double>] {
        positions.map { boundingBox.origin + ($0 * boundingBox.size) }
    }
}
