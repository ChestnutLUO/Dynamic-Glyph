import Foundation
import Testing
import GlyphRecognitionCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// The C++ input area (`glyph_logic_input.h`) held to the Swift oracle:
/// every scenario of `PlayerInputValidatorTests`, `PredictionTests`,
/// `UpcomingGuidanceTests` and `InputCheckDisplayTests` through both arms with
/// the same inputs, compared output for output after every step, then seeded
/// random walks.
@Suite("C++ logic: player input and prediction")
struct CxxInputTests {
    // MARK: - Comparison

    private static func json(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.bitPattern == y.bitPattern || (x.isNaN && y.isNaN)
        default: return false
        }
    }

    /// `==` on every field, except that NaN times, which `finish(at:)` can
    /// put in a result, count as equal to each other.
    static func same(_ a: InputCheckResult?, _ b: InputCheckResult?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.sessionID == b.sessionID && a.hackID == b.hackID && a.slotIndex == b.slotIndex
            && a.attemptID == b.attemptID && a.expectedGlyph == b.expectedGlyph && a.verdict == b.verdict
            && a.reason == b.reason && same(a.sourceTime, b.sourceTime) && same(a.startTime, b.startTime)
            && same(a.liftTime, b.liftTime) && a.windowEnd == b.windowEnd && a.samples.count == b.samples.count
            && zip(a.samples, b.samples).allSatisfy { x, y in
                same(x.time, y.time) && x.edges == y.edges && x.partialEdges == y.partialEdges
            }
    }

    /// Field for field, then the diagnostic row the replay and the app write.
    static func expectSame(_ swift: [InputCheckEvent], _ cxx: [InputCheckEvent], _ label: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(swift.count == cxx.count, "\(label): event count", sourceLocation: sourceLocation)
        for (a, b) in zip(swift, cxx) {
            let fields = a.kind == b.kind && same(a.time, b.time) && a.hackID == b.hackID
                && a.slotIndex == b.slotIndex && a.attemptID == b.attemptID && a.reason == b.reason
                && same(a.result, b.result) && a.edgeEvidence.count == b.edgeEvidence.count
                && zip(a.edgeEvidence, b.edgeEvidence).allSatisfy { x, y in
                    x.edge == y.edge && x.samples.count == y.samples.count
                        && zip(x.samples, y.samples).allSatisfy { same($0, $1) }
                }
            #expect(fields, "\(label): \(a.kind) / \(b.kind) at \(a.time)", sourceLocation: sourceLocation)
            let rowA = json(a.diagnosticRow), rowB = json(b.diagnosticRow)
            if let rowA, let rowB {
                #expect(rowA == rowB, "\(label): diagnostic row", sourceLocation: sourceLocation)
            }
        }
    }

    static func expectSame(_ swift: PlayerInputValidator, _ cxx: CxxPlayerInputValidator, _ label: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(swift.revision == cxx.revision, "\(label): revision", sourceLocation: sourceLocation)
        let a = swift.results, b = cxx.results
        #expect(a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }, "\(label): results",
                sourceLocation: sourceLocation)
        #expect(a.map { json($0.diagnosticRow) } == b.map { json($0.diagnosticRow) },
                "\(label): result rows", sourceLocation: sourceLocation)
    }

    // MARK: - The oracle's feed, driving both arms

    private struct DualFeed {
        static let synthetic = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!,
                                                    GlyphID("beta"): GlyphPath(encoded: "456")!])
        let session = CaptureSessionID(rawValue: 1)
        let table: GlyphTable
        let label: String
        var swift: PlayerInputValidator
        let cxx: CxxPlayerInputValidator
        var slots: [SlotObservation]
        var state: TrackingState = .input
        var hackID = 1
        var observedPresentation = true
        var slotCountConflict = false
        var indicatorsObstructed = false
        var time = 10.0
        var steps = 0
        var swiftEvents: [InputCheckEvent] = []

        init(_ label: String, table: GlyphTable = Self.synthetic, names: [String] = ["alpha", "beta", "alpha"]) {
            self.label = label
            self.table = table
            swift = PlayerInputValidator(table: table, sessionID: CaptureSessionID(rawValue: 1))
            cxx = CxxPlayerInputValidator(table: table, sessionID: CaptureSessionID(rawValue: 1))
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
            steps += 1
            let evidence = FrameEvidence(sessionID: sessionID ?? session, time: time, header: nil,
                slots: index.map { SlotStripReading(slotCount: slots.count, highlightedIndex: $0,
                                                   markerCentersX: [], hasInputTimerBar: true) },
                shape: ShapeEvidence(kind: edges == nil ? .noStroke : kind, glyph: nil,
                                     edges: edges ?? [], extensions: []),
                hasValidCalibration: calibrated)
            let context = PlayerInputValidator.Context(
                state: state, hackID: hackID, slots: slots, expectedSlotCount: slots.count,
                observedPresentation: observedPresentation, slotCountConflict: slotCountConflict,
                indicatorsObstructed: indicatorsObstructed)
            // Sorted so both arms see the same order; the oracle's own order
            // comes from a Set and a Dictionary.
            let evidenceList = (edges ?? []).sorted(by: Self.edgeOrder)
                .map { GlyphEdgeEvidence(edge: $0, samples: [1, 1, 1]) }
                + partial.sorted { Self.edgeOrder($0.key, $1.key) }.map { edge, coverage in
                    let lit = Int((coverage * 100).rounded())
                    return GlyphEdgeEvidence(edge: edge, samples: Array(repeating: 1, count: lit)
                                             + Array(repeating: 0, count: 100 - lit))
                }
            let a = swift.accept(evidence, context: context, edgeEvidence: evidenceList)
            let b = cxx.accept(evidence, context: context, edgeEvidence: evidenceList)
            swiftEvents += a
            CxxInputTests.expectSame(a, b, "\(label) step \(steps)")
            CxxInputTests.expectSame(swift, cxx, "\(label) step \(steps)")
        }

        mutating func finish(at stamp: Double? = nil) {
            steps += 1
            let a = swift.finish(at: stamp ?? time), b = cxx.finish(at: stamp ?? time)
            swiftEvents += a
            CxxInputTests.expectSame(a, b, "\(label) finish")
            CxxInputTests.expectSame(swift, cxx, "\(label) finish")
        }

        mutating func draw(_ index: Int, _ edges: Set<GlyphPath.Edge>, postLift: [Set<GlyphPath.Edge>]? = nil) {
            step(index)
            step(index, edges)
            for frame in postLift ?? Array(repeating: edges, count: 3) { step(index + 1, frame) }
            step(index + 1)
        }

        static func edgeOrder(_ a: GlyphPath.Edge, _ b: GlyphPath.Edge) -> Bool {
            (a.lower.rawValue, a.upper.rawValue) < (b.lower.rawValue, b.upper.rawValue)
        }
    }

    // MARK: - PlayerInputValidatorTests, scenario for scenario

    @Test("Consecutive attempts")
    func consecutiveAttempts() {
        var feed = DualFeed("consecutive")
        feed.draw(0, feed.edges("alpha"))
        feed.step(1, feed.edges("beta"))
        for _ in 0..<3 { feed.step(2, feed.edges("beta")) }
        feed.step(2)
        feed.step(2, feed.edges("alpha"))
        feed.state = .completed
        feed.step(nil, feed.edges("beta"))
        #expect(feed.cxx.results.map(\.verdict) == [.matched, .matched])
    }

    @Test("Agreement of post-lift runs")
    func agreement() {
        let right = DualFeed("").edges("alpha"), wrong = DualFeed("").edges("beta")
        let cases: [[Set<GlyphPath.Edge>]] = [
            [right, right, right], [wrong, wrong, right, right, right], [wrong, wrong, wrong, wrong, wrong],
            [wrong, wrong, wrong], [right, right], [right], [right, wrong, right, wrong],
            [right, right, right, wrong, wrong, wrong], [wrong, wrong, wrong, right, right, right],
            [[], [], [], [], [], []]
        ]
        for (number, samples) in cases.enumerated() {
            var feed = DualFeed("agreement \(number)")
            feed.draw(0, right, postLift: samples)
        }
    }

    @Test("Early match and its kept time")
    func earlyMatch() {
        var feed = DualFeed("early")
        let right = feed.edges("alpha"), wrong = feed.edges("beta")
        feed.step(0)
        feed.step(0, right)
        for _ in 0..<3 { feed.step(1, right) }
        for _ in 0..<5 { feed.step(1, right) }
        feed.step(1)
        var wrongFeed = DualFeed("early wrong")
        wrongFeed.step(0)
        wrongFeed.step(0, right)
        for _ in 0..<8 { wrongFeed.step(1, wrong) }
        wrongFeed.step(1)
        #expect(wrongFeed.cxx.results.first?.verdict == .differs)
    }

    @Test("Withdrawn match")
    func withdrawnMatch() {
        var feed = DualFeed("withdrawn")
        let right = feed.edges("alpha"), wrong = feed.edges("beta")
        feed.step(0)
        feed.step(0, right)
        for _ in 0..<3 { feed.step(1, right) }
        for _ in 0..<3 { feed.step(1, wrong) }
        feed.step(1)
    }

    @Test("Span and duplicate timestamps")
    func span() {
        var feed = DualFeed("span")
        let edges = feed.edges("alpha")
        feed.step(0)
        feed.step(0, edges)
        for _ in 0..<3 { feed.step(1, edges, gap: 0.025) }
        feed.step(1)
        var duplicates = DualFeed("duplicates")
        duplicates.step(0)
        duplicates.step(0, edges)
        duplicates.step(1, edges)
        for _ in 0..<4 { duplicates.step(1, edges, gap: 0) }
        duplicates.step(1)
    }

    @Test("Classification independence")
    func classificationIndependent() {
        for kind: ShapeEvidence.Kind in [.unexplainedInk, .unrecognizedStroke, .ambiguousShape, .uniqueVisibleShape] {
            var feed = DualFeed("kind \(kind)")
            let right = feed.edges("alpha"), wrong = feed.edges("beta")
            feed.step(0)
            for _ in 0..<13 { feed.step(0, wrong, kind: kind) }
            for _ in 0..<3 { feed.step(1, right, kind: kind) }
            feed.step(1)
        }
    }

    @Test("Missed start and missed clear")
    func missedStartAndClear() {
        var feed = DualFeed("missed start")
        let edges = feed.edges("alpha")
        feed.step(0, edges)
        for _ in 0..<3 { feed.step(1, edges) }
        feed.step(1)
        var clear = DualFeed("missed clear")
        clear.step(0)
        clear.step(0, clear.edges("alpha"))
        for _ in 0..<3 { clear.step(1, clear.edges("alpha")) }
        for _ in 0..<3 { clear.step(1, clear.edges("beta")) }
        for _ in 0..<3 { clear.step(2, clear.edges("beta")) }
        clear.step(2)
    }

    @Test("Ink-only boundary and unclosed window")
    func inkOnlyAndUnclosed() {
        var feed = DualFeed("ink only")
        let alpha = feed.edges("alpha"), beta = feed.edges("beta")
        feed.step(0)
        feed.step(0, alpha)
        for _ in 0..<5 { feed.step(1, alpha) }
        feed.step(1, [])
        for _ in 0..<4 { feed.step(1, beta) }
        for _ in 0..<3 { feed.step(2, beta) }
        feed.step(2)
        var unclosed = DualFeed("unclosed")
        unclosed.step(0)
        unclosed.step(0, alpha)
        for _ in 0..<2 { unclosed.step(1, alpha) }
        unclosed.step(2, beta)
        unclosed.step(2, beta)
    }

    @Test("Interruptions, before and after a match")
    func interruptions() {
        for reason: InputCheckUnavailableReason in [.frameGap, .stripLoss, .invalidCalibration, .phaseChange] {
            for stableRun in [2, 3] {
                var feed = DualFeed("interruption \(reason) \(stableRun)")
                let edges = feed.edges("alpha")
                feed.step(0)
                feed.step(0, edges)
                for _ in 0..<stableRun { feed.step(1, edges) }
                switch reason {
                case .frameGap: feed.step(1, edges, gap: 0.2)
                case .stripLoss: feed.step(nil, edges)
                case .invalidCalibration: feed.step(1, edges, calibrated: false)
                default: feed.state = .completed; feed.step(1, edges)
                }
            }
        }
    }

    @Test("Interruption recovery")
    func interruptionRecovery() {
        var feed = DualFeed("recovery")
        let edges = feed.edges("alpha")
        feed.step(0)
        feed.step(0, edges)
        feed.step(nil, edges)
        feed.step(0, edges)
        for _ in 0..<3 { feed.step(1, edges) }
        feed.step(1)
        #expect(feed.cxx.results.first?.reason == .missedStart)
    }

    @Test("Tracking gates")
    func trackingGates() {
        for gate in 0..<3 {
            var feed = DualFeed("gate \(gate)")
            feed.observedPresentation = gate != 0
            feed.slotCountConflict = gate == 1
            feed.indicatorsObstructed = gate == 2
            feed.draw(0, feed.edges("alpha"))
        }
        var feed = DualFeed("inferred mid-drawing")
        feed.step(0)
        feed.step(0, feed.edges("alpha"))
        feed.slots[0].status = .inferred
        for _ in 0..<3 { feed.step(1, feed.edges("alpha")) }
        feed.step(1)
    }

    @Test("Backwards time and end of stream")
    func brokenTimeAndEOF() {
        for backwards in [false, true] {
            var feed = DualFeed("broken time \(backwards)")
            let edges = feed.edges("alpha")
            feed.step(0)
            feed.step(0, edges)
            for _ in 0..<2 { feed.step(1, edges) }
            if backwards { feed.step(1, edges, gap: -0.1) } else { feed.finish() }
        }
        // A non-finite end time lands in a result. NaN makes that result
        // unequal to itself, so a backward move that keeps every result still
        // counts as a change in Swift; the C++ arm must agree.
        for stamp in [Double.nan, .infinity, -.infinity] {
            var feed = DualFeed("non-finite end \(stamp)", names: ["alpha", "beta", "alpha", "beta"])
            let alpha = feed.edges("alpha"), beta = feed.edges("beta")
            feed.draw(0, alpha)
            feed.step(1, beta)
            feed.step(2, beta)
            feed.step(2, beta)
            feed.finish(at: stamp)
            feed.step(3)
            feed.step(2)
            feed.step(2)
            feed.step(2, alpha)
            feed.finish(at: stamp)
            #expect(feed.swift.revision == feed.cxx.revision)
        }
    }

    @Test("Jumps and backward navigation")
    func navigation() {
        var jump = DualFeed("jump")
        jump.step(0)
        jump.step(0, jump.edges("alpha"))
        jump.step(2, jump.edges("alpha"))
        jump.step(2, jump.edges("alpha"))
        jump.step(2)
        var backward = DualFeed("backward")
        backward.draw(0, backward.edges("alpha"))
        backward.step(0)
        backward.step(0)
        backward.draw(0, backward.edges("alpha"))
        #expect(backward.cxx.results.first?.attemptID == 2)
    }

    @Test("Unconfirmed expectations")
    func expectations() {
        for status: SlotObservation.Status in [.pending, .observing, .inferred, .missing, .uncertain] {
            var feed = DualFeed("expectation \(status)")
            feed.slots[0].status = status
            feed.draw(0, feed.edges("alpha"))
            feed.draw(1, feed.edges("beta"))
        }
    }

    @Test("Identity across slots, sessions and hacks")
    func identity() {
        var feed = DualFeed("identity", names: ["alpha", "alpha", "alpha"])
        feed.draw(0, feed.edges("alpha"))
        feed.draw(1, feed.edges("alpha"))
        feed.step(0, sessionID: CaptureSessionID(rawValue: 99))
        feed.hackID = 2
        feed.step(0)
        #expect(feed.cxx.results.isEmpty)
    }

    @Test("Normalized templates")
    func normalizedTemplates() {
        let table = GlyphTable(entries: [GlyphID("long"): GlyphPath(encoded: "08")!])
        var feed = DualFeed("normalized", table: table, names: ["long", "long"])
        feed.draw(0, feed.edges("long"))
        #expect(feed.cxx.results.first?.verdict == .matched)
    }

    @Test("Tracker form, including another session's tracker")
    func trackerOwnership() {
        let table = DualFeed.synthetic
        let session = CaptureSessionID(rawValue: 1)
        var tracker = PresentationTracker(sessionID: session)
        let stranger = PresentationTracker(sessionID: CaptureSessionID(rawValue: 7))
        var swift = PlayerInputValidator(table: table, sessionID: session)
        let cxx = CxxPlayerInputValidator(table: table, sessionID: session)
        var time = 0.0
        var step = 0
        for (phase, index, name) in [(GamePhase.presenting, 0, "alpha"), (.presenting, 1, "beta"), (.input, 0, "beta"),
                                     (.input, 1, "alpha"), (.input, 1, "alpha")] {
            for _ in 0..<4 {
                time += 0.05
                step += 1
                let edges = GlyphFrameRecognizer(table: table).expectedEdges(for: GlyphID(name))!
                let evidence = FrameEvidence(sessionID: session, time: time,
                    header: HeaderReading(phase: phase, matchedText: "", confidence: 1, sourceTime: time),
                    slots: SlotStripReading(slotCount: 2, highlightedIndex: index, markerCentersX: [],
                                            hasInputTimerBar: phase == .input),
                    shape: ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name), edges: edges, extensions: []),
                    hasValidCalibration: true)
                tracker.accept(evidence)
                let evidenceList = edges.sorted(by: DualFeed.edgeOrder).map { GlyphEdgeEvidence(edge: $0, samples: [1]) }
                Self.expectSame(swift.accept(evidence, tracker: stranger, edgeEvidence: evidenceList),
                                cxx.accept(evidence, tracker: stranger, edgeEvidence: evidenceList), "stranger \(step)")
                Self.expectSame(swift.accept(evidence, tracker: tracker, edgeEvidence: evidenceList),
                                cxx.accept(evidence, tracker: tracker, edgeEvidence: evidenceList), "tracker \(step)")
                Self.expectSame(swift, cxx, "tracker \(step)")
            }
        }
        Self.expectSame(swift.finish(at: time), cxx.finish(at: time), "tracker finish")
        Self.expectSame(swift, cxx, "tracker finish")
    }

    @Test("Partly lit edges")
    func partlyLitEdges() {
        let right = DualFeed("").edges("alpha")
        let edge = right.sorted { "\($0)" < "\($1)" }[0]
        for coverage in [0.6, 0.3, 0.1] {
            var feed = DualFeed("partial \(coverage)")
            feed.step(0)
            feed.step(0, right)
            for _ in 0..<6 { feed.step(1, right.subtracting([edge]), partial: [edge: coverage]) }
            feed.step(1)
        }
        var extra = DualFeed("partial extra")
        let other = extra.edges("beta").sorted { "\($0)" < "\($1)" }[0]
        extra.step(0)
        extra.step(0, right)
        for _ in 0..<3 { extra.step(1, right, partial: [other: 0.6]) }
        extra.step(1)
    }

    @Test("Partial evidence across runs")
    func partialEvidenceAcrossRuns() {
        for partialFirst in [true, false] {
            var feed = DualFeed("partial runs \(partialFirst)")
            let right = feed.edges("alpha")
            let edge = right.sorted { "\($0)" < "\($1)" }[0]
            let missing = right.subtracting([edge])
            let partial = [0.1, 0.6, 0.1]
            let dark = Array(repeating: 0.1, count: 5)
            let runs = partialFirst ? [partial, dark] : [dark, partial]
            feed.step(0)
            feed.step(0, right)
            for (index, coverages) in runs.enumerated() {
                if index > 0 { feed.step(1, right) }
                for coverage in coverages { feed.step(1, missing, partial: [edge: coverage]) }
            }
            feed.step(1)
        }
    }

    @Test("Recorded truth", .enabled(if: ReferenceData.shapesAvailable))
    func recordedTruth() throws {
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
            var feed = DualFeed("truth \(number)", table: table, names: ["truth", "idea", "discover", "xm"])
            feed.step(0)
            feed.step(0, truth)
            for (edges, partial) in postLift { feed.step(1, edges, partial: partial) }
            feed.step(1)
            #expect(feed.cxx.results.first?.reason == .partialEdge)
        }
    }

    @Test("Recorded transients", .enabled(if: ReferenceData.shapesAvailable))
    func recordedTransients() throws {
        let table = try ReferenceData.glyphTable()
        func edges(_ encoded: String) -> Set<GlyphPath.Edge> {
            GlyphGeometry.normalizedEdges(GlyphPath(encoded: encoded)!.undirectedEdges)
        }
        let shield = edges("036a740")
        let mind = edges("35a63")
        let recorded: [(String, Set<GlyphPath.Edge>, Int, [(Set<GlyphPath.Edge>, Int)])] = [
            ("shield", shield.union(edges("4a")), 13, [(shield.union(edges("4a")), 2), (shield, 9)]),
            ("mind", mind.union(edges("56")), 3,
             [(mind.subtracting(edges("5a")), 1), (mind, 1), (mind.subtracting(edges("5a")), 2), (mind, 35)])
        ]
        for (name, drawing, drawingSamples, postLift) in recorded {
            var feed = DualFeed(name, table: table, names: [name, "xm"])
            feed.step(0)
            for _ in 0..<drawingSamples { feed.step(0, drawing) }
            for (set, count) in postLift { for _ in 0..<count { feed.step(1, set) } }
            feed.step(1)
            #expect(feed.cxx.results.first?.verdict == .matched)
        }
    }

    // MARK: - InputCheckDisplayTests, with results from each arm

    @Test("Input check display reads the same from either arm's results")
    func inputCheckDisplay() {
        let right = DualFeed("").edges("alpha"), wrong = DualFeed("").edges("beta")
        let feeds: [(String, [Set<GlyphPath.Edge>])] = [
            ("matched", [right, right, right]), ("differs", Array(repeating: wrong, count: 5)),
            ("unavailable", [right])
        ]
        for (label, postLift) in feeds {
            var feed = DualFeed("display \(label)")
            feed.draw(0, right, postLift: postLift)
            func snapshot(_ results: [InputCheckResult], session: UInt64, hack: Int) -> GlyphDisplaySnapshot {
                GlyphDisplaySnapshot(captureSessionID: CaptureSessionID(rawValue: session), hackID: hack,
                    revision: 5, liveness: .live, state: .input, phaseSource: .inputTimer,
                    acceptance: .trackingSequence, sourceFrameTime: feed.time, evidenceArrivalUptime: 100,
                    expectedSlotCount: 3, slots: feed.slots, currentSlotIndex: nil, inputSlotIndex: 1,
                    slotCountConflict: false, isFrozen: true, provisionalGlyph: nil, provisionalExtensionCount: 0,
                    outlook: .unavailable, calibrationSummary: "", inputChecks: results, inputCheckRevision: 1)
            }
            for (session, hack) in [(UInt64(1), 1), (2, 1), (1, 2)] {
                let a = snapshot(feed.swift.results, session: session, hack: hack)
                let b = snapshot(feed.cxx.results, session: session, hack: hack)
                for uptime in [100.0, 100.5, 101.6, 102.0] {
                    for slot in 0..<3 {
                        #expect(a.inputCheckDisplay(for: slot, atUptime: uptime)
                                == b.inputCheckDisplay(for: slot, atUptime: uptime), "\(label) \(slot) \(uptime)")
                    }
                    #expect(a.inputCheckRenderKey(atUptime: uptime) == b.inputCheckRenderKey(atUptime: uptime))
                }
            }
        }
    }

    // MARK: - PredictionTests and UpcomingGuidanceTests

    private static func g(_ names: String...) -> [GlyphID] { names.map(GlyphID.init) }

    private static func expectSameOutlooks(_ table: SequenceTable, _ observed: [[GlyphID]], _ label: String,
                                           lengths: [Int?] = [nil, 0, 1, 2, 3, 4, 5, 6],
                                           sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        let swift = SequencePredictor(table: table)
        let cxx = CxxSequencePredictor(table: table)
        var compared = 0
        for prefix in observed {
            for length in lengths {
                for limit in [8, 0, 1, 1_000] {
                    let a = swift.outlook(observed: prefix, expectedLength: length, displayCandidateLimit: limit)
                    let b = cxx.outlook(observed: prefix, expectedLength: length, displayCandidateLimit: limit)
                    #expect(a == b, "\(label) \(prefix.map(\.name)) length \(String(describing: length)) limit \(limit)",
                            sourceLocation: sourceLocation)
                    compared += 1
                }
                // The protocol's two-argument form.
                #expect(swift.outlook(observed: prefix, expectedLength: length)
                        == cxx.outlook(observed: prefix, expectedLength: length), sourceLocation: sourceLocation)
            }
        }
        return compared
    }

    @Test("Prediction scenarios on the hand-written tables")
    func predictionScenarios() {
        let g = Self.g
        let table = SequenceTable(sequences: [g("a", "b", "c"), g("a", "b", "d"), g("a", "e"), g("f", "g")])
        _ = Self.expectSameOutlooks(table, [g(), g("a"), g("a", "b"), g("a", "b", "c"), g("f"), g("a", "z"),
                                            g("a", "e", "x", "y"), g("z"), g("f", "g")], "basic")
        let repeated = SequenceTable(sequences: [g("a", "a", "b"), g("a", "b", "a")])
        _ = Self.expectSameOutlooks(repeated, [g(), g("a"), g("a", "a"), g("a", "b")], "repeated")
        let duplicates = SequenceTable(sequences: [g("a", "b"), g("a", "b"), g("c", "d")])
        _ = Self.expectSameOutlooks(duplicates, [g(), g("a"), g("c")], "duplicates")
        let terminal = SequenceTable(sequences: [g("a", "b"), g("a", "b", "c")])
        _ = Self.expectSameOutlooks(terminal, [g(), g("a"), g("a", "b"), g("a", "b", "c")], "terminal")
        // Names that are prefixes of each other. With a character below the
        // comma the joined names sort differently from the name lists.
        let names = SequenceTable(sequences: [g("ab", "c"), g("a", "bc"), g("a", "b"), g("abc"), g("a-b", "c"),
                                              g("a", "b", "c"), g("a b", "x"), g("a", "x"), g("a!", "x")])
        _ = Self.expectSameOutlooks(names, [g(), g("a"), g("ab"), g("a", "b")], "joined names")
    }

    @Test("Prediction on the reference table's named cases", .enabled(if: ReferenceData.sequencesAvailable))
    func referencePredictionScenarios() throws {
        let g = Self.g
        let table = try ReferenceData.sequenceTable()
        let duplicated = g("have", "harmony", "together", "end", "mystery")
        _ = Self.expectSameOutlooks(table, [Array(duplicated.prefix(4)), g("pursue", "conflict"),
                                            g("change", "perspective")], "reference")
    }

    @Test("Upcoming guidance from either arm's outlook", .enabled(if: ReferenceData.sequencesAvailable))
    func upcomingGuidance() throws {
        let table = try ReferenceData.sequenceTable()
        let swift = SequencePredictor(table: table), cxx = CxxSequencePredictor(table: table)
        let observed = [GlyphID("change"), GlyphID("perspective")]
        let slots = ["change", "perspective"].enumerated().map {
            SlotObservation(index: $0.offset, status: .confirmed, glyph: GlyphID($0.element))
        } + [SlotObservation(index: 2), SlotObservation(index: 3)]
        func snapshot(_ outlook: SequenceOutlook) -> GlyphDisplaySnapshot {
            GlyphDisplaySnapshot(
                captureSessionID: CaptureSessionID(rawValue: 1), hackID: 1, revision: 1,
                liveness: .live, state: .input, phaseSource: .headerText, acceptance: .trackingSequence,
                sourceFrameTime: 100, evidenceArrivalUptime: 10, expectedSlotCount: 4, slots: slots,
                currentSlotIndex: nil, inputSlotIndex: 2, inputSlotObservedTime: 100,
                slotCountConflict: false, isFrozen: true, provisionalGlyph: nil, provisionalExtensionCount: 0,
                outlook: outlook, calibrationSummary: "11 rings")
        }
        let a = swift.outlook(observed: observed, expectedLength: 4)
        let b = cxx.outlook(observed: observed, expectedLength: 4)
        #expect(a == b)
        let guidance = snapshot(b).upcomingGuidance()
        #expect(snapshot(a).upcomingGuidance() == guidance)
        #expect(guidance?.styles.compactMap(\.glyph).map(\.name) == ["begin", "new"])
    }

    @Test("Every prefix of 200 random reference sequences", .enabled(if: ReferenceData.sequencesAvailable))
    func randomReferencePrefixes() throws {
        let table = try ReferenceData.sequenceTable()
        var random = SplitMix64(seed: 0x5eed_0f_1e55)
        var prefixes: [[GlyphID]] = []
        let vocabulary = Array(Set(table.sequences.joined())).sorted()
        for _ in 0..<200 {
            let sequence = table.sequences[random.next(below: table.sequences.count)]
            for length in 0...min(4, sequence.count) {
                let prefix = Array(sequence.prefix(length))
                prefixes.append(prefix)
                // The same prefix with its last Glyph swapped, often contradicted,
                // and with a Glyph outside the table.
                if length > 0 {
                    var swapped = prefix
                    swapped[length - 1] = vocabulary[random.next(below: vocabulary.count)]
                    prefixes.append(swapped)
                    var unknown = prefix
                    unknown[random.next(below: length)] = GlyphID("not-a-glyph")
                    prefixes.append(unknown)
                }
            }
        }
        // Each distinct prefix once; the walk draws the short ones many times.
        var seen = Set<[GlyphID]>()
        let distinct = prefixes.filter { seen.insert($0).inserted }
        let compared = Self.expectSameOutlooks(table, distinct, "random prefixes", lengths: [nil, 1, 2, 3, 4, 5, 0, 6])
        #expect(compared == distinct.count * 8 * 4)
    }

    // MARK: - Seeded random walks through both validators

    /// One scripted frame of a simulated player: the highlighted slot relative
    /// to the attempt's slot, and what the array shows.
    private enum Drawing {
        case clear
        case target
        case other(GlyphID)
        case partial(GlyphPath.Edge, Double)
        case stray
        case inkOnly
    }

    @Test("Random walks of 2,000 steps, three seeds", arguments: [UInt64(1), 0xdead_beef, 20_261_108])
    func randomWalk(seed: UInt64) throws {
        let table = ReferenceData.shapesAvailable ? try ReferenceData.glyphTable() : DualFeed.synthetic
        var policy = PlayerInputValidator.Policy()
        if seed == 20_261_108 {
            policy.minimumSamples = 2
            policy.minimumDifferingSamples = 4
            policy.minimumPartialCoverage = 0.45
        }
        var random = SplitMix64(seed: seed)
        let session = CaptureSessionID(rawValue: 3)
        var swift = PlayerInputValidator(table: table, sessionID: session, policy: policy)
        let cxx = CxxPlayerInputValidator(table: table, sessionID: session, policy: policy)
        let recognizer = GlyphFrameRecognizer(table: table)
        let names = Array(table.glyphs.prefix(12)) + [GlyphID("not-in-table")]
        let elementary = GlyphGeometry.elementaryEdges.sorted(by: DualFeed.edgeOrder)
        let statuses: [SlotObservation.Status] = [.pending, .observing, .confirmed, .inferred, .missing, .uncertain]

        var slotCount = 4
        var hackID = 1
        func freshSlots() -> [SlotObservation] {
            (0..<slotCount).map { index in
                SlotObservation(index: index, status: random.chance(0.9) ? .confirmed : statuses[random.next(below: 6)],
                                glyph: random.chance(0.97) ? names[random.next(below: names.count - 1)]
                                    : (random.chance(0.5) ? nil : names[names.count - 1]))
            }
        }
        var slots = freshSlots()
        var cursor = 0
        var time = 100.0
        // The scripted attempt: (highlight offset from `cursor`, drawing).
        var script: [(Int, Drawing)] = []
        var compared = 0
        var tally: [String: Int] = [:]

        func target(_ slot: Int) -> Set<GlyphPath.Edge>? {
            slots.first { $0.index == slot }?.glyph.flatMap { recognizer.expectedEdges(for: $0) }
        }
        func makeScript() -> [(Int, Drawing)] {
            var frames: [(Int, Drawing)] = []
            // A clear before drawing, sometimes missed.
            for _ in 0..<random.next(below: 4) { frames.append((0, .clear)) }
            for _ in 0..<(1 + random.next(below: 8)) { frames.append((0, random.chance(0.8) ? .target : .stray)) }
            // After lift: one reading, with flickers and settling transients.
            let edges = target(cursor)?.sorted(by: DualFeed.edgeOrder) ?? []
            let reading: Drawing
            let pick = random.unit()
            if pick < 0.55 || edges.isEmpty { reading = .target }
            else if pick < 0.8 { reading = .other(names[random.next(below: names.count - 1)]) }
            else { reading = .partial(edges[random.next(below: edges.count)], random.unit() * 0.75) }
            // Sometimes a second stable reading follows the first.
            let second: Drawing = random.chance(0.15) ? .other(names[random.next(below: names.count - 1)]) : reading
            let liftCount = 1 + random.next(below: 12)
            for frame in 0..<liftCount {
                let flicker = random.unit()
                let settled = frame < liftCount / 2 ? reading : second
                frames.append((1, flicker < 0.1 ? .stray : flicker < 0.15 ? .target : settled))
            }
            frames.append((1, random.chance(0.85) ? .clear : .inkOnly))
            return frames
        }

        for step in 0..<2_000 {
            if script.isEmpty {
                if cursor >= slotCount - 1 || random.chance(0.03) {
                    hackID += 1
                    slotCount = 2 + random.next(below: 4)
                    slots = freshSlots()
                    cursor = 0
                }
                script = makeScript()
            }
            let (offset, drawing) = script.removeFirst()
            var highlighted: Int? = min(cursor + offset, slotCount - 1)
            if script.isEmpty { cursor = min(cursor + 1, slotCount - 1) }

            // Rare disturbances to every input the validator reads.
            if random.chance(0.005) {
                let index = random.next(below: slots.count)
                slots[index].status = statuses[random.next(below: 6)]
            }
            if random.chance(0.003) { slots[random.next(below: slots.count)].glyph = names[random.next(below: names.count)] }
            if random.chance(0.004) { hackID += 1 }
            let state: TrackingState = random.chance(0.995) ? .input : [.presenting, .completed, .command][random.next(below: 3)]
            let expected: Int? = random.chance(0.997) ? slotCount : (random.chance(0.5) ? nil : slotCount + 1)
            let context = PlayerInputValidator.Context(
                state: state, hackID: hackID, slots: slots, expectedSlotCount: expected,
                observedPresentation: random.chance(0.997), slotCountConflict: random.chance(0.003),
                indicatorsObstructed: random.chance(0.003))
            let roll = random.unit()
            if roll < 0.01 { highlighted = nil }
            else if roll < 0.015 { highlighted = random.next(below: slotCount) }
            else if roll < 0.017 { highlighted = slotCount }
            else if roll < 0.018 { highlighted = -1 }
            else if roll < 0.022 {
                cursor = random.next(below: slotCount)
                script = []
            }
            let strip: SlotStripReading? = random.chance(0.995)
                ? SlotStripReading(slotCount: random.chance(0.997) ? slotCount : slotCount - 1,
                                   highlightedIndex: highlighted, markerCentersX: [], hasInputTimerBar: true)
                : nil

            // The 20 Hz cadence with jitter, duplicates, gaps, steps back and
            // the odd non-finite stamp.
            let timeRoll = random.unit()
            let stamp: Double
            if timeRoll < 0.01 { stamp = time }
            else if timeRoll < 0.015 { stamp = time + 0.15 }
            else if timeRoll < 0.018 { stamp = time - 0.05 }
            else if timeRoll < 0.019 { stamp = .nan }
            else if timeRoll < 0.02 { stamp = .infinity }
            else { stamp = time + 0.03 + 0.04 * random.unit() }
            if stamp.isFinite { time = max(time, stamp) }

            func lit(_ edge: GlyphPath.Edge, _ coverage: Double) -> GlyphEdgeEvidence {
                let count = random.chance(0.01) ? 0 : 10 + random.next(below: 15)
                let litCount = Int((coverage * Double(count)).rounded())
                return GlyphEdgeEvidence(edge: edge, samples: (0..<count).map {
                    $0 < litCount ? 0.18 + random.unit() : 0.17 * random.unit()
                })
            }
            var kind: ShapeEvidence.Kind = [.unrecognizedStroke, .unexplainedInk, .ambiguousShape,
                                            .uniqueVisibleShape][random.next(below: 4)]
            var evidence: [GlyphEdgeEvidence] = []
            let attemptSlot = max(0, cursor - (script.isEmpty ? 1 : 0))
            switch drawing {
            case .clear:
                kind = .noStroke
            case .target:
                let edges = target(attemptSlot) ?? []
                evidence = elementary.filter { edges.contains($0) }.map { lit($0, 1) }
            case .other(let name):
                let edges = recognizer.expectedEdges(for: name) ?? []
                evidence = elementary.filter { edges.contains($0) }.map { lit($0, 1) }
            case .partial(let missing, let coverage):
                let edges = target(attemptSlot) ?? []
                evidence = elementary.filter { edges.contains($0) }.map { lit($0, $0 == missing ? coverage : 1) }
            case .stray:
                evidence = elementary.filter { _ in random.chance(0.12) }.map { lit($0, random.unit()) }
            case .inkOnly:
                evidence = elementary.filter { _ in random.chance(0.1) }.map { lit($0, random.unit() * 0.7) }
            }
            if random.chance(0.005) { kind = .unavailable }

            let frame = FrameEvidence(
                sessionID: random.chance(0.997) ? session : CaptureSessionID(rawValue: 4), time: stamp, header: nil,
                slots: strip, shape: ShapeEvidence(kind: kind, glyph: nil, edges: [], extensions: []),
                hasValidCalibration: random.chance(0.995))

            let a: [InputCheckEvent], b: [InputCheckEvent]
            if random.chance(0.002) {
                a = swift.finish(at: time)
                b = cxx.finish(at: time)
            } else {
                a = swift.accept(frame, context: context, edgeEvidence: evidence)
                b = cxx.accept(frame, context: context, edgeEvidence: evidence)
            }
            Self.expectSame(a, b, "seed \(seed) step \(step)")
            Self.expectSame(swift, cxx, "seed \(seed) step \(step)")
            compared += 1
            for event in a {
                tally["\(event.kind) \(event.result?.verdict.rawValue ?? "") \(event.reason?.rawValue ?? "")", default: 0] += 1
            }
        }
        Self.expectSame(swift.finish(at: time), cxx.finish(at: time), "seed \(seed) final")
        Self.expectSame(swift, cxx, "seed \(seed) final")
        #expect(compared == 2_000)
        // The walk reaches the verdicts, not only the refusals.
        #expect(tally.keys.contains { $0.hasPrefix("finished matched") }, "\(tally)")
        #expect(tally.keys.contains { $0.hasPrefix("verdict") }, "\(tally)")
    }
}

/// A small seeded generator, so a failing walk can be replayed exactly.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}
