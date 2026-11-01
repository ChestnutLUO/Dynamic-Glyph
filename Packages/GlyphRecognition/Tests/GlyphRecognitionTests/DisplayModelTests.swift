import Testing
@testable import GlyphRecognition

@Suite("Header phrases")
struct HeaderPhraseTests {
    private let matcher = HeaderPhraseMatcher()

    private func read(_ text: String, confidence: Double = 0.9) -> HeaderReading {
        matcher.read(lines: [(text, confidence)])
    }

    @Test("The four game headers are recognized as written on screen")
    func knownHeaders() {
        #expect(read("Command channel open…").phase == .command)
        #expect(read("Incoming glyph sequence").phase == .presenting)
        #expect(read("GO!").phase == .input)
        #expect(read("Glyph hack complete").phase == .completed)
        // Case and punctuation are normalized away, spacing is not significant.
        #expect(read("COMMAND  CHANNEL   OPEN...").phase == .command)
    }

    @Test("Unrelated screen text produces unknown rather than a guess")
    func unrelatedText() {
        // Harmless unrelated text, independent of the redacted map fixture.
        for text in ["DRONE FOOTAGE", "Garden Exhibit", "+448 AP", "RECALL", "16:84", ""] {
            #expect(read(text).phase == .unknown, Comment(rawValue: text))
        }
        // "GO" must match the whole header; a longer line containing it is not
        // the input screen.
        #expect(read("go to the portal").phase == .unknown)
        #expect(read("Incoming glyph").phase == .unknown)
    }

    @Test("Low confidence and contradictory lines are refused")
    func refusals() {
        #expect(read("Incoming glyph sequence", confidence: 0.2).phase == .unknown)
        let conflict = matcher.read(lines: [("Incoming glyph sequence", 0.9), ("GO!", 0.95)])
        #expect(conflict.phase == .unknown)
        #expect(conflict.matchedText == "conflicting phrases")
    }
}

@Suite("Sequence outlook")
struct SequenceOutlookTests {
    private func predictor() throws -> SequencePredictor {
        SequencePredictor(table: try ReferenceData.sequenceTable())
    }

    private func glyphs(_ names: String...) -> [GlyphID] { names.map(GlyphID.init) }

    @Test("The field run's two-Glyph prefix stays ambiguous until the slots are counted", .enabled(if: ReferenceData.sequencesAvailable))
    func fieldPrefixNeedsLength() throws {
        let predictor = try predictor()
        let observed = glyphs("change", "perspective")
        // The table holds this as a complete sequence and as the prefix of
        // three-, four- and five-Glyph sequences.
        let unknownLength = predictor.outlook(observed: observed)
        #expect(unknownLength.state == .ambiguous)
        #expect(unknownLength.candidateCount >= 4)
        #expect(unknownLength.observationMayBeComplete)
        #expect(unknownLength.predictedSuffix.isEmpty)

        // The presentation showed four indicators.
        let four = predictor.outlook(observed: observed, expectedLength: 4)
        #expect(four.state == .resolved)
        #expect(four.candidateCount == 1)
        #expect(four.predictedSuffix.map(\.name) == ["begin", "new"])
        #expect(!four.observationMayBeComplete)

        let five = predictor.outlook(observed: observed, expectedLength: 5)
        #expect(five.state == .resolved)
        #expect(five.predictedSuffix.map(\.name) == ["begin", "new", "resistance"])

        let two = predictor.outlook(observed: observed, expectedLength: 2)
        #expect(two.state == .resolved)
        #expect(two.predictedSuffix.isEmpty)
        #expect(two.observationMayBeComplete)
    }

    @Test("The recording's four observations do not settle the fifth slot by themselves", .enabled(if: ReferenceData.sequencesAvailable))
    func recordingPrefix() throws {
        let predictor = try predictor()
        let observed = glyphs("see", "truth", "see", "future")
        let unknownLength = predictor.outlook(observed: observed)
        #expect(unknownLength.state != .contradicted)
        // Five indicators were visible, and the presented sequence was
        // see, truth, see, future, begin.
        let five = predictor.outlook(observed: observed, expectedLength: 5)
        #expect(five.state == .resolved)
        #expect(five.predictedSuffix.map(\.name) == ["begin"])
    }

    @Test("Nothing observed is not the same as nothing possible", .enabled(if: ReferenceData.sequencesAvailable))
    func unobserved() throws {
        let predictor = try predictor()
        let distinctSequences = try ReferenceData.sequenceTable().count
        let empty = predictor.outlook(observed: [])
        #expect(empty.state == .unobserved)
        #expect(empty.candidateCount == distinctSequences)
        #expect(empty.predictedSuffix.isEmpty)
        // A length on its own still narrows the field.
        let twoSlots = predictor.outlook(observed: [], expectedLength: 2)
        #expect(twoSlots.state == .unobserved)
        #expect(twoSlots.candidateCount < empty.candidateCount)
        #expect(twoSlots.candidateCount > 0)
    }

    @Test("An impossible prefix is contradicted, and a wrong length is a length conflict", .enabled(if: ReferenceData.sequencesAvailable))
    func failureStatesAreDistinct() throws {
        let predictor = try predictor()
        let impossible = predictor.outlook(observed: glyphs("see", "see", "see", "see"))
        #expect(impossible.state == .contradicted)
        #expect(impossible.candidateCount == 0)
        #expect(impossible.observed.count == 4, "observations are kept for review")

        // Fewer slots than Glyphs already collected.
        let tooShort = predictor.outlook(observed: glyphs("change", "perspective"), expectedLength: 1)
        #expect(tooShort.state == .lengthConflict)
        #expect(tooShort.observed.count == 2, "the prefix is not truncated to fit")

        // A count the game never presents.
        #expect(predictor.outlook(observed: glyphs("change"), expectedLength: 6).state == .lengthConflict)

        // A valid length that excludes every sequence consistent with the prefix.
        let excluded = predictor.outlook(observed: glyphs("change", "perspective", "technology"),
                                         expectedLength: 5)
        #expect(excluded.state == .lengthConflict)
    }

    @Test("Alternatives are reported per position, not flattened into one guess", .enabled(if: ReferenceData.sequencesAvailable))
    func alternativesPerPosition() throws {
        let predictor = try predictor()
        let outlook = predictor.outlook(observed: glyphs("change", "perspective"), expectedLength: 3)
        #expect(outlook.state == .resolved || outlook.state == .ambiguous)
        #expect(outlook.suffixAlternatives.count == 1)
        #expect(outlook.suffixAlternatives[0].contains(GlyphID("technology")))
    }

    @Test("Unknown length preserves the original predictor exactly", .enabled(if: ReferenceData.sequencesAvailable))
    func lengthUnknownMatchesPredict() throws {
        let predictor = try predictor()
        for observed in [glyphs(), glyphs("change"), glyphs("change", "perspective"),
                         glyphs("see", "truth"), glyphs("see", "see", "see")] {
            let base = predictor.predict(observed: observed)
            let outlook = predictor.outlook(observed: observed)
            #expect(outlook.candidateCount == base.candidates.count)
            #expect(outlook.observationMayBeComplete == base.observationMayBeComplete)
            #expect((outlook.state == .resolved) == (base.isResolved && !observed.isEmpty))
            #expect((outlook.state == .contradicted) == base.isContradicted)
        }
    }
}

@Suite("Diagram geometry")
struct GlyphDiagramLayoutTests {
    private let layout = GlyphDiagramLayout()

    /// Expectations stated from the node coordinates in `NodeArray.canonical`,
    /// not from anything the renderer or the recognizer produces. A mirrored or
    /// vertically flipped layout fails these.
    @Test("An asymmetric Glyph keeps its side and its direction", .enabled(if: ReferenceData.shapesAvailable))
    func orientation() throws {
        let table = try ReferenceData.glyphTable()
        // future = 2479: nodes 2 and 9 are the right-hand outer pair, 4 and 7
        // the right-hand inner pair. Every point is on the right, and the walk
        // runs downwards.
        let future = try #require(table.path(for: GlyphID("future")))
        let points = layout.segments(for: future)
        #expect(points.count == 3)
        #expect(points.allSatisfy { $0.from.x > 0.5 && $0.to.x > 0.5 })
        #expect(points.first!.from.y < points.last!.to.y)

        // begin = 06a7: starts at the apex, reaches the base, ends on the
        // lower right. The apex is the topmost point of the whole tile.
        let begin = try #require(table.path(for: GlyphID("begin")))
        let beginPoints = layout.segments(for: begin)
        let apex = beginPoints.first!.from
        #expect(apex.y == layout.nodePositions().map(\.y).min())
        #expect(abs(apex.x - 0.5) < 1e-9)
        #expect(beginPoints[1].to.y == layout.nodePositions().map(\.y).max())
    }

    @Test("Every reference Glyph produces a drawable, inset diagram", .enabled(if: ReferenceData.shapesAvailable))
    func everyGlyphDraws() throws {
        let table = try ReferenceData.glyphTable()
        for id in table.glyphs {
            let path = try #require(table.path(for: id))
            let segments = layout.segments(for: path)
            #expect(segments.count == path.nodes.count - 1, "\(id)")
            for segment in segments {
                for point in [segment.from, segment.to] {
                    #expect(point.x >= layout.inset - 1e-9 && point.x <= 1 - layout.inset + 1e-9, "\(id)")
                    #expect(point.y >= layout.inset - 1e-9 && point.y <= 1 - layout.inset + 1e-9, "\(id)")
                }
            }
            // A walk that revisits a node marks it once.
            #expect(layout.visitedNodes(of: path).count == Set(path.nodes).count, "\(id)")
        }
    }

    /// Stated from `NodeArray.canonical`'s own comments: apex 0, upper right
    /// 2, lower right 9, base a, lower left 8, upper left 1.
    @Test("The frame is the outer hexagon, clockwise from the apex")
    func outline() {
        let positions = layout.nodePositions()
        let expected = [0, 2, 9, 10, 8, 1].map { positions[$0] }
        #expect(layout.outline() == expected)
    }

    @Test("A tile is centred in whatever rectangle it is given")
    func framing() {
        let wide = layout.frame(in: SIMD2(0, 0), size: SIMD2(200, 100))
        #expect(wide.side == 100)
        #expect(wide.origin.x == 50 && wide.origin.y == 0)
        let tall = layout.frame(in: SIMD2(10, 20), size: SIMD2(80, 160))
        #expect(tall.side == 80)
        #expect(tall.origin.x == 10 && tall.origin.y == 60)
    }
}

@Suite("Status tone")
struct StatusToneTests {
    @Test("Each display status has the tone both the window edge and the Island keyline use")
    func toneTable() {
        let expected: [DisplayStatus: StatusTone] = [
            .stopped: .warning, .stale: .warning, .obstructed: .warning, .conflicted: .warning,
            .inferred: .tentative, .provisional: .tentative,
            .waiting: .idle, .unknownPhase: .idle,
            .collecting: .collecting, .yourTurn: .drawing, .complete: .done
        ]
        for status in [DisplayStatus.stopped, .stale, .obstructed, .inferred, .provisional, .conflicted,
                       .waiting, .collecting, .yourTurn, .complete, .unknownPhase] {
            #expect(status.tone == expected[status], "\(status)")
        }
        #expect(Set(expected.values) == Set(StatusTone.allCases))
    }

    @Test("A warning tone is only ever shown for a status the player should not trust")
    func warningMeansUntrustworthy() {
        for status in [DisplayStatus.stopped, .stale, .obstructed, .inferred, .provisional, .conflicted,
                       .waiting, .collecting, .yourTurn, .complete, .unknownPhase] where status.tone == .warning {
            #expect(!status.isTrustworthy, "\(status)")
        }
    }
}
