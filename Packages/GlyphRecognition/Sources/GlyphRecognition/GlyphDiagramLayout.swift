/// The one place that turns a Glyph into drawable geometry.
///
/// Core Graphics and SwiftUI disagree about which way y points, and a Glyph
/// vocabulary that is closed under reflection will not tell you when you have
/// got it wrong: a vertically flipped `future` is a perfectly plausible
/// picture of some other Glyph. So the convention is fixed here, once, and
/// asserted by tests against independently stated geometry.
///
/// **Convention: x increases right, y increases DOWN**, matching
/// `NodeArray.canonical` and image coordinates. A renderer drawing into a
/// bottom-left-origin context must apply the flip itself.
public struct GlyphDiagramLayout: Sendable {
    /// Fraction of the tile's smaller side kept clear around the diagram, so
    /// node markers and stroke caps are not clipped.
    public let inset: Double

    public init(inset: Double = 0.12) {
        precondition(inset >= 0 && inset < 0.5)
        self.inset = inset
    }

    /// Node positions inside a unit tile, in the order of `NodeIndex.all`.
    public func nodePositions() -> [SIMD2<Double>] {
        let scale = 1 - 2 * inset
        return NodeArray.canonical.positions.map { SIMD2(inset, inset) + $0 * SIMD2(scale, scale) }
    }

    /// The stroke to draw, as ordered point pairs in the unit tile.
    ///
    /// Drawn from the walk, not from the undirected edge set: a polyline
    /// through the nodes in order reproduces the game's own drawing, including
    /// `imperfect`, the one Glyph that revisits part of its path.
    public func segments(for path: GlyphPath) -> [(from: SIMD2<Double>, to: SIMD2<Double>)] {
        let positions = nodePositions()
        return zip(path.nodes, path.nodes.dropFirst()).map {
            (positions[$0.rawValue], positions[$1.rawValue])
        }
    }

    /// The nodes the stroke visits, for emphasis.
    ///
    /// Drawn as small filled markers rather than the game's bright hollow
    /// rings: rings are exactly the cue `NodeArrayDetector` looks for, and the
    /// app must not be able to calibrate onto a picture of its own display.
    public func visitedNodes(of path: GlyphPath) -> [SIMD2<Double>] {
        let positions = nodePositions()
        var seen: Set<Int> = []
        return path.nodes.compactMap { seen.insert($0.rawValue).inserted ? positions[$0.rawValue] : nil }
    }

    /// The outer hexagon as a closed loop, clockwise from the apex.
    ///
    /// Many Glyphs share a shape and differ only in its size or where it sits
    /// in the array, so a stroke drawn with nothing around it is ambiguous.
    /// Built from `outerHexagon` rather than listed by hand: the apex, the
    /// right-hand vertices top to bottom, then the rest bottom to top.
    public func outline() -> [SIMD2<Double>] {
        let positions = nodePositions()
        let vertices = NodeArray.canonical.outerHexagon.map { positions[$0.rawValue] }
        // The inset is symmetric, so the tile's centre line is the array's.
        let right = vertices.filter { $0.x > 0.5 }.sorted { $0.y < $1.y }
        let rest = vertices.filter { $0.x <= 0.5 }
        let apex = rest.min { $0.y < $1.y }
        let others = rest.filter { $0 != apex }.sorted { $0.y > $1.y }
        return (apex.map { [$0] } ?? []) + right + others
    }

    /// Places a unit tile inside a pixel rectangle, preserving aspect ratio.
    public func frame(in origin: SIMD2<Double>, size: SIMD2<Double>) -> (origin: SIMD2<Double>, side: Double) {
        let side = min(size.x, size.y)
        return (origin + (size - SIMD2(side, side)) / 2, side)
    }
}
