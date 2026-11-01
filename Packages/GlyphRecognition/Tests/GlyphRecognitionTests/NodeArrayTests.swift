import Testing
@testable import GlyphRecognition

/// The node positions are measured from a real capture. The *labelling* — which
/// physical node the data set calls `0` — is inferred, and these tests are the
/// evidence for that inference.
///
/// An earlier version of this suite claimed to be a tripwire and was not:
/// swapping inner nodes 3 and 4 passed every test in it, because nothing
/// exercised the inner nodes at all. The collinearity check below is what
/// actually constrains them.
@Suite("Node array and labelling")
struct NodeArrayTests {
    private let array = NodeArray.canonical

    @Test("The lattice is exact")
    func lattice() {
        #expect(array.positions.count == 11)
        #expect(Set(array.positions.map(\.x)) == [0, 0.25, 0.5, 0.75, 1])
        #expect(Set(array.positions.map(\.y)) == [0, 0.25, 0.375, 0.5, 0.625, 0.75, 1])
    }

    @Test("Six nodes lie on the boundary and five inside")
    func hexagonIsDerivedFromGeometry() {
        #expect(array.outerHexagon.count == 6)
        #expect(array.interior.count == 5)
        #expect(array.outerHexagon.map(\.rawValue).sorted() == [0, 1, 2, 8, 9, 10])
        #expect(array.interior.map(\.rawValue).sorted() == [3, 4, 5, 6, 7])
    }

    /// `clear` = `05a` pins the three axis nodes: under a correct labelling it
    /// is a single vertical stroke down the axis of symmetry.
    @Test("clear traces the vertical axis", .enabled(if: ReferenceData.shapesAvailable))
    func clearIsVertical() throws {
        let table = try ReferenceData.glyphTable()
        let path = try #require(table.path(for: GlyphID("clear")))
        #expect(path.encoded == "05a")
        for node in path.nodes {
            #expect(array.position(of: node).x == 0.5, "node \(node) is off the axis")
        }
    }

    /// `all` = `018a920` pins the six boundary labels as a set: it uses every
    /// boundary node, no interior one, and closes.
    @Test("all traces the closed outer hexagon", .enabled(if: ReferenceData.shapesAvailable))
    func allIsTheHexagon() throws {
        let table = try ReferenceData.glyphTable()
        let path = try #require(table.path(for: GlyphID("all")))
        #expect(path.encoded == "018a920")
        #expect(Set(path.nodes) == array.outerHexagon)
        #expect(Set(path.nodes).isDisjoint(with: array.interior))
        #expect(path.nodes.first == path.nodes.last)
    }

    /// **The test that constrains the interior.**
    ///
    /// A drawn segment should not pass through a node the Glyph does not claim
    /// to visit. Under the canonical labelling exactly one Glyph does — and it
    /// is `imperfect`, which the wiki documents as the one Glyph requiring
    /// deliberate backtracking, so its degeneracy is expected rather than
    /// evidence against the mapping.
    ///
    /// Swapping a single pair of interior labels raises this count by two
    /// orders of magnitude: 3↔4 gives 103, 6↔7 gives 105. That is what makes
    /// this a real tripwire where the earlier tests were not.
    @Test("Only imperfect crosses a node it does not visit", .enabled(if: ReferenceData.shapesAvailable))
    func interiorLabellingIsConstrained() throws {
        let table = try ReferenceData.glyphTable()
        var offenders: [GlyphID] = []
        var crossings = 0
        for id in table.glyphs {
            guard let path = table.path(for: id) else { continue }
            let crossed = array.unvisitedNodesCrossed(by: path)
            if !crossed.isEmpty {
                offenders.append(id)
                crossings += crossed.count
            }
        }
        #expect(offenders == [GlyphID("imperfect")], "unexpected offenders: \(offenders)")
        #expect(crossings == 1)
    }

    /// States the limit of the evidence in a form that fails if someone
    /// "fixes" it without adding a labelled capture.
    ///
    /// A whole-array left-right reflection — swapping 1/2, 3/4, 6/7 and 8/9 at
    /// once — produces exactly the same collinearity count, because the
    /// vocabulary is closed under reflection. The data alone cannot rule it
    /// out; only an independently labelled capture can.
    @Test("A full reflection is NOT ruled out by the data", .enabled(if: ReferenceData.shapesAvailable))
    func reflectionRemainsUnresolved() throws {
        let table = try ReferenceData.glyphTable()
        let reflected = NodeArray(positions: array.positions.map { SIMD2(1 - $0.x, $0.y) })
        var crossings = 0
        for id in table.glyphs {
            guard let path = table.path(for: id) else { continue }
            crossings += reflected.unvisitedNodesCrossed(by: path).count
        }
        #expect(crossings == 1, """
            A reflected layout is geometrically indistinguishable from the \
            canonical one. If this ever stops being true, the reflection \
            ambiguity has been resolved and NodeArray's documentation should \
            be updated to say so.
            """)
    }

    @Test("No Glyph contains a zero-length segment", .enabled(if: ReferenceData.shapesAvailable))
    func noDegenerateSegments() throws {
        let table = try ReferenceData.glyphTable()
        for id in table.glyphs {
            guard let path = table.path(for: id) else { continue }
            for (a, b) in zip(path.nodes, path.nodes.dropFirst()) {
                #expect(array.position(of: a) != array.position(of: b), "\(id) repeats node \(a)")
            }
        }
    }

    @Test("Snapping returns nil rather than a far-away guess")
    func snapping() throws {
        let centre = array.position(of: try #require(NodeIndex(rawValue: 5)))
        #expect(array.nearest(to: centre, within: 0.05)?.node.rawValue == 5)
        #expect(array.nearest(to: SIMD2(0.5, 0.44), within: 0.01) == nil)
    }

    @Test("Fitting maps the lattice onto a pixel bounding box")
    func fitting() {
        // The measured array in the source capture, frame-02389.
        let fitted = array.fitted(to: (origin: SIMD2(74.8, 454.7), size: SIMD2(451.7, 542.3)))
        #expect(abs(fitted[0].x - 300.65) < 0.5)
        #expect(abs(fitted[0].y - 454.7) < 0.5)
        #expect(abs(fitted[10].y - 997.0) < 0.5)
    }
}
