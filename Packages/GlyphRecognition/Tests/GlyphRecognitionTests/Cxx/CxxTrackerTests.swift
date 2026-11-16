import CoreGraphics
import Foundation
import Testing
import Vision
import GlyphCoreCxx
import GlyphRecognitionCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

// The C++ presentation tracker and header matcher held to the Swift oracle:
// every scenario of PresentationTrackerTests, SequenceOwnershipTests and
// OverlayEvidenceTests, a seeded random walk, and every header line set of the
// phrase tests, through both arms with the same inputs.

// MARK: - Both arms side by side

/// `a == b`, with NaN equal to NaN: both arms carry a non-finite time the
/// same way, and that is what is compared.
private func same(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
private func same(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return same(x, y)
    default: return false
    }
}

private func same(_ a: TrackingEvent, _ b: TrackingEvent) -> Bool {
    a.kind == b.kind && same(a.time, b.time) && a.hackID == b.hackID && a.slotIndex == b.slotIndex
        && a.glyph == b.glyph && a.reason == b.reason && a.sampleCount == b.sampleCount
}

private func same(_ a: SlotObservation, _ b: SlotObservation) -> Bool {
    a.index == b.index && a.status == b.status && a.glyph == b.glyph && a.alternatives == b.alternatives
        && same(a.firstSampleTime, b.firstSampleTime) && same(a.lastSampleTime, b.lastSampleTime)
        && a.sampleCount == b.sampleCount && a.boundaryReason == b.boundaryReason
}

/// The Swift tracker and the C++ tracker, given the same calls and compared
/// after every one: the events returned and every property the app reads.
private final class TrackerPair {
    private(set) var swift: PresentationTracker
    let cxx: CxxPresentationTracker
    let name: String
    private(set) var comparisons = 0
    private(set) var kinds: [TrackingEvent.Kind: Int] = [:]
    private var issues = 0

    init(_ name: String, session: CaptureSessionID, policy: PresentationTracker.Policy = PresentationTracker.Policy(),
         glyphs: [GlyphID]) {
        self.name = name
        swift = PresentationTracker(sessionID: session, policy: policy)
        cxx = CxxPresentationTracker(sessionID: session, policy: policy, glyphs: glyphs)
        compare("created", events: [], [], sourceLocation: #_sourceLocation)
    }

    @discardableResult
    func accept(_ evidence: FrameEvidence, sourceLocation: SourceLocation = #_sourceLocation) -> [TrackingEvent] {
        let expected = swift.accept(evidence)
        let actual = cxx.accept(evidence)
        for event in expected { kinds[event.kind, default: 0] += 1 }
        compare("accept at \(evidence.time)", events: expected, actual, sourceLocation: sourceLocation)
        return expected
    }

    func invalidatePhase(sourceLocation: SourceLocation = #_sourceLocation) {
        swift.invalidatePhase()
        cxx.invalidatePhase()
        compare("invalidatePhase", events: [], [], sourceLocation: sourceLocation)
    }

    func reset(sourceLocation: SourceLocation = #_sourceLocation) {
        swift.reset()
        cxx.reset()
        compare("reset", events: [], [], sourceLocation: sourceLocation)
    }

    private func compare(_ step: String, events expected: [TrackingEvent], _ actual: [TrackingEvent],
                         sourceLocation: SourceLocation) {
        comparisons += 1
        var differences: [String] = []
        if expected.count != actual.count || !zip(expected, actual).allSatisfy(same) {
            differences.append("events\n  swift: \(expected)\n  cxx:   \(actual)")
        }
        func check<T: Equatable>(_ label: String, _ a: T, _ b: T) {
            if a != b { differences.append("\(label): swift \(a), cxx \(b)") }
        }
        check("policy", swift.policy, cxx.policy)
        check("state", swift.state, cxx.state)
        check("phaseSource", swift.phaseSource, cxx.phaseSource)
        check("hackID", swift.hackID, cxx.hackID)
        check("revision", swift.revision, cxx.revision)
        if !same(swift.lastEvidenceTime, cxx.lastEvidenceTime) {
            differences.append("lastEvidenceTime: swift \(String(describing: swift.lastEvidenceTime)), cxx \(String(describing: cxx.lastEvidenceTime))")
        }
        if !same(swift.lastPhaseTime, cxx.lastPhaseTime) {
            differences.append("lastPhaseTime: swift \(String(describing: swift.lastPhaseTime)), cxx \(String(describing: cxx.lastPhaseTime))")
        }
        if !same(swift.lastIndicatorTime, cxx.lastIndicatorTime) {
            differences.append("lastIndicatorTime: swift \(String(describing: swift.lastIndicatorTime)), cxx \(String(describing: cxx.lastIndicatorTime))")
        }
        check("expectedSlotCount", swift.expectedSlotCount, cxx.expectedSlotCount)
        check("currentSlotIndex", swift.currentSlotIndex, cxx.currentSlotIndex)
        check("inputSlotIndex", swift.inputSlotIndex, cxx.inputSlotIndex)
        check("indicatorsObstructed", swift.indicatorsObstructed, cxx.indicatorsObstructed)
        check("slotCountConflict", swift.slotCountConflict, cxx.slotCountConflict)
        check("isFrozen", swift.isFrozen, cxx.isFrozen)
        check("observedPresentationForCurrentHack", swift.observedPresentationForCurrentHack,
              cxx.observedPresentationForCurrentHack)
        check("confirmedPrefix", swift.confirmedPrefix, cxx.confirmedPrefix)
        let swiftSlots = swift.slots, cxxSlots = cxx.slots
        if swiftSlots.count != cxxSlots.count || !zip(swiftSlots, cxxSlots).allSatisfy(same) {
            differences.append("slots\n  swift: \(swiftSlots)\n  cxx:   \(cxxSlots)")
        }
        guard !differences.isEmpty else { return }
        issues += 1
        // The first few differences say what went wrong; the rest follow from them.
        guard issues <= 3 else { return }
        Issue.record(Comment(rawValue: "\(name), comparison \(comparisons) (\(step)):\n"
                                 + differences.joined(separator: "\n")),
                     sourceLocation: sourceLocation)
    }
}

/// The oracle tests' `Feed`, driving both arms.
private struct Feed {
    let pair: TrackerPair
    let session: CaptureSessionID
    let table: GlyphTable?
    let includesExtensions: Bool
    var time = 100.0
    var events: [TrackingEvent] = []

    init(_ name: String, table: GlyphTable?, session: CaptureSessionID = CaptureSessionID(rawValue: 1),
         policy: PresentationTracker.Policy = PresentationTracker.Policy(), includesExtensions: Bool = true) {
        self.table = table
        self.session = session
        self.includesExtensions = includesExtensions
        pair = TrackerPair(name, session: session, policy: policy, glyphs: table?.glyphs ?? [])
    }

    private func shape(_ name: String?) -> ShapeEvidence {
        guard let name, let table, let path = table.path(for: GlyphID(name)) else {
            return ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: [])
        }
        let edges = GlyphGeometry.normalizedEdges(path.undirectedEdges)
        let extensions = includesExtensions ? table.glyphs.filter {
            guard let other = table.path(for: $0) else { return false }
            return edges.isStrictSubset(of: GlyphGeometry.normalizedEdges(other.undirectedEdges))
        } : []
        return ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name), edges: edges, extensions: extensions)
    }

    @discardableResult
    mutating func step(_ phase: GamePhase?, slots: Int? = nil, highlight: Int? = nil,
                       glyph: String? = nil, timerBar: Bool = false,
                       calibrated: Bool = true,
                       after gap: Double = 0.05, headerLag: Double = 0,
                       from other: CaptureSessionID? = nil,
                       partial: PartialSlotStripReading? = nil, partialTimer: Bool = false,
                       rejection: SlotStripRejection? = nil, centers: [Double]? = nil, partlyCovered: Bool = false,
                       sourceLocation: SourceLocation = #_sourceLocation) -> [TrackingEvent] {
        time += gap
        let reading = slots.map { count in
            SlotStripReading(slotCount: count, highlightedIndex: highlight,
                             markerCentersX: centers ?? (0..<count).map { (Double($0) + 0.5) / Double(count) },
                             hasInputTimerBar: timerBar, isPartlyCovered: partlyCovered)
        }
        let produced = pair.accept(FrameEvidence(
            sessionID: other ?? session, time: time,
            header: phase.map { HeaderReading(phase: $0, matchedText: $0.rawValue, confidence: 0.9,
                                              sourceTime: time - headerLag) },
            slots: reading,
            slotRejection: reading == nil ? rejection ?? (partial != nil || partialTimer ? .incompleteStrip : nil) : nil,
            shape: shape(glyph), hasValidCalibration: calibrated, hasInputTimerBar: timerBar,
            partialSlots: partial, hasPartialInputTimerBar: partialTimer), sourceLocation: sourceLocation)
        events += produced
        return produced
    }

    mutating func hold(_ count: Int, _ phase: GamePhase?, slots: Int? = nil, highlight: Int? = nil,
                       glyph: String? = nil, timerBar: Bool = false,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        for _ in 0..<count {
            step(phase, slots: slots, highlight: highlight, glyph: glyph, timerBar: timerBar,
                 sourceLocation: sourceLocation)
        }
    }

    func count(_ kind: TrackingEvent.Kind) -> Int { events.filter { $0.kind == kind }.count }
}

// MARK: - Oracle scenarios

@Suite("C++ logic: presentation tracker", .serialized)
struct CxxTrackerTests {
    @Test("PresentationTrackerPhaseEpochTests: rewinds and explicit epochs")
    func phaseEpochs() throws {
        let table = GlyphTable(entries: [GlyphID("change"): try #require(GlyphPath(encoded: "038"))])
        var scenarios = 0
        do {
            var f = Feed("rewindPhaseOwnership", table: table)
            f.step(.command)
            f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            f.time = 0.95
            f.step(nil, calibrated: false)
            f.step(.presenting, calibrated: false)
            f.step(nil, calibrated: false)
            f.step(nil, calibrated: false, after: 0.8)
            scenarios += 1
        }
        do {
            var f = Feed("explicitEpochPreservesCommittedSequence", table: table)
            f.step(.command)
            f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            f.pair.invalidatePhase()
            f.step(nil, calibrated: false, after: 50)
            scenarios += 1
        }
        #expect(scenarios == 2)
    }

    @Test("PresentationTrackerTests: every scenario", .enabled(if: ReferenceData.shapesAvailable))
    func presentationTracker() throws {
        let table = try ReferenceData.glyphTable()
        func feed(_ name: String, policy: PresentationTracker.Policy = PresentationTracker.Policy()) -> Feed {
            Feed(name, table: table, policy: policy)
        }
        var scenarios = 0

        do {
            var f = feed("redoLastSlotGuidance")
            let names = ["shapers", "see", "complex", "path", "destiny"]
            for (index, name) in names.enumerated() { f.hold(4, .presenting, slots: 5, highlight: index, glyph: name) }
            f.step(nil, slots: 5, highlight: 0, timerBar: true)
            for index in [0, 1, 2, 3, 2, 3, 4] {
                for _ in 0..<20 { f.step(nil, slots: 5, highlight: index, glyph: names[index], timerBar: true) }
            }
            f.step(.completed)
            scenarios += 1
        }
        do {
            _ = feed("nothingObserved")
            scenarios += 1
        }
        do {
            var f = feed("commandShapesIgnored")
            f.hold(8, .command, glyph: "see")
            scenarios += 1
        }
        do {
            var f = feed("noBoundaryNoCommit")
            f.step(.command)
            f.hold(10, .presenting, slots: 4, highlight: 0, glyph: "change")
            scenarios += 1
        }
        for (short, long) in [("see", "advance"), ("all", "clear_all")] {
            var f = feed("growingPrefixes \(short)")
            f.step(.command)
            f.hold(3, .presenting, slots: 2, highlight: 0, glyph: short)
            f.hold(3, .presenting, slots: 2, highlight: 0, glyph: long)
            f.hold(2, .presenting, slots: 2, highlight: 1)
            #expect(f.pair.cxx.slots.first?.glyph?.name == long)
            scenarios += 1
        }
        do {
            var f = feed("shortGlyphWithExtensions")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "see")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            scenarios += 1
        }
        do {
            var f = feed("repeatedFramesAreOneEntry")
            f.step(.command)
            f.hold(20, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            scenarios += 1
        }
        do {
            var f = feed("repeatedGlyphKeepsBothSlots")
            f.step(.command)
            let presented = ["see", "truth", "see", "future", "begin"]
            for (index, name) in presented.enumerated() {
                f.hold(2, .presenting, slots: 5, highlight: index)
                f.hold(6, .presenting, slots: 5, highlight: index, glyph: name)
            }
            f.hold(3, .input, slots: 5, highlight: 0, timerBar: true)
            #expect(f.pair.cxx.slots.map { $0.glyph?.name } == presented)
            scenarios += 1
        }
        do {
            var f = feed("missedMiddleSlot")
            f.step(.command)
            f.hold(6, .presenting, slots: 4, highlight: 0, glyph: "change")
            f.hold(6, .presenting, slots: 4, highlight: 1)
            f.hold(6, .presenting, slots: 4, highlight: 2, glyph: "begin")
            f.hold(6, .presenting, slots: 4, highlight: 3, glyph: "new")
            f.hold(2, .input, slots: 4, highlight: 0, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("conflictingShapesAbstain")
            f.step(.command)
            f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "future")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            #expect(f.count(.slotUncertain) == 1)
            scenarios += 1
        }
        do {
            var f = feed("inputDoesNotOverwrite")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
            f.hold(10, .input, slots: 2, highlight: 0, glyph: "future")
            f.hold(10, .input, slots: 2, highlight: 1, glyph: "truth")
            scenarios += 1
        }
        do {
            var f = feed("newHackResetsOnce")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(4, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
            f.hold(3, .completed)
            f.hold(4, .command)
            f.hold(6, .presenting, slots: 3, highlight: 0, glyph: "see")
            // The command channel discards the finished hack's sequence by name.
            #expect(f.events.contains { $0.reason == "command channel opened; discarded change,perspective" })
            scenarios += 1
        }
        do {
            var f = feed("staleSessionRejected")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            let events = f.step(.presenting, slots: 2, highlight: 1, glyph: "truth", from: CaptureSessionID(rawValue: 99))
            #expect(events.map(\.reason) == ["evidence from capture session 99"])
            scenarios += 1
        }
        do {
            var gapped = feed("discontinuitiesInvalidate gap")
            gapped.step(.command)
            gapped.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            gapped.step(.presenting, slots: 2, highlight: 0, glyph: "change", after: 3.0)
            gapped.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
            gapped.hold(2, .presenting, slots: 2, highlight: 1)
            #expect(gapped.events.contains { $0.reason == "frame gap of 3.000 s" })
            scenarios += 1

            var rotated = feed("discontinuitiesInvalidate rotation")
            rotated.step(.command)
            rotated.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            rotated.hold(6, .presenting, slots: 2, highlight: 0)
            rotated.step(.presenting, slots: 2, highlight: 0, glyph: "truth", calibrated: false)
            rotated.hold(2, .presenting, slots: 2, highlight: 1)
            scenarios += 1
        }
        do {
            var f = feed("unreadableHeader")
            f.step(.command)
            f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(3, nil, slots: 2, highlight: 0, glyph: "change")
            f.step(nil, slots: 2, highlight: 0, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("lastSlotAcrossHeaderGap")
            f.step(.command)
            func present(_ count: Int, highlight: Int?, glyph: String?) {
                for _ in 0..<count { f.step(.presenting, slots: 2, highlight: highlight, glyph: glyph, headerLag: 0.3) }
            }
            present(6, highlight: 0, glyph: "change")
            present(6, highlight: 1, glyph: "perspective")
            present(2, highlight: 1, glyph: nil)
            present(2, highlight: nil, glyph: nil)
            f.hold(10, .unknown, slots: 2)
            f.hold(2, .input, slots: 2, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("lastSlotWithHeaderCovered")
            f.hold(3, nil, slots: 3)
            f.hold(6, nil, slots: 3, highlight: 0, glyph: "change")
            f.hold(2, nil, slots: 3, highlight: 0)
            f.hold(6, nil, slots: 3, highlight: 1, glyph: "perspective")
            f.hold(2, nil, slots: 3, highlight: 1)
            f.hold(6, nil, slots: 3, highlight: 2, glyph: "truth")
            f.hold(2, nil, slots: 3, highlight: 2)
            f.hold(12, nil, slots: 3)
            f.hold(3, nil, slots: 3, timerBar: true)
            f.hold(3, nil, slots: 3, highlight: 0, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("missedCountdownDoesNotReusePreviousAnswer")
            f.hold(3, nil, slots: 2)
            f.hold(5, nil, slots: 2, highlight: 0, glyph: "change")
            f.hold(5, nil, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(3, nil, slots: 2)
            f.hold(60, nil)
            f.hold(3, nil, slots: 2)
            f.step(nil, slots: 2, highlight: 0, glyph: "truth")
            f.hold(4, nil, slots: 2, highlight: 0, glyph: "truth")
            f.hold(4, nil, slots: 2, highlight: 1, glyph: "see")
            f.hold(2, nil, slots: 2)
            scenarios += 1
        }
        do {
            var f = feed("tailFlickerIsNotANewHack")
            f.hold(3, nil, slots: 2)
            f.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, nil, slots: 2, highlight: 0)
            f.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, nil, slots: 2, highlight: 1)
            f.hold(4, nil, slots: 2)
            f.step(nil)
            f.hold(6, nil, slots: 2)
            f.hold(4, nil, slots: 2, highlight: 0, glyph: "truth")
            f.hold(4, nil, slots: 2, highlight: 1, glyph: "see")
            f.hold(2, nil, slots: 2)
            scenarios += 1
        }
        do {
            var f = feed("interruptedMidSlotResumes")
            f.hold(3, nil, slots: 2)
            f.hold(5, nil, slots: 2, highlight: 0, glyph: "change")
            f.step(nil, after: 2)
            f.hold(5, .presenting, slots: 2, highlight: 1, glyph: "truth")
            scenarios += 1
        }
        do {
            var policy = PresentationTracker.Policy()
            policy.entersPresentationFromIndicators = false
            var f = feed("indicatorPresentationDisabled", policy: policy)
            f.hold(3, nil, slots: 3)
            f.hold(6, nil, slots: 3, highlight: 0, glyph: "change")
            f.hold(2, nil, slots: 3, highlight: 0)
            f.hold(6, nil, slots: 3, highlight: 1, glyph: "perspective")
            scenarios += 1
        }
        do {
            var policy = PresentationTracker.Policy()
            policy.closesLastSlotOnRelease = false
            var f = feed("lastSlotReleaseDisabled", policy: policy)
            f.hold(3, nil, slots: 2)
            f.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, nil, slots: 2, highlight: 0)
            f.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, nil, slots: 2, highlight: 1)
            f.hold(12, nil, slots: 2)
            f.hold(3, nil, slots: 2, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("releasedTailIsNotAPrelude")
            f.hold(3, nil, slots: 2)
            f.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
            f.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, nil, slots: 2, highlight: 1)
            f.hold(12, nil, slots: 2)
            f.hold(3, nil, slots: 2, highlight: 0)
            scenarios += 1
        }
        do {
            var drawing = feed("releasedHighlightGuards drawing")
            drawing.step(.command)
            drawing.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            drawing.hold(3, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            drawing.hold(3, .presenting, slots: 2, glyph: "perspective")
            scenarios += 1

            var early = feed("releasedHighlightGuards early")
            early.step(.command)
            early.hold(6, .presenting, slots: 3, highlight: 0, glyph: "change")
            early.hold(4, .presenting, slots: 3)
            scenarios += 1

            var empty = feed("releasedHighlightGuards empty")
            empty.step(.command)
            empty.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            empty.hold(1, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            empty.hold(4, .presenting, slots: 2)
            scenarios += 1
        }
        for lag in [0, 0.6] {
            var f = feed("laggingHeader \(lag)")
            f.step(.presenting, slots: 2, highlight: 0, headerLag: lag)
            f.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
            scenarios += 1
        }
        do {
            var f = feed("longUnreadableHeader")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            f.hold(20, nil, slots: 2, highlight: 1, glyph: "truth")
            f.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("slotCountConflict")
            f.step(.command)
            f.hold(6, .presenting, slots: 4, highlight: 0, glyph: "change")
            f.hold(4, .presenting, slots: 5, highlight: 0)
            #expect(f.events.contains { $0.reason == "counts 4/5" })
            scenarios += 1
        }
        do {
            var f = feed("joinLate")
            f.hold(6, .presenting, slots: 4, highlight: 2, glyph: "begin")
            f.hold(6, .presenting, slots: 4, highlight: 3, glyph: "new")
            f.hold(2, .input, slots: 4, highlight: 0, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("indicatorsCovered")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            f.hold(12, .presenting, slots: nil)
            f.hold(2, .presenting, slots: 2, highlight: 1)
            scenarios += 1
        }
        do {
            var f = feed("inputHighlightBumpsRevision")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
            f.step(.input, slots: 2, highlight: 1, timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("resetClearsEverything")
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            f.pair.reset()
            // And it keeps working afterwards, with the hack count carried on.
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "see")
            f.hold(2, .presenting, slots: 2, highlight: 1)
            scenarios += 1
        }
        #expect(scenarios == 36)
    }

    @Test("ObscuredIndicatorTests: every scenario", .enabled(if: ReferenceData.shapesAvailable))
    func obscuredIndicators() throws {
        let table = try ReferenceData.glyphTable()
        func feed(_ name: String) -> Feed { Feed(name, table: table) }
        var scenarios = 0
        do {
            var f = feed("textFallback")
            f.hold(4, .presenting, glyph: "see")
            f.hold(4, .presenting)
            scenarios += 1
        }
        do {
            var f = feed("growingAndRepeatedShapes")
            for _ in 0..<2 {
                f.hold(3, .presenting, glyph: "see")
                f.hold(3, .presenting, glyph: "advance")
                f.hold(2, .presenting)
            }
            scenarios += 1
        }
        do {
            var f = feed("refusesFalseBoundaries")
            f.hold(3, .presenting, glyph: "see")
            f.step(.presenting)
            f.hold(3, .presenting, glyph: "advance")
            f.hold(3, .presenting, glyph: "all")
            f.hold(4, .presenting)
            scenarios += 1
        }
        do {
            var f = feed("restoredAnchor")
            f.hold(3, .presenting, glyph: "see")
            f.hold(4, .presenting)
            f.hold(3, .presenting, glyph: "advance")
            f.hold(3, .presenting, slots: 4, highlight: 2, glyph: "all")
            f.step(.presenting, slots: 4, highlight: 3)
            scenarios += 1
        }
        do {
            var f = feed("independentTimer")
            f.hold(3, .presenting, glyph: "see")
            f.step(.presenting, glyph: "all", timerBar: true, headerLag: 0.2)
            f.hold(10, nil, glyph: "advance", timerBar: true)
            scenarios += 1
        }
        do {
            var f = feed("timerCannotPromotePartialShape")
            f.hold(3, .presenting, slots: 2, highlight: 0, glyph: "see")
            f.step(nil, glyph: "advance", timerBar: true)
            scenarios += 1
        }
        for phase in [GamePhase.command, .input, .unknown] {
            var f = feed("fallbackGates \(phase)")
            f.hold(4, phase, glyph: "see")
            f.hold(4, phase)
            scenarios += 1
        }
        do {
            var f = feed("fallbackGates stale text")
            for _ in 0..<4 { f.step(.presenting, glyph: "see", headerLag: 3) }
            scenarios += 1
        }
        do {
            var f = feed("gapBreaksContinuity")
            f.hold(3, .presenting, glyph: "see")
            f.step(.presenting, after: 2)
            f.hold(4, .presenting)
            scenarios += 1
        }
        do {
            var f = feed("boundedFallback")
            for _ in 0..<10 {
                f.hold(3, .presenting, glyph: "see")
                f.hold(4, .presenting)
            }
            #expect(f.pair.cxx.slots.count == SequenceTable.maximumLength)
            scenarios += 1
        }
        #expect(scenarios == 12)
    }

    @Test("InputHighlightHysteresisTests: every scenario")
    func inputHighlightHysteresis() {
        // `Strip` in the oracle: a three-slot presentation, then input on a slot.
        func inInput(_ name: String, on inputSlot: Int) -> Feed {
            var f = Feed(name, table: nil)
            f.step(.command, slots: 3, highlight: nil)
            for index in 0..<3 { f.hold(6, .presenting, slots: 3, highlight: index) }
            f.hold(4, .input, slots: 3, highlight: inputSlot, timerBar: true)
            return f
        }
        var single = inInput("singleFrameDropoutHeld", on: 1)
        single.step(.input, slots: 3, highlight: nil, timerBar: true)
        single.step(.input, slots: 3, highlight: 1, timerBar: true)
        single.hold(5, .input, slots: 3, highlight: nil, timerBar: true)
        single.step(.input, slots: 3, highlight: 2, timerBar: true)

        var long = inInput("longDropoutClears", on: 0)
        let grace = long.pair.swift.policy.indicatorObstructionGrace
        long.hold(Int((grace / 0.05).rounded(.down)) - 1, .input, slots: 3, highlight: nil, timerBar: true)
        long.hold(3, .input, slots: 3, highlight: nil, timerBar: true)
        long.step(.input, slots: 3, highlight: 1, timerBar: true)

        var leaving = inInput("leavingInputClears", on: 2)
        leaving.step(.input, slots: 3, highlight: nil, timerBar: true)
        leaving.step(.completed, slots: 3, highlight: nil)
        #expect(leaving.pair.cxx.state == .completed)
    }

    // MARK: Our own window's lower edge across the strip

    @Test("A hack read below our own window's lower edge is tracked once, from presentation to input")
    func windowLowerEdgeHack() throws {
        // A field report whose frames show the row below the window, replayed
        // at 20 frames/s, with five Glyphs of a synthetic table: the window's
        // lower edge lies across the strip and the header throughout, so no
        // header is read, and the row below it reads only from the
        // presentation to the end of input.
        var entries: [GlyphID: GlyphPath] = [:]
        let names = ["g1", "g2", "g3", "g4", "g5"]
        for (name, encoded) in zip(names, ["16a", "347", "1367", "8630", "5475"]) {
            entries[GlyphID(name)] = try #require(GlyphPath(encoded: encoded))
        }
        var f = Feed("windowLowerEdgeHack", table: GlyphTable(entries: entries))
        let centres = [0.1799, 0.3400, 0.5000, 0.6592, 0.8192]
        func row(_ count: Int, _ highlight: Int?, glyph: String? = nil, timer: Bool = false) {
            for _ in 0..<count {
                f.step(nil, slots: 5, highlight: highlight, glyph: glyph, timerBar: timer, centers: centres,
                       partlyCovered: true)
            }
        }
        func covered(_ count: Int, calibrated: Bool) {
            for _ in 0..<count { f.step(nil, calibrated: calibrated, rejection: .coveredByOverlay) }
        }
        // The map, the command screen and the strip's rows covered before
        // the row is drawn (0 to 7.7 s).
        for _ in 0..<34 { f.step(nil, calibrated: false) }
        covered(20, calibrated: true)
        covered(33, calibrated: true)
        #expect(f.count(.hackStarted) == 0 && f.pair.swift.state == .inactive)
        // The presentation (7.75 to 10.75 s).
        row(9, nil)
        for (index, name) in names.enumerated() { row(8, index, glyph: name) }
        row(11, nil)
        #expect(f.count(.hackStarted) == 1 && f.pair.swift.state == .presenting)
        #expect(f.events.filter { $0.kind == .slotCommitted }.map { $0.glyph?.name } == names)
        // Input with the countdown (10.8 to 18.5 s).
        row(3, nil, timer: true)
        #expect(f.pair.swift.state == .input && f.pair.swift.phaseSource == .inputTimer)
        #expect(f.count(.sequenceFrozen) == 1)
        for (index, frames) in [17, 17, 18, 21, 78].enumerated() {
            row(frames, index, timer: true)
            #expect(f.pair.swift.inputSlotIndex == index)
        }
        #expect(!f.pair.swift.indicatorsObstructed)
        // "Glyph hack complete", the result panel under the window, the map.
        covered(27, calibrated: true)
        covered(40, calibrated: false)
        for _ in 0..<160 { f.step(nil, calibrated: false) }
        #expect(f.count(.hackStarted) == 1 && f.pair.swift.hackID == 1)
        #expect(f.pair.swift.slots.map { $0.glyph?.name } == names)
        #expect(!f.events.contains { $0.kind == .evidenceInvalidated || $0.kind == .slotCountConflict })
    }

    // MARK: Our own window over the strip

    /// The indicators of a four-slot row that show beside our own window over
    /// its right half, as the reader gives them.
    private static func beside(highlight: Int?) -> PartialSlotStripReading {
        PartialSlotStripReading(markerCentersX: [0.2595, 0.4196], highlightedMarker: highlight,
                                coveredFrom: 306.0 / 603, coveredTo: 1)
    }

    /// A four-slot presentation and the start of input on slot 0, then the
    /// window moved over the strip's right half.
    private func coveredInput(_ name: String) -> Feed {
        var f = Feed(name, table: nil)
        f.step(.command)
        for index in 0..<4 { f.hold(6, .presenting, slots: 4, highlight: index) }
        f.hold(4, .input, slots: 4, highlight: 0, timerBar: true)
        return f
    }

    @Test("The countdown beside our own window holds input, and the visible highlight is tracked")
    func windowCoverHoldsInput() {
        var f = coveredInput("windowCoverHoldsInput")
        let hack = f.pair.swift.hackID
        let slots = f.pair.swift.slots
        // As in a field report: the header goes unreadable and the
        // full strip with it; the countdown runs on beside the window for 7 s.
        for _ in 0..<32 { f.step(nil, partial: Self.beside(highlight: 0), partialTimer: true) }
        #expect(f.pair.swift.state == .input && f.pair.swift.phaseSource == .partialInputTimer)
        #expect(f.pair.swift.inputSlotIndex == 0)
        for _ in 0..<20 { f.step(nil, partial: Self.beside(highlight: 1), partialTimer: true) }
        #expect(f.pair.swift.inputSlotIndex == 1)
        // The highlight moved under the window: unknown, not held on slot 1.
        f.step(nil, partial: Self.beside(highlight: nil), partialTimer: true)
        #expect(f.pair.swift.state == .input && f.pair.swift.inputSlotIndex == nil)
        for _ in 0..<87 { f.step(nil, partial: Self.beside(highlight: nil), partialTimer: true) }
        #expect(f.pair.swift.state == .input && f.pair.swift.inputSlotIndex == nil)
        // The obstruction stays: no full strip, so no input verdicts.
        #expect(f.pair.swift.indicatorsObstructed)
        // The countdown is gone: input ends within the grace of the last one.
        let lastRail = f.time
        var left: Double?
        for _ in 0..<30 {
            f.step(nil)
            if left == nil, f.pair.swift.state != .input { left = f.time }
        }
        let grace = f.pair.swift.policy.unknownPhaseGrace
        #expect(left.map { $0 - lastRail <= grace + 0.05 + 1e-9 } == true)
        #expect(f.pair.swift.state == .interrupted)
        // The result: one hack, its presented slots untouched by the hold.
        f.step(.completed)
        #expect(f.pair.swift.state == .completed && f.pair.swift.hackID == hack)
        #expect(f.pair.swift.slots == slots)
        #expect(f.count(.hackStarted) == 1 && f.count(.hackCompleted) == 1)
        #expect(!f.events.contains { $0.kind == .evidenceInvalidated || $0.kind == .slotCountConflict })
    }

    @Test("The countdown beside our own window starts and resumes nothing")
    func windowCoverStartsNothing() {
        // No hack at all.
        var idle = Feed("windowCoverBeforeAnyHack", table: nil)
        for _ in 0..<10 { idle.step(nil, partial: Self.beside(highlight: 0), partialTimer: true) }
        #expect(idle.pair.swift.state == .inactive && idle.pair.swift.hackID == 0)

        // Input interrupted before the window covered the strip stays interrupted.
        var interrupted = coveredInput("windowCoverAfterInterruption")
        for _ in 0..<20 { interrupted.step(nil) }
        #expect(interrupted.pair.swift.state == .interrupted)
        for _ in 0..<10 { interrupted.step(nil, partial: Self.beside(highlight: 0), partialTimer: true) }
        #expect(interrupted.pair.swift.state == .interrupted && interrupted.pair.swift.inputSlotIndex == nil)

        // The presentation is not input, whatever shows beside the window.
        var presenting = Feed("windowCoverDuringPresentation", table: nil)
        presenting.step(.command)
        presenting.hold(6, .presenting, slots: 4, highlight: 0)
        for _ in 0..<10 { presenting.step(nil, partial: Self.beside(highlight: 1), partialTimer: true) }
        #expect(presenting.pair.swift.state == .presenting && presenting.count(.sequenceFrozen) == 0)

        // Without a valid fit, or beside a completed hack, it holds nothing.
        var uncalibrated = coveredInput("windowCoverWithoutCalibration")
        for _ in 0..<20 { uncalibrated.step(nil, calibrated: false, partial: Self.beside(highlight: 0), partialTimer: true) }
        #expect(uncalibrated.pair.swift.state == .interrupted)
        var completed = coveredInput("windowCoverAfterCompletion")
        completed.step(.completed)
        for _ in 0..<10 { completed.step(nil, partial: Self.beside(highlight: 0), partialTimer: true) }
        #expect(completed.pair.swift.state == .completed)
    }

    @Test("A header naming another phase ends the hold beside our own window",
          arguments: [GamePhase.completed, .command, .presenting])
    func windowCoverYieldsToHeaders(phase: GamePhase) {
        var f = coveredInput("windowCoverYieldsTo\(phase.rawValue)")
        for _ in 0..<10 { f.step(nil, partial: Self.beside(highlight: 1), partialTimer: true) }
        #expect(f.pair.swift.state == .input)
        f.step(phase, partial: Self.beside(highlight: 1), partialTimer: true)
        #expect(f.pair.swift.state.rawValue == phase.rawValue)
        #expect(f.pair.swift.inputSlotIndex == nil)
        // A new presentation is a new hack, not this one's input.
        #expect(f.count(.hackStarted) == (phase == .presenting ? 2 : 1))
    }

    @Test("Beside our own window, a highlight that fits no known row is not placed")
    func windowCoverUnplacedHighlight() {
        // The row's count is proven at four; markers off its grid place nothing.
        var f = coveredInput("windowCoverOffGrid")
        let offGrid = PartialSlotStripReading(markerCentersX: [0.30, 0.46], highlightedMarker: 0,
                                              coveredFrom: 0.5, coveredTo: 1)
        for _ in 0..<5 { f.step(nil, partial: offGrid, partialTimer: true) }
        #expect(f.pair.swift.state == .input && f.pair.swift.inputSlotIndex == nil)
        // Without the countdown, the visible highlight alone places nothing.
        f.step(nil, partial: Self.beside(highlight: 0), partialTimer: true)
        #expect(f.pair.swift.inputSlotIndex == 0)
        f.step(nil, partial: Self.beside(highlight: 0))
        #expect(f.pair.swift.inputSlotIndex == nil)
    }

    @Test("The C resolution of indicators beside the window matches Swift's")
    func partialResolution() {
        var rng = SplitMix64(seed: 11)
        let pitch = GameUILayout().slotCenterPitch
        var resolved = 0
        for _ in 0..<4_000 {
            func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < probability }
            let slotCount = chance(0.9) ? Int.random(in: 1...5, using: &rng) : Int.random(in: -1...6, using: &rng)
            // A row of `drawn` slots, seen beside a window over one side,
            // read against `slotCount`: mostly the same count, on the grid.
            let drawn = chance(0.8) ? max(1, min(5, slotCount)) : Int.random(in: 1...5, using: &rng)
            func center(_ index: Int) -> Double { 0.5 + (Double(index) - Double(drawn - 1) / 2) * pitch }
            let visible = Int.random(in: 0...drawn, using: &rng)
            let right = chance(0.5)
            let shown = right ? Array(0..<visible) : Array((drawn - visible)..<drawn)
            let jitter = chance(0.8) ? 0.02 : 0.06
            let centers = shown.map { center($0) + Double.random(in: -jitter...jitter, using: &rng) }
            let markerCount = centers.count
            var edge = right ? (visible < drawn ? center(visible) - pitch / 2 : 1)
                             : (visible < drawn ? center(drawn - visible - 1) + pitch / 2 : 0)
            if chance(0.2) { edge += Double.random(in: -0.2...0.2, using: &rng) }
            let highlight = chance(0.4) ? nil : Int.random(in: -1...markerCount, using: &rng)
            let partial = PartialSlotStripReading(markerCentersX: centers, highlightedMarker: highlight,
                                                  coveredFrom: right ? edge : 0, coveredTo: right ? 1 : edge)
            let swift = partial.resolved(slotCount: slotCount)
            var reading = gl_partial_slot_reading()
            reading.markerCount = Int32(markerCount)
            reading.highlightedMarker = gc_opt_int32(has: highlight != nil, value: Int32(highlight ?? 0))
            reading.coveredFrom = partial.coveredFrom
            reading.coveredTo = partial.coveredTo
            reading.centerPitch = partial.centerPitch
            reading.centerTolerance = partial.centerTolerance
            var indices = [Int32](repeating: -1, count: max(1, markerCount))
            var highlighted = gc_opt_int32()
            let ok = centers.withUnsafeBufferPointer { buffer in
                reading.markerCentersX = buffer.baseAddress
                return indices.withUnsafeMutableBufferPointer {
                    gl_partial_slot_resolve(&reading, Int32(slotCount), $0.baseAddress, &highlighted)
                }
            }
            #expect(ok == (swift != nil), "\(partial) in \(slotCount)")
            guard let swift, ok else { continue }
            resolved += 1
            #expect(indices.prefix(markerCount).map(Int.init) == swift.slotIndices)
            #expect((highlighted.has ? Int(highlighted.value) : nil) == swift.highlightedIndex)
        }
        #expect(resolved > 100)
    }

    @Test("SequenceOwnershipTests: every scenario", .enabled(if: ReferenceData.shapesAvailable))
    func sequenceOwnership() throws {
        let table = try ReferenceData.glyphTable()
        do {
            var f = Feed("missedPresentationDoesNotInherit", table: table, includesExtensions: false)
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            f.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
            f.hold(3, .input, slots: 2, highlight: 0, timerBar: true)
            f.hold(3, .completed)
            f.hold(3, .command)
            f.hold(3, .input, slots: 4, highlight: 0, timerBar: true)
            #expect(f.pair.cxx.slots.compactMap(\.glyph).isEmpty)
        }
        do {
            var f = Feed("timerBarBeatsStaleHeader", table: table, includesExtensions: false)
            f.step(.command)
            f.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
            for _ in 0..<6 {
                f.step(.presenting, slots: 2, highlight: 0, glyph: "future", timerBar: true, headerLag: 0.3)
            }
            #expect(f.pair.cxx.state == .input)
        }
    }

    @Test("Edge cases: stale sessions, backwards and non-finite times, gaps, invalidation and reset")
    func edgeCases() throws {
        let table = GlyphTable(entries: [
            GlyphID("a"): try #require(GlyphPath(encoded: "01")),
            GlyphID("b"): try #require(GlyphPath(encoded: "015")),
            GlyphID("c"): try #require(GlyphPath(encoded: "0156")),
            GlyphID("d"): try #require(GlyphPath(encoded: "38")),
        ])
        var f = Feed("edge cases", table: table)
        f.step(.command)
        f.hold(4, .presenting, slots: 3, highlight: 0, glyph: "a")
        f.hold(4, .presenting, slots: 3, highlight: 0, glyph: "b")
        f.hold(4, .presenting, slots: 3, highlight: 0, glyph: "c")
        f.hold(2, .presenting, slots: 3, highlight: 1)
        #expect(f.events.contains { $0.reason.hasSuffix("; grew through 3 nested shapes") })
        f.step(.presenting, slots: 3, highlight: 1, glyph: "d", from: CaptureSessionID(rawValue: UInt64.max))
        // Gaps whose length must be printed to the millisecond.
        f.step(.presenting, slots: 3, highlight: 1, glyph: "d", after: 1.0005)
        f.step(.presenting, slots: 3, highlight: 1, glyph: "d", after: 2.3456)
        f.step(.presenting, slots: 3, highlight: 1, glyph: "d", after: 12345.6789)
        #expect(f.events.contains { $0.reason == "frame gap of 2.346 s" })
        // Backwards, then the same time twice.
        f.step(.presenting, slots: 3, highlight: 2, glyph: "a", after: -0.5)
        f.step(.presenting, slots: 3, highlight: 2, glyph: "a", after: 0)
        f.step(.presenting, slots: 3, highlight: 2, glyph: "a", after: 0)
        f.pair.invalidatePhase()
        f.hold(3, nil, slots: 3, highlight: 2, glyph: "a")
        f.hold(3, .presenting, slots: 3, highlight: 2, glyph: "a")
        f.hold(3, .presenting, slots: 3, highlight: 1, glyph: "a")
        // A header from the future, and one too old to count.
        f.step(.input, slots: 3, highlight: 0, headerLag: -0.1)
        f.step(.input, slots: 3, highlight: 0, headerLag: 0.76)
        // Non-finite source times.
        f.time = .infinity
        f.step(.presenting, slots: 3, highlight: 0, glyph: "a", after: 0)
        f.time = 10
        f.step(.presenting, slots: 3, highlight: 0, glyph: "a", after: 0)
        f.time = -.infinity
        f.step(.presenting, slots: 3, highlight: 0, glyph: "a", after: 0)
        f.time = 20
        f.step(.presenting, slots: 3, highlight: 0, glyph: "a", after: 0)
        f.time = .nan
        f.step(.presenting, slots: 3, highlight: 0, glyph: "b", after: 0)
        f.step(.presenting, slots: 3, highlight: 1, glyph: "b", after: 0)
        f.time = 30
        f.hold(3, .presenting, slots: 3, highlight: 1, glyph: "c")
        f.pair.reset()
        f.pair.reset()
        f.pair.invalidatePhase()
        f.hold(3, .command)
        f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "d")
        f.hold(4, .presenting, slots: 2, highlight: 1, glyph: "c")
        f.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
        f.hold(2, .completed)
        f.hold(2, .command)
    }

    // MARK: - OverlayEvidenceTests

    private let overlaySession = CaptureSessionID(rawValue: 42)

    private func band(_ name: String = "Phases/field-00443.png") throws -> FrameTopBand {
        let image = try #require(ImageDecoder.cgImage(from: Data(contentsOf:
            ReferenceData.fixturesDirectory.appendingPathComponent(name))))
        return try ImageDecoder.topBand(image)
    }

    private func cover(_ band: FrameTopBand, x: Int, y: Int, width: Int, height: Int,
                       pixels cover: [UInt8]) throws -> FrameTopBand {
        var pixels = band.image.pixels
        for row in 0..<height where y + row >= 0 && y + row < band.image.height {
            for column in 0..<width where x + column >= 0 && x + column < band.image.width {
                let offset = ((y + row) * band.image.width + x + column) * 3
                let source = (row * width + column) * 3
                pixels.replaceSubrange(offset..<(offset + 3), with: cover[source..<(source + 3)])
            }
        }
        return FrameTopBand(image: try ColorImage(width: band.image.width, height: band.image.height,
                                                  pixels: pixels), frameHeight: band.frameHeight)
    }

    private func pip(width: Int, height: Int, tone: StatusTone) throws -> [UInt8] {
        let table = try GlyphTable.parse(csv: "test,03\n")
        let state: TrackingState = switch tone {
        case .idle: .inactive
        case .drawing: .input
        case .done: .completed
        case .warning, .tentative, .collecting: .presenting
        }
        let snapshot = GlyphDisplaySnapshot(captureSessionID: overlaySession, hackID: 1, revision: 1,
            liveness: .live, state: state, phaseSource: .headerText, acceptance: .trackingSequence,
            sourceFrameTime: 1, evidenceArrivalUptime: 10, expectedSlotCount: nil,
            slots: tone == .tentative ? [SlotObservation(index: 0, status: .inferred, glyph: GlyphID("test"))] : [],
            currentSlotIndex: nil, inputSlotIndex: nil, indicatorsObstructed: tone == .warning,
            slotCountConflict: false, isFrozen: false, provisionalGlyph: nil,
            provisionalExtensionCount: 0, outlook: .unavailable, calibrationSummary: "11 rings")
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        GlyphDisplayRenderer(table: table).draw(snapshot, in: context,
            size: CGSize(width: width, height: height), atUptime: 10, windowCornerRadius: 13.5)
        return try ImageDecoder.decodeColor(#require(context.makeImage()),
            in: CGRect(x: 0, y: 0, width: width, height: height)).pixels
    }

    private func evidence(_ band: FrameTopBand, at time: Double) -> FrameEvidence {
        let reader = SlotStripReader()
        let result = reader.read(band)
        return FrameEvidence(sessionID: overlaySession, time: time,
            header: HeaderReading(phase: .presenting, matchedText: "incoming glyph sequence",
                                  confidence: 1, sourceTime: time),
            slots: try? result.get(),
            shape: ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
            hasValidCalibration: true, hasInputTimerBar: reader.hasTimerBar(band))
    }

    private func covered(at time: Double, shape: ShapeEvidence.Kind, calibrated: Bool = true) -> FrameEvidence {
        FrameEvidence(sessionID: overlaySession, time: time, header: nil, slots: nil,
                      slotRejection: .coveredByOverlay,
                      shape: ShapeEvidence(kind: shape, glyph: shape == .uniqueVisibleShape ? GlyphID("test") : nil,
                                           edges: [], extensions: []),
                      hasValidCalibration: calibrated)
    }

    @Test("OverlayEvidenceTests: a PiP edge over the timer region", arguments: [StatusTone.tentative, .warning])
    func pipIsNotCountdown(tone: StatusTone) throws {
        let original = try band()
        for height in [71, 142] {
            let coveredBand = try cover(original, x: 10, y: 302 - height, width: 284, height: height,
                                        pixels: pip(width: 284, height: height, tone: tone))
            let pair = TrackerPair("pipIsNotCountdown \(tone) \(height)", session: overlaySession, glyphs: [])
            for index in 0..<3 { pair.accept(evidence(original, at: 1 + Double(index) * 0.05)) }
            pair.accept(evidence(coveredBand, at: 1.15))
            #expect(pair.cxx.state == .presenting)
        }
    }

    @Test("OverlayEvidenceTests: an opaque notification over the indicators", arguments: [0, 300])
    func missingWholeIndicators(left: Int) throws {
        let coveredBand = try cover(band(), x: left, y: 135, width: 303, height: 100,
                                    pixels: Array(repeating: 24, count: 303 * 100 * 3))
        let pair = TrackerPair("missingWholeIndicators \(left)", session: overlaySession, glyphs: [])
        for index in 0..<3 { pair.accept(evidence(coveredBand, at: 1 + Double(index) * 0.05)) }
        #expect(pair.cxx.indicatorsObstructed)
    }

    @Test("OverlayEvidenceTests: a window over the strip before any hack")
    func coveredBeforeAnyHack() {
        let pair = TrackerPair("coveredBeforeAnyHack", session: overlaySession, glyphs: [GlyphID("test")])
        let kinds: [ShapeEvidence.Kind] = [.noStroke, .noStroke, .uniqueVisibleShape, .uniqueVisibleShape,
                                           .unrecognizedStroke, .noStroke, .unrecognizedStroke, .noStroke]
        for (index, kind) in kinds.enumerated() { pair.accept(covered(at: 1 + Double(index) * 0.1, shape: kind)) }
        pair.accept(FrameEvidence(sessionID: overlaySession, time: 2, header: nil, slots: nil,
                                  slotRejection: .noMarkers,
                                  shape: ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
                                  hasValidCalibration: true))
        #expect(!pair.cxx.indicatorsObstructed)
    }

    @Test("OverlayEvidenceTests: a remembered calibration away from the Glyph screen", arguments: [true, false])
    func coveredAwayFromTheGlyphScreen(calibrated: Bool) {
        let pair = TrackerPair("coveredAwayFromTheGlyphScreen \(calibrated)", session: overlaySession,
                               glyphs: [GlyphID("test")])
        for index in 0..<20 {
            let kind: ShapeEvidence.Kind = index % 2 == 0 ? .unexplainedInk : .unrecognizedStroke
            pair.accept(covered(at: 1 + Double(index) * 0.1, shape: kind, calibrated: calibrated))
        }
        if !calibrated {
            for index in 0..<20 {
                pair.accept(covered(at: 5 + Double(index) * 0.1, shape: .noStroke, calibrated: false))
            }
        }
        #expect(!pair.cxx.indicatorsObstructed)
    }

    // MARK: - Seeded random walk

    @Test("A seeded random walk of 2,000 frames compares equal after every step", arguments: [UInt64(1), 2, 3])
    func randomWalk(seed: UInt64) throws {
        let table = ReferenceData.shapesAvailable ? try ReferenceData.glyphTable() : try Self.syntheticTable()
        var walk = RandomWalk(seed: seed, table: table)
        let pair = TrackerPair("random walk seed \(seed)", session: walk.session, glyphs: table.glyphs)
        var held = 0
        for _ in 0..<2_000 {
            switch walk.operation() {
            case .accept(let evidence): pair.accept(evidence)
            case .invalidatePhase: pair.invalidatePhase()
            case .reset: pair.reset()
            }
            if pair.swift.phaseSource == .partialInputTimer { held += 1 }
        }
        #expect(held > 0, "seed \(seed) never held input beside the window")
        // The walk must reach the rules that matter, not only the idle ones.
        for kind: TrackingEvent.Kind in [.phaseChanged, .hackStarted, .slotAdvanced, .slotCommitted, .slotMissing,
                                         .evidenceInvalidated, .sequenceFrozen, .hackCompleted,
                                         .staleEvidenceRejected] {
            #expect(pair.kinds[kind, default: 0] > 0, "seed \(seed) never produced \(kind): \(pair.kinds)")
        }
        #expect(pair.comparisons > 2_000)
    }

    private static func syntheticTable() throws -> GlyphTable {
        var entries: [GlyphID: GlyphPath] = [:]
        for (name, encoded) in [("see", "01"), ("advance", "015"), ("all", "0156"), ("clear_all", "01568"),
                                ("change", "038"), ("future", "27"), ("truth", "4a9"), ("new", "236"),
                                ("begin", "8a9"), ("perspective", "1357")] {
            entries[GlyphID(name)] = try #require(GlyphPath(encoded: encoded))
        }
        return GlyphTable(entries: entries)
    }

    // MARK: - Header phrase matcher

    private func compareMatchers(_ swift: HeaderPhraseMatcher, _ cxx: CxxHeaderPhraseMatcher,
                                 _ lines: [(text: String, confidence: Double)], _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = swift.read(lines: lines)
        let actual = cxx.read(lines: lines)
        #expect(expected == actual, "\(label): \(lines)", sourceLocation: sourceLocation)
    }

    @Test("HeaderPhraseTests: every line set, on the default English matcher")
    func headerPhraseTests() {
        let swift = HeaderPhraseMatcher()
        let cxx = CxxHeaderPhraseMatcher()
        let singles = ["Command channel open…", "Incoming glyph sequence", "GO!", "Glyph hack complete",
                       "COMMAND  CHANNEL   OPEN...", "DRONE FOOTAGE", "Garden Exhibit", "+448 AP", "RECALL", "16:84",
                       "", "go to the portal", "Incoming glyph"]
        for text in singles { compareMatchers(swift, cxx, [(text, 0.9)], "single") }
        compareMatchers(swift, cxx, [("Incoming glyph sequence", 0.2)], "low confidence")
        compareMatchers(swift, cxx, [("Incoming glyph sequence", 0.9), ("GO!", 0.95)], "conflict")
        compareMatchers(swift, cxx, [], "no lines")
    }

    @Test("GameTextTests: headers in every language")
    func gameTextHeaders() {
        let samples: [(GameLanguage, String)] = [
            (.simplifiedChinese, "命令频道正在打开…"), (.simplifiedChinese, "正在接收符文序列…"),
            (.simplifiedChinese, "开始！"), (.simplifiedChinese, "符文入侵完成"),
            (.traditionalChinese, "開啟指令頻道…"), (.traditionalChinese, "正在接收 GLYPH 序列…"),
            (.japanese, "コマンドチャンネルを開いています..."), (.japanese, "グリフを受信中…"),
            (.japanese, "Go!"), (.japanese, "ハック完了。ボーナスを計算中…"),
            (.korean, "명령 채널 열림…"), (.korean, "해킹 완료. 보너스 계산 중..."),
        ]
        for (language, text) in samples {
            let swift = HeaderPhraseMatcher(language: language)
            let cxx = CxxHeaderPhraseMatcher(language: language)
            compareMatchers(swift, cxx, [(text, 1)], "\(language)")
            compareMatchers(swift, cxx, [("开始 Glyph Hack", 1)], "\(language)")
        }
    }

    @Test("Every phrase of every language pack, written as the game and OCR write it",
          arguments: GameLanguage.allCases)
    func everyPhrase(language: GameLanguage) {
        let swift = HeaderPhraseMatcher(language: language)
        let cxx = CxxHeaderPhraseMatcher(language: language)
        let phrases = GameText(language).headerPhrases
        var lines: [String] = []
        for phrase in phrases {
            let spaced = phrase.words.joined(separator: " ")
            let run = phrase.words.joined()
            lines += [spaced, run, spaced.uppercased(), "\(spaced)…", "\(spaced)!", "  \(spaced)  ",
                      "\(spaced) extra", "prefix \(spaced)", "\(run)。", "（\(run)）", "\(run)：完成",
                      phrase.words.map { $0.uppercased() }.joined(separator: "   "),
                      phrase.words.dropLast().joined(separator: " ")]
        }
        lines += ["", " ", "…", "!!!", "12 34", "ー", "・"]
        for line in lines {
            for confidence in [0.0, 0.29, 0.3, 0.35, 0.5, 1.0] {
                compareMatchers(swift, cxx, [(line, confidence)], "\(language)")
            }
        }
        // Pairs of lines: the same phase agrees, different phases conflict,
        // and the most confident hit gives the text.
        for first in lines.prefix(40) {
            for second in lines.suffix(40) {
                compareMatchers(swift, cxx, [(first, 0.8), (second, 0.9)], "\(language) pair")
                compareMatchers(swift, cxx, [(first, 0.9), (second, 0.9)], "\(language) tie")
            }
        }
    }

    @Test("Random header lines built from the phrase vocabulary", arguments: GameLanguage.allCases)
    func randomLines(language: GameLanguage) {
        let swift = HeaderPhraseMatcher(language: language)
        let cxx = CxxHeaderPhraseMatcher(language: language)
        var vocabulary = GameText(language).headerPhrases.flatMap(\.words)
        vocabulary += vocabulary.map { $0.uppercased() }
        vocabulary += ["glyph", "hack", "go", "Go", "GO", "portal", "AP", "16", "开", "始", "受信", "ー", "ハック"]
        let separators = [" ", "  ", "", "…", "!", "。", "、", "：", "-", "...", "·", "\t", "\n"]
        var generator = SplitMix64(seed: UInt64(language.rawValue.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) }))
        for _ in 0..<600 {
            var lines: [(text: String, confidence: Double)] = []
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                var text = ""
                for _ in 0..<Int.random(in: 0...5, using: &generator) {
                    text += vocabulary.randomElement(using: &generator) ?? ""
                    text += separators.randomElement(using: &generator) ?? ""
                }
                lines.append((text, [0.2, 0.3, 0.35, 0.5, 0.9, 1].randomElement(using: &generator) ?? 1))
            }
            compareMatchers(swift, cxx, lines, "\(language) random")
        }
    }

    @Test("Custom phrase lists, including degenerate ones")
    func customPhrases() {
        let phrases: [HeaderPhraseMatcher.Phrase] = [
            .init(phase: .command, words: ["a", "b"]),
            .init(phase: .presenting, words: ["b", "c"], requiresExactMatch: true),
            .init(phase: .input, words: ["cd"], matchesWithin: true),
            .init(phase: .completed, words: ["x", "y", "z"], requiresExactMatch: true, matchesWithin: true),
        ]
        let swift = HeaderPhraseMatcher(phrases: phrases, minimumConfidence: 0.5)
        let cxx = CxxHeaderPhraseMatcher(phrases: phrases, minimumConfidence: 0.5)
        for text in ["a b", "A, B!", "b c", "b c d", "abcd", "a b c d", "x y z", "xyz", "c d", "q a b", "ab"] {
            for confidence in [0.49, 0.5, 0.9] {
                compareMatchers(swift, cxx, [(text, confidence)], "custom")
            }
        }
        compareMatchers(swift, cxx, [("a b", 0.6), ("a b c", 0.7)], "custom same phase")
        compareMatchers(swift, cxx, [("a b", 0.6), ("b c", 0.7)], "custom conflict")
        compareMatchers(HeaderPhraseMatcher(phrases: []), CxxHeaderPhraseMatcher(phrases: []),
                        [("anything", 1)], "no phrases")
    }

    @Test("PhaseDetectionTests: the lines Vision reads from every phase fixture, in every language")
    func visionLines() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let directory = try ReferenceData.fixturesDirectory.appendingPathComponent("Phases")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        let recognizer = HeaderTextRecognizer()
        let matchers = GameLanguage.allCases.map { (HeaderPhraseMatcher(language: $0), CxxHeaderPhraseMatcher(language: $0)) }
        let english = (HeaderPhraseMatcher(), CxxHeaderPhraseMatcher())
        var phases: Set<GamePhase> = []
        for file in files {
            let image = try #require(ImageDecoder.cgImage(from: Data(contentsOf: file)))
            for crop in [recognizer.headerCrop(of: image),
                         image.cropping(to: CGRect(x: 0, y: Double(image.height) * 0.35, width: Double(image.width),
                                                   height: Double(image.height) * 0.1))].compactMap({ $0 }) {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = false
                request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
                let observations = try await request.perform(on: crop)
                let lines: [(text: String, confidence: Double)] = observations.compactMap { observation in
                    guard let best = observation.topCandidates(1).first else { return nil }
                    return (best.string, Double(best.confidence))
                }
                phases.insert(english.0.read(lines: lines).phase)
                compareMatchers(english.0, english.1, lines, file.lastPathComponent)
                for (swift, cxx) in matchers { compareMatchers(swift, cxx, lines, file.lastPathComponent) }
            }
        }
        // The fixtures name every phase, so the matcher's hits were compared,
        // not only its refusals.
        #expect(phases.isSuperset(of: [.command, .presenting, .input, .completed, .unknown]))
    }
}

// MARK: - Random evidence

/// SplitMix64: a small, fixed generator, so a seed names one walk forever.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A plausible capture with noise: a scene that moves through command,
/// presentation, input and completion, read through unreliable headers and
/// strips, with gaps, rewinds, other sessions, invalidations and resets.
private struct RandomWalk {
    enum Operation {
        case accept(FrameEvidence)
        case invalidatePhase
        case reset
    }

    let session = CaptureSessionID(rawValue: 7)
    private var rng: SplitMix64
    /// Our own window beside the strip draws from its own generator, so the
    /// rest of the walk is the one it was before the window existed.
    private var coverRng: SplitMix64
    private let glyphs: [GlyphID]
    private let shapes: [GlyphID: ShapeEvidence]
    private var time = 50.0
    private var scene: GamePhase = .command
    private var slotCount = 3
    private var highlight: Int?
    private var glyph: GlyphID?

    init(seed: UInt64, table: GlyphTable) {
        rng = SplitMix64(seed: seed)
        coverRng = SplitMix64(seed: seed &+ 0x5EED)
        var chosen = table.glyphs.filter { ["see", "advance", "all", "clear_all", "change", "perspective"].contains($0.name) }
        var others = table.glyphs.filter { !chosen.contains($0) }
        others.shuffle(using: &rng)
        chosen += others.prefix(8)
        glyphs = chosen
        var shapes: [GlyphID: ShapeEvidence] = [:]
        for id in chosen {
            guard let path = table.path(for: id) else { continue }
            let edges = GlyphGeometry.normalizedEdges(path.undirectedEdges)
            let extensions = table.glyphs.filter {
                guard let other = table.path(for: $0) else { return false }
                return edges.isStrictSubset(of: GlyphGeometry.normalizedEdges(other.undirectedEdges))
            }
            shapes[id] = ShapeEvidence(kind: .uniqueVisibleShape, glyph: id, edges: edges, extensions: extensions)
        }
        self.shapes = shapes
    }

    private mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < probability }

    mutating func operation() -> Operation {
        if chance(0.005) { return .invalidatePhase }
        if chance(0.002) { return .reset }
        advanceScene()
        return .accept(frame())
    }

    private mutating func advanceScene() {
        let order: [GamePhase] = [.command, .presenting, .input, .completed]
        let dwell: Double = scene == .presenting ? 0.025 : 0.06
        if chance(dwell) {
            if chance(0.85), let index = order.firstIndex(of: scene) {
                scene = order[(index + 1) % order.count]
            } else {
                scene = GamePhase.allCases.randomElement(using: &rng) ?? .unknown
            }
            if scene == .presenting {
                slotCount = Int.random(in: 1...5, using: &rng)
                highlight = nil
                glyph = nil
            }
            if scene == .input { highlight = 0 }
        }
        switch scene {
        case .presenting:
            if chance(0.12) {
                if let current = highlight {
                    highlight = current + 1 < slotCount ? current + 1 : (chance(0.5) ? nil : current)
                } else {
                    highlight = 0
                }
                glyph = nil
            } else if chance(0.02), let current = highlight, current > 0 {
                highlight = current - 1
            }
            if chance(0.25) { glyph = chance(0.7) ? glyphs.randomElement(using: &rng) : nil }
        case .input:
            if chance(0.1) { highlight = Int.random(in: 0..<slotCount, using: &rng) }
            if chance(0.05) { highlight = nil }
            if chance(0.2) { glyph = chance(0.5) ? glyphs.randomElement(using: &rng) : nil }
        default:
            if chance(0.2) { glyph = chance(0.3) ? glyphs.randomElement(using: &rng) : nil }
        }
    }

    private mutating func frame() -> FrameEvidence {
        let roll = Double.random(in: 0..<1, using: &rng)
        switch roll {
        case ..<0.88: time += Double.random(in: 0.03...0.07, using: &rng)
        case ..<0.91: break
        case ..<0.94: time += Double.random(in: 0.8...3.0, using: &rng)
        case ..<0.96: time -= Double.random(in: 0.01...2.0, using: &rng)
        default: time += Double.random(in: 0.3...0.8, using: &rng)
        }
        let sessionID = chance(0.02) ? CaptureSessionID(rawValue: 8) : session

        var header: HeaderReading?
        if chance(0.7) {
            let phase = chance(0.1) ? (GamePhase.allCases.randomElement(using: &rng) ?? .unknown) : scene
            let lag: Double
            switch Double.random(in: 0..<1, using: &rng) {
            case ..<0.75: lag = 0
            case ..<0.95: lag = Double.random(in: 0...0.9, using: &rng)
            default: lag = -Double.random(in: 0...0.2, using: &rng)
            }
            header = HeaderReading(phase: phase, matchedText: phase.rawValue, confidence: 0.9, sourceTime: time - lag)
        }

        let stripShown = scene == .presenting || scene == .input
        var slots: SlotStripReading?
        var rejection: SlotStripRejection?
        if chance(stripShown ? 0.8 : 0.15) {
            let count = chance(0.04) ? Int.random(in: 1...5, using: &rng) : slotCount
            var shown = highlight.flatMap { $0 < count ? $0 : nil }
            if chance(0.05) { shown = chance(0.5) ? nil : Int.random(in: 0..<count, using: &rng) }
            let jitter = chance(0.1) ? 0.03 : 0.004
            let centers = (0..<count).map { (Double($0) + 0.5) / Double(count) + Double.random(in: -jitter...jitter, using: &rng) }
            let timer = scene == .input ? chance(0.7) : chance(0.04)
            slots = SlotStripReading(slotCount: count, highlightedIndex: shown, markerCentersX: centers,
                                     hasInputTimerBar: timer, isPartlyCovered: chance(0.1))
        } else if chance(0.7) {
            rejection = chance(0.35) ? .coveredByOverlay : [SlotStripRejection.bandUnavailable, .noMarkers,
                .tooManyMarkers, .unevenSpacing, .inconsistentMarkerWidths, .multipleHighlights,
                .incompleteMarkerHeight, .incompleteStrip].randomElement(using: &rng)
        }

        let shape: ShapeEvidence
        let otherKinds: [ShapeEvidence.Kind] = [.unavailable, .unrecognizedStroke, .unexplainedInk, .ambiguousShape]
        if let glyph, let visible = shapes[glyph], chance(0.75) {
            shape = visible
        } else if glyph == nil, chance(0.65) {
            shape = ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: [])
        } else if chance(0.1), let any = glyphs.randomElement(using: &rng), let visible = shapes[any] {
            shape = visible
        } else {
            shape = ShapeEvidence(kind: otherKinds.randomElement(using: &rng) ?? .unavailable, glyph: nil,
                                  edges: [], extensions: [])
        }
        let calibrated = chance(0.92)
        let timer = chance(0.04)
        let (partial, partialTimer) = slots == nil ? besideWindow() : (nil, false)
        return FrameEvidence(sessionID: sessionID, time: time, header: header, slots: slots, slotRejection: rejection,
                             shape: shape, hasValidCalibration: calibrated, hasInputTimerBar: timer,
                             partialSlots: partial, hasPartialInputTimerBar: partialTimer)
    }

    /// What shows beside our own window over one side of the strip: mostly
    /// during input, on the row's grid, sometimes off it or out of place.
    private mutating func besideWindow() -> (PartialSlotStripReading?, Bool) {
        func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &coverRng) < probability }
        guard chance(scene == .input ? 0.6 : 0.05) else { return (nil, false) }
        let timer = chance(scene == .input ? 0.8 : 0.3)
        guard slotCount >= 2, chance(0.85) else { return (nil, timer) }
        let count = chance(0.05) ? Int.random(in: 2...5, using: &coverRng) : slotCount
        let visible = Int.random(in: 1..<count, using: &coverRng)
        let pitch = GameUILayout().slotCenterPitch
        func center(_ index: Int) -> Double { 0.5 + (Double(index) - Double(count - 1) / 2) * pitch }
        let right = chance(0.5)
        let shown = right ? Array(0..<visible) : Array((count - visible)..<count)
        let jitter = chance(0.1) ? 0.05 : 0.01
        let centers = shown.map { center($0) + Double.random(in: -jitter...jitter, using: &coverRng) }
        var marker = highlight.flatMap { shown.firstIndex(of: $0) }
        if chance(0.05) { marker = Int.random(in: 0..<visible, using: &coverRng) }
        let edge = right ? (center(visible - 1) + center(visible)) / 2 : (center(count - visible - 1) + center(count - visible)) / 2
        return (PartialSlotStripReading(markerCentersX: centers, highlightedMarker: marker,
                                        coveredFrom: right ? edge : 0, coveredTo: right ? 1 : edge), timer)
    }
}
