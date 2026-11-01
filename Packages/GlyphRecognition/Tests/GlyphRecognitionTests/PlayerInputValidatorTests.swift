import Testing
@testable import GlyphRecognition

private struct InputFeed {
    static let synthetic = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!,
                                                GlyphID("beta"): GlyphPath(encoded: "456")!])
    let session = CaptureSessionID(rawValue: 1)
    let table: GlyphTable
    var validator: PlayerInputValidator
    var slots: [SlotObservation]
    var state: TrackingState = .input
    var hackID = 1
    var observedPresentation = true
    var slotCountConflict = false
    var indicatorsObstructed = false
    var time = 10.0
    var events: [InputCheckEvent] = []

    init(table: GlyphTable = Self.synthetic, names: [String] = ["alpha", "beta", "alpha"]) {
        self.table = table
        validator = PlayerInputValidator(table: table, sessionID: CaptureSessionID(rawValue: 1))
        slots = names.enumerated().map { SlotObservation(index: $0.offset, status: .confirmed,
                                                        glyph: GlyphID($0.element)) }
    }

    func edges(_ name: String) -> Set<GlyphPath.Edge> {
        GlyphFrameRecognizer(table: table).expectedEdges(for: GlyphID(name))!
    }

    mutating func step(_ index: Int?, _ edges: Set<GlyphPath.Edge>? = nil, gap: Double = 0.05,
                       kind: ShapeEvidence.Kind = .unexplainedInk, calibrated: Bool = true,
                       sessionID: CaptureSessionID? = nil, partial: [GlyphPath.Edge: Double] = [:]) {
        time += gap
        let evidence = FrameEvidence(sessionID: sessionID ?? session, time: time, header: nil,
            slots: index.map { SlotStripReading(slotCount: slots.count, highlightedIndex: $0,
                                               markerCentersX: [], hasInputTimerBar: true) },
            shape: ShapeEvidence(kind: edges == nil ? .noStroke : kind, glyph: nil,
                                 edges: edges ?? [], extensions: []),
            hasValidCalibration: calibrated)
        events += validator.accept(evidence,
            context: .init(state: state, hackID: hackID, slots: slots, expectedSlotCount: slots.count,
                           observedPresentation: observedPresentation, slotCountConflict: slotCountConflict,
                           indicatorsObstructed: indicatorsObstructed),
            edgeEvidence: (edges ?? []).map { GlyphEdgeEvidence(edge: $0, samples: [1, 1, 1]) }
                + partial.map { edge, coverage in
                    // Coverage is the share of samples lit; 100 of them give it to the percent.
                    let lit = Int((coverage * 100).rounded())
                    return GlyphEdgeEvidence(edge: edge, samples: Array(repeating: 1, count: lit)
                                             + Array(repeating: 0, count: 100 - lit))
                })
    }

    mutating func draw(_ index: Int, _ edges: Set<GlyphPath.Edge>, postLift: [Set<GlyphPath.Edge>]? = nil) {
        step(index)
        step(index, edges)
        for frame in postLift ?? Array(repeating: edges, count: 3) { step(index + 1, frame) }
        step(index + 1)
    }
}

@Suite("Player input validation")
struct PlayerInputValidatorTests {
    @Test("A single clear starts input; post-lift frames belong to the previous slot")
    func consecutiveAttempts() {
        var feed = InputFeed()
        feed.draw(0, feed.edges("alpha"))
        #expect(feed.validator.results.map(\.verdict) == [.matched])
        #expect(feed.validator.results.first?.slotIndex == 0)
        let revision = feed.validator.revision
        // The final clear from slot zero is the sole start sample for slot one.
        feed.step(1, feed.edges("beta"))
        for _ in 0..<3 { feed.step(2, feed.edges("beta")) }
        feed.step(2)
        #expect(feed.validator.results.map(\.slotIndex) == [0, 1])
        #expect(feed.validator.results.map(\.verdict) == [.matched, .matched])
        #expect(feed.validator.revision > revision)
        feed.step(2, feed.edges("alpha"))
        feed.state = .completed
        feed.step(nil, feed.edges("beta"))
        #expect(feed.validator.results.count == 2, "the final/result screen is never checked")
    }

    @Test("Only stable post-lift runs vote; a mismatch needs a longer run than a match")
    func agreement() {
        let right = InputFeed().edges("alpha"), wrong = InputFeed().edges("beta")
        let cases: [([Set<GlyphPath.Edge>], InputCheckVerdict, InputCheckUnavailableReason?)] = [
            ([right, right, right], .matched, nil),
            ([wrong, wrong, right, right, right], .matched, nil),
            ([wrong, wrong, wrong, wrong, wrong], .differs, nil),
            ([wrong, wrong, wrong], .unavailable, .shortWindow),
            ([right, right], .unavailable, .shortWindow),
            ([right], .unavailable, .shortWindow),
            ([right, wrong, right, wrong], .unavailable, .shortWindow),
            ([right, right, right, wrong, wrong, wrong], .unavailable, .disagreeingSamples),
            ([wrong, wrong, wrong, right, right, right], .unavailable, .disagreeingSamples),
            ([[], [], [], [], [], []], .unavailable, .shortWindow)
        ]
        for (samples, verdict, reason) in cases {
            var feed = InputFeed()
            feed.draw(0, right, postLift: samples)
            let result = feed.validator.results.first
            #expect(result?.verdict == verdict, "\(samples.map(\.count))")
            #expect(result?.reason == reason, "\(samples.map(\.count))")
            #expect(result?.windowEnd == .clearArray)
        }
    }

    @Test("A match is shown while the drawing is still up; closing keeps its time")
    func earlyMatch() {
        var feed = InputFeed()
        let right = feed.edges("alpha"), wrong = feed.edges("beta")
        feed.step(0)
        feed.step(0, right)
        feed.step(1, right)
        feed.step(1, right)
        #expect(feed.validator.results.isEmpty, "two samples are not yet a stable run")
        feed.step(1, right)
        let shown = feed.validator.results.first
        #expect(shown?.verdict == .matched)
        #expect(shown?.windowEnd == .open)
        for _ in 0..<5 { feed.step(1, right) }
        feed.step(1)
        #expect(feed.validator.results.first?.windowEnd == .clearArray)
        #expect(feed.validator.results.first?.sourceTime == shown?.sourceTime)

        // A wrong reading is never shown before the window closes.
        var wrongFeed = InputFeed()
        wrongFeed.step(0)
        wrongFeed.step(0, right)
        for _ in 0..<8 { wrongFeed.step(1, wrong) }
        #expect(wrongFeed.validator.results.isEmpty)
        wrongFeed.step(1)
        #expect(wrongFeed.validator.results.first?.verdict == .differs)
    }

    @Test("A later stable reading withdraws a match that was already shown")
    func withdrawnMatch() {
        var feed = InputFeed()
        let right = feed.edges("alpha"), wrong = feed.edges("beta")
        feed.step(0)
        feed.step(0, right)
        for _ in 0..<3 { feed.step(1, right) }
        #expect(feed.validator.results.first?.verdict == .matched)
        for _ in 0..<3 { feed.step(1, wrong) }
        #expect(feed.validator.results.first?.verdict == .unavailable)
        #expect(feed.validator.results.first?.reason == .disagreeingSamples)
        feed.step(1)
        #expect(feed.validator.results.first?.reason == .disagreeingSamples)
    }

    @Test("Three samples must span 100 ms; duplicate timestamps do not count")
    func span() {
        var feed = InputFeed()
        let edges = feed.edges("alpha")
        feed.step(0)
        feed.step(0, edges)
        for _ in 0..<3 { feed.step(1, edges, gap: 0.025) }
        feed.step(1)
        #expect(feed.validator.results.first?.reason == .shortWindow)
        var duplicates = InputFeed()
        duplicates.step(0)
        duplicates.step(0, edges)
        duplicates.step(1, edges)
        for _ in 0..<4 { duplicates.step(1, edges, gap: 0) }
        duplicates.step(1)
        #expect(duplicates.validator.results.first?.reason == .shortWindow)
    }

    @Test("Unexplained ink and unrecognized strokes can match; drawing transients cannot warn")
    func classificationIndependent() {
        for kind: ShapeEvidence.Kind in [.unexplainedInk, .unrecognizedStroke, .ambiguousShape, .uniqueVisibleShape] {
            var feed = InputFeed()
            let right = feed.edges("alpha"), wrong = feed.edges("beta")
            feed.step(0)
            for _ in 0..<13 { feed.step(0, wrong, kind: kind) }
            #expect(feed.validator.results.isEmpty)
            for _ in 0..<3 { feed.step(1, right, kind: kind) }
            #expect(feed.validator.results.first?.verdict == .matched)
            feed.step(1)
            #expect(feed.validator.results.first?.verdict == .matched)
        }
    }

    @Test("No observed clear means no definitive comparison")
    func missedStart() {
        var feed = InputFeed()
        let edges = feed.edges("alpha")
        feed.step(0, edges)
        for _ in 0..<3 { feed.step(1, edges) }
        feed.step(1)
        #expect(feed.validator.results.first?.reason == .missedStart)
    }

    @Test("Missing a clear between two attempts never combines their drawings")
    func missedClear() {
        var feed = InputFeed()
        feed.step(0)
        feed.step(0, feed.edges("alpha"))
        for _ in 0..<3 { feed.step(1, feed.edges("alpha")) }
        for _ in 0..<3 { feed.step(1, feed.edges("beta")) }
        for _ in 0..<3 { feed.step(2, feed.edges("beta")) }
        feed.step(2)
        #expect(feed.validator.results.map(\.verdict) == [.unavailable, .unavailable])
        #expect(feed.validator.results.map(\.reason) == [.disagreeingSamples, .missedStart])
        #expect(feed.validator.results.map(\.slotIndex) == [0, 1])
    }

    @Test("New ink that reaches no lattice edge ends the window when no clear sample is caught")
    func inkOnlyBoundary() {
        // The Redo capture: `path` gave way to `destiny`'s first ink within
        // one sample, and the growing new stroke withdrew path's match.
        var feed = InputFeed()
        let alpha = feed.edges("alpha"), beta = feed.edges("beta")
        feed.step(0)
        feed.step(0, alpha)
        for _ in 0..<5 { feed.step(1, alpha) }
        feed.step(1, [])
        for _ in 0..<4 { feed.step(1, beta) }
        #expect(feed.validator.results.map(\.verdict) == [.matched])
        #expect(feed.validator.results.first?.windowEnd == .clearArray)
        for _ in 0..<3 { feed.step(2, beta) }
        feed.step(2)
        #expect(feed.validator.results.map(\.verdict) == [.matched, .matched])
        #expect(feed.validator.results.last?.startTime != nil, "the ink-only sample is an observed start")
    }

    @Test("An advance before any clear closes the window as unclosed, not as a missed start")
    func unclosedWindow() {
        var feed = InputFeed()
        feed.step(0)
        feed.step(0, feed.edges("alpha"))
        for _ in 0..<2 { feed.step(1, feed.edges("alpha")) }
        feed.step(2, feed.edges("beta"))
        feed.step(2, feed.edges("beta"))
        #expect(feed.validator.results.first?.slotIndex == 0)
        #expect(feed.validator.results.first?.reason == .unclosedWindow)
    }

    @Test("Strip loss, gaps, invalid geometry and phase changes terminate open windows")
    func interruptions() {
        for reason: InputCheckUnavailableReason in [.frameGap, .stripLoss, .invalidCalibration, .phaseChange] {
            var feed = InputFeed()
            let edges = feed.edges("alpha")
            feed.step(0)
            feed.step(0, edges)
            for _ in 0..<2 { feed.step(1, edges) }
            switch reason {
            case .frameGap: feed.step(1, edges, gap: 0.2)
            case .stripLoss: feed.step(nil, edges)
            case .invalidCalibration: feed.step(1, edges, calibrated: false)
            default: feed.state = .completed; feed.step(1, edges)
            }
            #expect(feed.validator.results.first?.reason == reason)
            #expect(feed.validator.results.first?.verdict == .unavailable)

            // A match already reached from a stable run is not undone by
            // losing the frames that follow it.
            var matched = InputFeed()
            matched.step(0)
            matched.step(0, edges)
            for _ in 0..<3 { matched.step(1, edges) }
            switch reason {
            case .frameGap: matched.step(1, edges, gap: 0.2)
            case .stripLoss: matched.step(nil, edges)
            case .invalidCalibration: matched.step(1, edges, calibrated: false)
            default: matched.state = .completed; matched.step(1, edges)
            }
            #expect(matched.validator.results.first?.verdict == .matched)
            #expect(matched.validator.results.first?.windowEnd == .interrupted)
        }
    }

    @Test("A glitch while drawing shows nothing; the resumed attempt is unchecked after lift")
    func interruptionRecovery() {
        var feed = InputFeed()
        let edges = feed.edges("alpha")
        feed.step(0)
        feed.step(0, edges)
        feed.step(nil, edges)
        #expect(feed.validator.results.isEmpty, "the player is still drawing")
        #expect(feed.events.contains { $0.kind == .unchecked && $0.reason == .stripLoss })
        feed.step(0, edges)
        #expect(feed.validator.results.isEmpty)
        for _ in 0..<3 { feed.step(1, edges) }
        #expect(feed.validator.results.isEmpty, "no match without an observed start")
        feed.step(1)
        #expect(feed.validator.results.first?.reason == .missedStart)
    }

    @Test("Unobserved presentation, conflicting counts and obstructed indicators cannot yield a match")
    func trackingGates() {
        for gate in 0..<3 {
            var feed = InputFeed()
            feed.observedPresentation = gate != 0
            feed.slotCountConflict = gate == 1
            feed.indicatorsObstructed = gate == 2
            feed.draw(0, feed.edges("alpha"))
            #expect(feed.validator.results.isEmpty)
        }
        var feed = InputFeed()
        feed.step(0)
        feed.step(0, feed.edges("alpha"))
        feed.slots[0].status = .inferred
        for _ in 0..<3 { feed.step(1, feed.edges("alpha")) }
        feed.step(1)
        #expect(feed.validator.results.isEmpty)
    }

    @Test("Backwards source time and replay termination never complete a post-lift comparison")
    func brokenTimeAndEOF() {
        for backwards in [false, true] {
            var feed = InputFeed()
            let edges = feed.edges("alpha")
            feed.step(0)
            feed.step(0, edges)
            for _ in 0..<2 { feed.step(1, edges) }
            if backwards { feed.step(1, edges, gap: -0.1) }
            else { feed.validator.finish(at: feed.time) }
            #expect(feed.validator.results.first?.verdict == .unavailable)
            #expect(feed.validator.results.first?.reason == (backwards ? .frameGap : .endOfStream))
        }
    }

    @Test("Jumps and backward navigation do not submit a drawing")
    func navigation() {
        var jump = InputFeed()
        jump.step(0)
        jump.step(0, jump.edges("alpha"))
        jump.step(2, jump.edges("alpha"))
        jump.step(2, jump.edges("alpha"))
        jump.step(2)
        #expect(jump.validator.results.isEmpty)
        #expect(jump.events.contains { $0.reason == .multiSlotJump })
        var backward = InputFeed()
        backward.draw(0, backward.edges("alpha"))
        backward.step(0)
        backward.step(0)
        #expect(backward.validator.results.isEmpty)
        backward.draw(0, backward.edges("alpha"))
        #expect(backward.validator.results.first?.verdict == .matched)
        #expect(backward.validator.results.first?.attemptID == 2)
    }

    @Test("Unconfirmed expectations are excluded, but a confirmed slot after a hole is checkable")
    func expectations() {
        for status: SlotObservation.Status in [.pending, .observing, .inferred, .missing, .uncertain] {
            var feed = InputFeed()
            feed.slots[0].status = status
            feed.draw(0, feed.edges("alpha"))
            #expect(feed.validator.results.isEmpty)
            feed.draw(1, feed.edges("beta"))
            #expect(feed.validator.results.map(\.slotIndex) == [1])
            #expect(feed.validator.results.first?.verdict == .matched)
        }
    }

    @Test("Repeated shapes stay in separate slots; a new hack clears results")
    func identity() {
        var feed = InputFeed(names: ["alpha", "alpha", "alpha"])
        feed.draw(0, feed.edges("alpha"))
        feed.draw(1, feed.edges("alpha"))
        #expect(feed.validator.results.map(\.slotIndex) == [0, 1])
        #expect(Set(feed.validator.results.map(\.attemptID)).count == 2)
        let old = feed.validator.results
        feed.step(0, sessionID: CaptureSessionID(rawValue: 99))
        #expect(feed.validator.results == old)
        feed.hackID = 2
        feed.step(0)
        #expect(feed.validator.results.isEmpty)
    }

    @Test("Expected templates normalize long edges; measured elementary edges are used as supplied")
    func normalizedTemplates() {
        let table = GlyphTable(entries: [GlyphID("long"): GlyphPath(encoded: "08")!])
        var feed = InputFeed(table: table, names: ["long", "long"])
        let normalized = feed.edges("long")
        #expect(normalized == GlyphGeometry.normalizedEdges(table.path(for: GlyphID("long"))!.undirectedEdges))
        feed.draw(0, normalized)
        #expect(feed.validator.results.first?.verdict == .matched)
    }

    @Test("The validator observes the tracker without changing presentation or prediction")
    func trackerOwnership() {
        let table = InputFeed.synthetic
        let session = CaptureSessionID(rawValue: 1)
        var tracker = PresentationTracker(sessionID: session)
        var validator = PlayerInputValidator(table: table, sessionID: session)
        var time = 0.0
        for (phase, index, name) in [(GamePhase.presenting, 0, "alpha"), (.presenting, 1, "beta"), (.input, 0, "beta")] {
            for _ in 0..<4 {
                time += 0.05
                let edges = GlyphFrameRecognizer(table: table).expectedEdges(for: GlyphID(name))!
                let evidence = FrameEvidence(sessionID: session, time: time,
                    header: HeaderReading(phase: phase, matchedText: "", confidence: 1, sourceTime: time),
                    slots: SlotStripReading(slotCount: 2, highlightedIndex: index, markerCentersX: [], hasInputTimerBar: phase == .input),
                    shape: ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name), edges: edges, extensions: []),
                    hasValidCalibration: true)
                tracker.accept(evidence)
                let before = tracker.slots, prefix = tracker.confirmedPrefix, revision = tracker.revision
                validator.accept(evidence, tracker: tracker,
                                 edgeEvidence: edges.map { GlyphEdgeEvidence(edge: $0, samples: [1]) })
                #expect(tracker.slots == before)
                #expect(tracker.confirmedPrefix == prefix)
                #expect(tracker.revision == revision)
            }
        }
        #expect(tracker.confirmedPrefix.map(\.name) == ["alpha", "beta"])
    }

    @Test("A missing edge that was partly lit cannot make a drawing differ; a dark one can")
    func partlyLitEdges() {
        let right = InputFeed().edges("alpha")
        let edge = right.sorted { "\($0)" < "\($1)" }[0]
        for (coverage, verdict, reason) in [(0.6, InputCheckVerdict.unavailable, InputCheckUnavailableReason?.some(.partialEdge)),
                                            (0.3, .unavailable, .partialEdge),
                                            (0.1, .differs, nil)] {
            var feed = InputFeed()
            feed.step(0)
            feed.step(0, right)
            for _ in 0..<6 { feed.step(1, right.subtracting([edge]), partial: [edge: coverage]) }
            feed.step(1)
            #expect(feed.validator.results.first?.verdict == verdict, "coverage \(coverage)")
            #expect(feed.validator.results.first?.reason == reason, "coverage \(coverage)")
            #expect(feed.validator.results.first?.samples.last?.partialEdges == (coverage >= 0.3 ? [edge] : []))
        }
        // A partly lit edge that is not expected changes nothing: extra edges
        // must be fully present to count, and this drawing has none.
        var extra = InputFeed()
        let other = extra.edges("beta").sorted { "\($0)" < "\($1)" }[0]
        extra.step(0)
        extra.step(0, right)
        for _ in 0..<3 { extra.step(1, right, partial: [other: 0.6]) }
        extra.step(1)
        #expect(extra.validator.results.first?.verdict == .matched)
    }

    @Test("Partial evidence in a shorter stable run withholds a later or earlier mismatch")
    func partialEvidenceAcrossRuns() {
        for partialFirst in [true, false] {
            var feed = InputFeed()
            let right = feed.edges("alpha")
            let edge = right.sorted { "\($0)" < "\($1)" }[0]
            let missing = right.subtracting([edge])
            // Both runs read the same incomplete shape. The shorter run is
            // stable enough to vote, with one sample supporting its missing
            // edge; the longer run alone would meet the mismatch threshold.
            let partial = [0.1, 0.6, 0.1]
            let dark = Array(repeating: 0.1, count: 5)
            let runs = partialFirst ? [partial, dark] : [dark, partial]
            feed.step(0)
            feed.step(0, right)
            for (index, coverages) in runs.enumerated() {
                if index > 0 { feed.step(1, right) } // A one-frame flicker is not a stable match.
                for coverage in coverages {
                    feed.step(1, missing, partial: [edge: coverage])
                }
            }
            #expect(feed.validator.results.isEmpty, "an open wrong reading cannot warn")
            feed.step(1)
            #expect(feed.validator.results.first?.verdict == .unavailable)
            #expect(feed.validator.results.first?.reason == .partialEdge)
        }
    }

    @Test("Recorded truth, drawn correctly twice, is never called a different Glyph",
          .enabled(if: ReferenceData.shapesAvailable))
    func recordedTruth() throws {
        // spikeB-2026-09-23T23-00-56Z: Ingress accepted both drawings. After
        // lift the recognizer read every edge but 3-5, lit at 58-62% on the
        // first attempt and 75-79% after Redo, for five samples over 200 ms.
        let table = try ReferenceData.glyphTable()
        let truth = GlyphGeometry.normalizedEdges(GlyphPath(encoded: "3574563")!.undirectedEdges)
        let e35 = GlyphPath.Edge(NodeIndex(character: "3")!, NodeIndex(character: "5")!)
        let e36 = GlyphPath.Edge(NodeIndex(character: "3")!, NodeIndex(character: "6")!)
        let attempts: [[(Set<GlyphPath.Edge>, [GlyphPath.Edge: Double])]] = [
            [0.62, 0.62, 0.58, 0.58, 0.62].map { (truth.subtracting([e35]), [e35: $0]) },
            [(truth.subtracting([e35, e36]), [e35: 0.79, e36: 0.79])]
                + [0.79, 0.79, 0.79, 0.75, 0.75].map { (truth.subtracting([e35]), [e35: $0]) }
        ]
        for (number, postLift) in attempts.enumerated() {
            var feed = InputFeed(table: table, names: ["truth", "idea", "discover", "xm"])
            #expect(feed.edges("truth") == truth)
            feed.step(0)
            feed.step(0, truth)
            for (edges, partial) in postLift { feed.step(1, edges, partial: partial) }
            feed.step(1)
            let result = try #require(feed.validator.results.first, "attempt \(number + 1)")
            #expect(result.verdict == .unavailable, "attempt \(number + 1)")
            #expect(result.reason == .partialEdge, "attempt \(number + 1)")
        }
    }

    @Test("Recorded shield and mind drawings match despite transients during and after lift",
          .enabled(if: ReferenceData.shapesAvailable))
    func recordedTransients() throws {
        let table = try ReferenceData.glyphTable()
        func edges(_ encoded: String) -> Set<GlyphPath.Edge> {
            GlyphGeometry.normalizedEdges(GlyphPath(encoded: encoded)!.undirectedEdges)
        }
        // Edge sets from the IMG_2003.MP4 replay at 20 fps, 562 px wide. While
        // drawing, shield showed `4-a` for 13 samples and mind `5-6` for 3.
        // After lift shield kept `4-a` for 2 samples; mind lacked `5-a` in 3
        // of its first 4. Each run is (edge set, samples).
        let shield = edges("036a740")
        let mind = edges("35a63")
        let recorded: [(String, Set<GlyphPath.Edge>, Int, [(Set<GlyphPath.Edge>, Int)], Int)] = [
            ("shield", shield.union(edges("4a")), 13, [(shield.union(edges("4a")), 2), (shield, 9)], 5),
            ("mind", mind.union(edges("56")), 3,
             [(mind.subtracting(edges("5a")), 1), (mind, 1), (mind.subtracting(edges("5a")), 2), (mind, 35)], 7)
        ]
        for (name, drawing, drawingSamples, postLift, shownAfter) in recorded {
            var feed = InputFeed(table: table, names: [name, "xm"])
            #expect(feed.edges(name) == (name == "shield" ? shield : mind))
            feed.step(0)
            for _ in 0..<drawingSamples { feed.step(0, drawing) }
            #expect(feed.validator.results.isEmpty)
            var sent = 0
            for (set, count) in postLift {
                for _ in 0..<count {
                    feed.step(1, set)
                    sent += 1
                    // The advance is confirmed on the second post-lift sample.
                    if sent >= 2, sent < shownAfter { #expect(feed.validator.results.isEmpty, "\(name) \(sent)") }
                    if sent == shownAfter { #expect(feed.validator.results.first?.verdict == .matched, "\(name)") }
                }
            }
            feed.step(1)
            #expect(feed.validator.results.first?.verdict == .matched)
            #expect(feed.validator.results.first?.reason == nil)
        }
    }
}
