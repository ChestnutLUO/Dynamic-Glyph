import Testing
@testable import GlyphRecognition

/// Feeds the tracker timestamped evidence directly.
///
/// No images, no text recognition and no clock, which is the point: every rule
/// that decides whether a Glyph joins the sequence can be staged exactly,
/// including the ones that are almost impossible to reproduce on a phone.
private struct Feed {
    var tracker: PresentationTracker
    let session: CaptureSessionID
    let table: GlyphTable
    var time = 100.0
    var events: [TrackingEvent] = []

    init(table: GlyphTable, session: CaptureSessionID = CaptureSessionID(rawValue: 1),
         policy: PresentationTracker.Policy = PresentationTracker.Policy()) {
        self.table = table
        self.session = session
        self.tracker = PresentationTracker(sessionID: session, policy: policy)
    }

    private func shape(_ name: String?) -> ShapeEvidence {
        guard let name, let path = table.path(for: GlyphID(name)) else {
            return ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: [])
        }
        let edges = GlyphGeometry.normalizedEdges(path.undirectedEdges)
        let extensions = table.glyphs.filter {
            guard let other = table.path(for: $0) else { return false }
            return edges.isStrictSubset(of: GlyphGeometry.normalizedEdges(other.undirectedEdges))
        }
        return ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name),
                             edges: edges, extensions: extensions)
    }

    @discardableResult
    mutating func step(_ phase: GamePhase?, slots: Int? = nil, highlight: Int? = nil,
                       glyph: String? = nil, timerBar: Bool = false,
                       calibrated: Bool = true,
                       after gap: Double = 0.05, headerLag: Double = 0,
                       from other: CaptureSessionID? = nil) -> [TrackingEvent] {
        time += gap
        let reading = slots.map { count in
            SlotStripReading(slotCount: count, highlightedIndex: highlight,
                             markerCentersX: (0..<count).map { (Double($0) + 0.5) / Double(count) },
                             hasInputTimerBar: timerBar)
        }
        let produced = tracker.accept(FrameEvidence(
            sessionID: other ?? session, time: time,
            header: phase.map { HeaderReading(phase: $0, matchedText: $0.rawValue, confidence: 0.9,
                                              sourceTime: time - headerLag) },
            slots: reading, shape: shape(glyph),
            hasValidCalibration: calibrated, hasInputTimerBar: timerBar))
        events += produced
        return produced
    }

    /// Holds one screen for several frames, which is what the game actually
    /// does: a presented shape is visible across five or six samples.
    mutating func hold(_ count: Int, _ phase: GamePhase?, slots: Int? = nil, highlight: Int? = nil,
                       glyph: String? = nil, timerBar: Bool = false) {
        for _ in 0..<count {
            step(phase, slots: slots, highlight: highlight, glyph: glyph, timerBar: timerBar)
        }
    }

    var committed: [String?] { tracker.slots.map { $0.glyph?.name } }
    var statuses: [SlotObservation.Status] { tracker.slots.map(\.status) }
    func count(_ kind: TrackingEvent.Kind) -> Int { events.filter { $0.kind == kind }.count }
}

@Suite("Presentation tracking phase epochs")
struct PresentationTrackerPhaseEpochTests {
    private func feed() throws -> Feed {
        let path = try #require(GlyphPath(encoded: "038"))
        return Feed(table: GlyphTable(entries: [GlyphID("change"): path]))
    }

    @Test("A rewind clears the future phase anchor while preserving committed slots and hack identity")
    func rewindPhaseOwnership() throws {
        var f = try feed()
        f.step(.command)
        f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
        f.hold(2, .presenting, slots: 2, highlight: 1)
        let committed = f.tracker.slots.filter { $0.status == .confirmed }
        let hackID = f.tracker.hackID
        #expect(!committed.isEmpty)
        #expect(committed.map { $0.glyph?.name } == ["change"])
        f.time = 0.95
        f.step(nil, calibrated: false)
        #expect(f.tracker.lastPhaseTime == nil)
        #expect(f.tracker.state == .interrupted && f.tracker.phaseSource == .none)
        #expect(f.tracker.hackID == hackID)
        #expect(f.tracker.slots.filter { $0.status == .confirmed } == committed)
        f.step(.presenting, calibrated: false)
        #expect(f.tracker.lastPhaseTime == f.time)
        #expect(f.time < 2)
        #expect(f.tracker.hackID == hackID)
        f.step(nil, calibrated: false)
        #expect(f.tracker.state == .presenting && f.tracker.phaseSource == .retained)
        f.step(nil, calibrated: false, after: 0.8)
        #expect(f.tracker.state == .interrupted)
        #expect(f.tracker.slots.filter { $0.status == .confirmed } == committed)
    }

    @Test("Explicit forward-epoch invalidation is phase-only, not a clean-slate reset")
    func explicitEpochPreservesCommittedSequence() throws {
        var f = try feed()
        f.step(.command)
        f.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
        f.hold(2, .presenting, slots: 2, highlight: 1)
        let slots = f.tracker.slots
        #expect(slots.filter { $0.status == .confirmed }.map { $0.glyph?.name } == ["change"])
        let hackID = f.tracker.hackID
        let revision = f.tracker.revision
        f.tracker.invalidatePhase()
        #expect(f.tracker.slots == slots && f.tracker.hackID == hackID)
        #expect(f.tracker.lastPhaseTime == nil && f.tracker.phaseSource == .none)
        #expect(f.tracker.state == .interrupted && f.tracker.revision > revision)
        f.step(nil, calibrated: false, after: 50)
        #expect(f.tracker.lastPhaseTime == nil)
        #expect(f.tracker.hackID == hackID)
        #expect(f.tracker.slots.filter { $0.status == .confirmed } == slots.filter { $0.status == .confirmed })
    }

}

@Suite("Presentation tracking", .enabled(if: ReferenceData.shapesAvailable))
struct PresentationTrackerTests {
    private func feed() throws -> Feed { Feed(table: try ReferenceData.glyphTable()) }

    @Test("Redo followed by a late countdown keeps fifth-slot guidance until completion")
    func redoLastSlotGuidance() throws {
        var f = try feed()
        let names = ["shapers", "see", "complex", "path", "destiny"]
        for (index, name) in names.enumerated() {
            f.hold(4, .presenting, slots: 5, highlight: index, glyph: name)
        }
        f.step(nil, slots: 5, highlight: 0, timerBar: true)
        let retained = f.tracker.slots
        let hackID = f.tracker.hackID
        // The field report returns from slot 4 to slot 3, redraws it, then
        // advances to slot 5. The timer, rather than header OCR, anchors input.
        for index in [0, 1, 2, 3, 2, 3, 4] {
            for _ in 0..<20 {
                f.step(nil, slots: 5, highlight: index, glyph: names[index], timerBar: true)
                #expect(f.tracker.state == .input)
                #expect(f.tracker.inputSlotIndex == index)
                #expect(f.tracker.slots == retained)
                #expect(f.tracker.hackID == hackID)
            }
        }
        let snapshot = GlyphDisplaySnapshot(captureSessionID: f.session, hackID: hackID,
            revision: f.tracker.revision, liveness: .live, state: f.tracker.state,
            phaseSource: f.tracker.phaseSource, acceptance: .trackingSequence,
            sourceFrameTime: f.time, evidenceArrivalUptime: f.time,
            expectedSlotCount: 5, slots: f.tracker.slots, currentSlotIndex: nil,
            inputSlotIndex: f.tracker.inputSlotIndex, inputSlotObservedTime: f.tracker.lastIndicatorTime,
            slotCountConflict: false, isFrozen: true, provisionalGlyph: nil,
            provisionalExtensionCount: 0, outlook: .unavailable, calibrationSummary: "test")
        #expect(snapshot.upcomingGuidance()?.firstSlotIndex == 4)
        #expect(snapshot.upcomingGuidance()?.styles.compactMap(\.glyph) == [GlyphID("destiny")])
        f.step(.completed)
        #expect(f.tracker.state == .completed)
        #expect(f.tracker.inputSlotIndex == nil)
    }

    @Test("With no evidence the tracker is waiting, not finished and not contradicted", .enabled(if: ReferenceData.sequencesAvailable))
    func nothingObserved() throws {
        let feed = try feed()
        #expect(feed.tracker.state == .inactive)
        #expect(feed.tracker.slots.isEmpty)
        #expect(feed.tracker.confirmedPrefix.isEmpty)
        #expect(feed.tracker.expectedSlotCount == nil)
        let outlook = SequencePredictor(table: try ReferenceData.sequenceTable())
            .outlook(observed: feed.tracker.confirmedPrefix)
        #expect(outlook.state == .unobserved)
    }

    @Test("Command-channel shapes never become sequence slots")
    func commandShapesIgnored() throws {
        var feed = try feed()
        feed.hold(8, .command, glyph: "see")
        #expect(feed.tracker.state == .command)
        #expect(feed.tracker.slots.isEmpty)
        #expect(feed.tracker.confirmedPrefix.isEmpty)
    }

    @Test("A stable shape with no boundary yet stays provisional")
    func noBoundaryNoCommit() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(10, .presenting, slots: 4, highlight: 0, glyph: "change")
        #expect(feed.tracker.state == .presenting)
        #expect(feed.tracker.slots[0].status == .observing)
        #expect(feed.tracker.confirmedPrefix.isEmpty)
        #expect(feed.count(.slotCommitted) == 0)
    }

    @Test("A prefix that grows into a longer Glyph is not committed as the prefix")
    func growingPrefixes() throws {
        for (short, long) in [("see", "advance"), ("all", "clear_all")] {
            var feed = try feed()
            feed.step(.command)
            feed.hold(3, .presenting, slots: 2, highlight: 0, glyph: short)
            #expect(feed.tracker.confirmedPrefix.isEmpty, "\(short) committed before the boundary")
            feed.hold(3, .presenting, slots: 2, highlight: 0, glyph: long)
            feed.hold(2, .presenting, slots: 2, highlight: 1)
            // Both shapes were stable inside one slot. They are nested, so the
            // completed drawing is the larger one.
            #expect(feed.committed == [long, nil], "\(short) -> \(long)")
            #expect(feed.tracker.slots[0].alternatives.map(\.name) == [short])
        }
    }

    @Test("A short Glyph that never grows is accepted at a verified boundary")
    func shortGlyphWithExtensions() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "see")
        // `see` is a strict prefix of `advance`; extensions alone cannot reject
        // a shape that held steady across an independently verified boundary.
        #expect(!feed.tracker.slots[0].alternatives.isEmpty == false)
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(feed.committed[0] == "see")
        #expect(feed.tracker.slots[0].sampleCount == 6)
    }

    @Test("Repeated frames of one held shape make one entry")
    func repeatedFramesAreOneEntry() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(20, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(feed.tracker.slots.filter { $0.status == .confirmed }.count == 1)
        #expect(feed.committed[0] == "change")
    }

    @Test("A Glyph presented twice keeps both slots")
    func repeatedGlyphKeepsBothSlots() throws {
        var feed = try feed()
        feed.step(.command)
        // The recording's real sequence: see, truth, see, future, begin.
        let presented = ["see", "truth", "see", "future", "begin"]
        for (index, name) in presented.enumerated() {
            feed.hold(2, .presenting, slots: 5, highlight: index)
            feed.hold(6, .presenting, slots: 5, highlight: index, glyph: name)
        }
        feed.hold(3, .input, slots: 5, highlight: 0, timerBar: true)
        #expect(feed.committed == presented)
        #expect(feed.tracker.expectedSlotCount == 5)
    }

    @Test("A missed slot keeps its place and the later Glyphs keep theirs")
    func missedMiddleSlot() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 4, highlight: 0, glyph: "change")
        // The second slot is on screen but nothing legible is drawn in it.
        feed.hold(6, .presenting, slots: 4, highlight: 1)
        feed.hold(6, .presenting, slots: 4, highlight: 2, glyph: "begin")
        feed.hold(6, .presenting, slots: 4, highlight: 3, glyph: "new")
        feed.hold(2, .input, slots: 4, highlight: 0, timerBar: true)
        #expect(feed.committed == ["change", nil, "begin", "new"])
        #expect(feed.statuses == [.confirmed, .missing, .confirmed, .confirmed])
        // Only the contiguous prefix may reach the predictor.
        #expect(feed.tracker.confirmedPrefix.map(\.name) == ["change"])
    }

    @Test("Two unrelated stable shapes in one slot leave it uncertain")
    func conflictingShapesAbstain() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(4, .presenting, slots: 2, highlight: 0, glyph: "future")
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(feed.tracker.slots[0].status == .uncertain)
        #expect(feed.tracker.slots[0].glyph == nil)
        #expect(feed.tracker.slots[0].alternatives.map(\.name) == ["change", "future"])
        let reason = try #require(feed.events.first { $0.kind == .slotUncertain }?.reason)
        #expect(reason.contains("unrelated stable shapes"))
    }

    @Test("Player strokes never change the presented sequence")
    func inputDoesNotOverwrite() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
        let frozen = feed.committed
        #expect(frozen == ["change", "perspective"])
        // The player now draws something else entirely, in both slots.
        feed.hold(10, .input, slots: 2, highlight: 0, glyph: "future")
        feed.hold(10, .input, slots: 2, highlight: 1, glyph: "truth")
        #expect(feed.committed == frozen)
        #expect(feed.tracker.isFrozen)
        #expect(feed.tracker.inputSlotIndex == 1)
    }

    @Test("A new hack resets the previous one exactly once")
    func newHackResetsOnce() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(4, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
        feed.hold(3, .completed)
        let firstHack = feed.tracker.hackID
        #expect(feed.committed == ["change", "perspective"])

        feed.hold(4, .command)
        feed.hold(6, .presenting, slots: 3, highlight: 0, glyph: "see")
        #expect(feed.tracker.hackID == firstHack + 1)
        #expect(feed.count(.hackStarted) == 2)
        #expect(feed.committed == [nil, nil, nil])
        #expect(feed.tracker.confirmedPrefix.isEmpty)
    }

    @Test("Evidence from another capture session is refused")
    func staleSessionRejected() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        let before = feed.tracker.revision
        let events = feed.step(.presenting, slots: 2, highlight: 1, glyph: "truth",
                               from: CaptureSessionID(rawValue: 99))
        #expect(events.map(\.kind) == [.staleEvidenceRejected])
        #expect(feed.tracker.revision == before)
        #expect(feed.tracker.confirmedPrefix.isEmpty)
        #expect(feed.tracker.slots[0].status == .observing)
    }

    @Test("A frame gap, a rotation and an overlay each stop evidence without inventing a boundary")
    func discontinuitiesInvalidate() throws {
        // A gap in the source timestamps.
        var gapped = try feed()
        gapped.step(.command)
        gapped.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        gapped.step(.presenting, slots: 2, highlight: 0, glyph: "change", after: 3.0)
        #expect(gapped.count(.slotCommitted) == 0)
        #expect(gapped.count(.evidenceInvalidated) >= 1)
        // The frames before the gap are gone: stability has to be re-earned
        // from frames that are known to be contiguous with each other.
        gapped.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
        gapped.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(gapped.committed[0] == "change")
        #expect(gapped.tracker.slots[0].sampleCount == 5)

        // Calibration lost, as after a rotation.
        var rotated = try feed()
        rotated.step(.command)
        rotated.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        rotated.hold(6, .presenting, slots: 2, highlight: 0)
        rotated.step(.presenting, slots: 2, highlight: 0, glyph: "truth", calibrated: false)
        rotated.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(rotated.committed[0] == "change")
    }

    @Test("A briefly unreadable header keeps the presentation, and the countdown bar ends it")
    func unreadableHeader() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(4, .presenting, slots: 2, highlight: 0, glyph: "change")
        // The header analysis misses a few frames; the shape is still collected.
        feed.hold(3, nil, slots: 2, highlight: 0, glyph: "change")
        #expect(feed.tracker.state == .presenting)
        #expect(feed.tracker.phaseSource == .retained)
        // The countdown bar appears while the header is still unread: player
        // input has begun, whatever the last header said.
        feed.step(nil, slots: 2, highlight: 0, timerBar: true)
        #expect(feed.tracker.state == .input)
        #expect(feed.committed[0] == "change")
        #expect(feed.tracker.isFrozen)
    }

    /// The end of the 2026-09-17 recording, at 20 Hz: the last Glyph is shown,
    /// the array clears, the last indicator loses its highlight, and then the
    /// header is unreadable for half a second before the countdown bar. On a
    /// phone the last header reading is older than the frame it is applied to,
    /// which is what `headerLag` stands for here; the grace then ran out in
    /// that gap and the last slot was thrown away, drawn as `?` for the whole
    /// of player input.
    @Test("The last Glyph survives an unreadable header before the countdown")
    func lastSlotAcrossHeaderGap() throws {
        var feed = try feed()
        feed.step(.command)
        // Every presentation frame carries a header read 0.3 s earlier.
        func present(_ count: Int, highlight: Int?, glyph: String?) {
            for _ in 0..<count {
                feed.step(.presenting, slots: 2, highlight: highlight, glyph: glyph, headerLag: 0.3)
            }
        }
        present(6, highlight: 0, glyph: "change")
        present(6, highlight: 1, glyph: "perspective")
        present(2, highlight: 1, glyph: nil)
        present(2, highlight: nil, glyph: nil)
        feed.hold(10, .unknown, slots: 2)
        feed.hold(2, .input, slots: 2, timerBar: true)
        #expect(feed.committed == ["change", "perspective"])
        #expect(feed.statuses == [.confirmed, .confirmed])
        #expect(feed.tracker.state == .input)
        #expect(feed.tracker.isFrozen)
    }

    /// The 2026-09-22 field run: the Picture in Picture window sat on the
    /// header, so the presentation was known only from the indicator strip.
    /// The last indicator's highlight dropping ended the phase on that frame,
    /// before the release could close the slot, and `body` was drawn as `?`
    /// for the whole of player input.
    @Test("With the header covered, the last Glyph survives its indicator being released")
    func lastSlotWithHeaderCovered() throws {
        var feed = try feed()
        feed.hold(3, nil, slots: 3)
        feed.hold(6, nil, slots: 3, highlight: 0, glyph: "change")
        feed.hold(2, nil, slots: 3, highlight: 0)
        feed.hold(6, nil, slots: 3, highlight: 1, glyph: "perspective")
        feed.hold(2, nil, slots: 3, highlight: 1)
        feed.hold(6, nil, slots: 3, highlight: 2, glyph: "truth")
        feed.hold(2, nil, slots: 3, highlight: 2)
        feed.hold(12, nil, slots: 3)
        #expect(feed.tracker.state == .presenting)
        #expect(feed.committed == ["change", "perspective", "truth"])
        // The countdown, then the game lighting slot 0 for the player.
        feed.hold(3, nil, slots: 3, timerBar: true)
        feed.hold(3, nil, slots: 3, highlight: 0, timerBar: true)
        #expect(feed.tracker.state == .input)
        #expect(feed.tracker.hackID == 1)
        #expect(feed.committed == ["change", "perspective", "truth"])
        #expect(feed.statuses == [.confirmed, .confirmed, .confirmed])
        #expect(feed.tracker.inputSlotIndex == 0)
    }

    @Test("A fresh strip prelude separates same-length hacks when the countdown was missed")
    func missedCountdownDoesNotReusePreviousAnswer() throws {
        var feed = try feed()
        feed.hold(3, nil, slots: 2)
        feed.hold(5, nil, slots: 2, highlight: 0, glyph: "change")
        feed.hold(5, nil, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(3, nil, slots: 2)
        #expect(feed.committed == ["change", "perspective"])
        // No countdown captured. The strip is gone for as long as the command
        // channel between hacks takes, then a new presentation starts.
        feed.hold(60, nil)
        #expect(feed.tracker.state == .interrupted)
        feed.hold(3, nil, slots: 2)
        feed.step(nil, slots: 2, highlight: 0, glyph: "truth")
        #expect(feed.tracker.hackID == 2)
        #expect(feed.committed == [nil, nil])
        feed.hold(4, nil, slots: 2, highlight: 0, glyph: "truth")
        feed.hold(4, nil, slots: 2, highlight: 1, glyph: "see")
        feed.hold(2, nil, slots: 2)
        #expect(feed.committed == ["truth", "see"])
        #expect(feed.count(.hackStarted) == 2)
    }

    @Test("A strip that flickers in the released tail keeps the answer when the countdown is missed")
    func tailFlickerIsNotANewHack() throws {
        var feed = try feed()
        feed.hold(3, nil, slots: 2)
        feed.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, nil, slots: 2, highlight: 0)
        feed.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, nil, slots: 2, highlight: 1)
        feed.hold(4, nil, slots: 2)
        #expect(feed.committed == ["change", "perspective"])
        // One unreadable strip frame drops the tracker out of presentation;
        // the rest of the tail then looks exactly like a new hack's prelude.
        feed.step(nil)
        feed.hold(6, nil, slots: 2)
        #expect(feed.tracker.state == .interrupted)
        // No countdown seen: input lights slot 0 and the player draws.
        feed.hold(4, nil, slots: 2, highlight: 0, glyph: "truth")
        feed.hold(4, nil, slots: 2, highlight: 1, glyph: "see")
        feed.hold(2, nil, slots: 2)
        #expect(feed.tracker.hackID == 1)
        #expect(feed.count(.hackStarted) == 1)
        #expect(feed.committed == ["change", "perspective"])
        #expect(feed.statuses == [.confirmed, .confirmed])
    }

    @Test("An interrupted presentation without a new prelude resumes instead of resetting")
    func interruptedMidSlotResumes() throws {
        var feed = try feed()
        feed.hold(3, nil, slots: 2)
        feed.hold(5, nil, slots: 2, highlight: 0, glyph: "change")
        feed.step(nil, after: 2)
        #expect(feed.tracker.state == .interrupted)
        feed.hold(5, .presenting, slots: 2, highlight: 1, glyph: "truth")
        #expect(feed.tracker.hackID == 1)
        #expect(feed.count(.hackStarted) == 1)
    }

    @Test("Without indicator-established presentation, a covered header leaves the hack unseen")
    func indicatorPresentationDisabled() throws {
        var policy = PresentationTracker.Policy()
        policy.entersPresentationFromIndicators = false
        var feed = Feed(table: try ReferenceData.glyphTable(), policy: policy)
        feed.hold(3, nil, slots: 3)
        feed.hold(6, nil, slots: 3, highlight: 0, glyph: "change")
        feed.hold(2, nil, slots: 3, highlight: 0)
        feed.hold(6, nil, slots: 3, highlight: 1, glyph: "perspective")
        #expect(feed.tracker.state == .inactive)
        #expect(feed.tracker.hackID == 0)
        #expect(feed.tracker.slots.isEmpty)
    }

    @Test("Without the release rule, the last Glyph waits for the countdown to close it")
    func lastSlotReleaseDisabled() throws {
        var policy = PresentationTracker.Policy()
        policy.closesLastSlotOnRelease = false
        var feed = Feed(table: try ReferenceData.glyphTable(), policy: policy)
        feed.hold(3, nil, slots: 2)
        feed.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, nil, slots: 2, highlight: 0)
        feed.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, nil, slots: 2, highlight: 1)
        feed.hold(12, nil, slots: 2)
        #expect(feed.tracker.state == .presenting)
        #expect(feed.committed == ["change", nil])
        feed.hold(3, nil, slots: 2, timerBar: true)
        #expect(feed.tracker.state == .input)
        #expect(feed.committed == ["change", "perspective"])
        #expect(feed.tracker.slots[1].boundaryReason == "presentation ended, player input began")
    }

    @Test("A released last indicator cannot start a new hack when input lights slot 0 without a countdown bar")
    func releasedTailIsNotAPrelude() throws {
        var feed = try feed()
        feed.hold(3, nil, slots: 2)
        feed.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
        feed.hold(6, nil, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, nil, slots: 2, highlight: 1)
        feed.hold(12, nil, slots: 2)
        feed.hold(3, nil, slots: 2, highlight: 0)
        #expect(feed.tracker.hackID == 1)
        #expect(feed.count(.hackStarted) == 1)
        #expect(feed.committed == ["change", "perspective"])
        #expect(feed.statuses == [.confirmed, .confirmed])
    }

    @Test("A released highlight closes nothing while a Glyph is showing, before the last slot, or before a stable shape")
    func releasedHighlightGuards() throws {
        // Still drawing: the highlight drops for two frames over a visible shape.
        var drawing = try feed()
        drawing.step(.command)
        drawing.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        drawing.hold(3, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        drawing.hold(3, .presenting, slots: 2, glyph: "perspective")
        #expect(drawing.tracker.currentSlotIndex == 1)
        #expect(drawing.statuses[1] == .observing)

        // Not the last slot: a released highlight over a clear array mid-hack.
        var early = try feed()
        early.step(.command)
        early.hold(6, .presenting, slots: 3, highlight: 0, glyph: "change")
        early.hold(4, .presenting, slots: 3)
        #expect(early.tracker.currentSlotIndex == 0)
        #expect(early.count(.slotCommitted) == 0)

        // Nothing stable yet in the last slot.
        var empty = try feed()
        empty.step(.command)
        empty.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        empty.hold(1, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        empty.hold(4, .presenting, slots: 2)
        #expect(empty.tracker.currentSlotIndex == 1)
        #expect(empty.count(.slotCommitted) == 1)
    }

    @Test("The grace period runs from the frame the header was read on, not from now")
    func laggingHeader() throws {
        // Both feeds see one readable header and then nothing but unreadable
        // frames. The only difference is how far behind the text recognizer was.
        func remainingState(headerLag: Double) throws -> TrackingState {
            var feed = try feed()
            feed.step(.presenting, slots: 2, highlight: 0, headerLag: headerLag)
            #expect(feed.tracker.state == .presenting)
            feed.hold(6, nil, slots: 2, highlight: 0, glyph: "change")
            return feed.tracker.state
        }
        #expect(try remainingState(headerLag: 0) == .presenting)
        // 0.6 s behind: the phase was last established nearly a second ago, and
        // the tracker says so instead of crediting it to the current frame.
        #expect(try remainingState(headerLag: 0.6) == .interrupted)
    }

    @Test("A header unreadable for too long makes the phase unknown, keeping committed slots")
    func longUnreadableHeader() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        // Long enough to exhaust the grace period, not merely a few frames.
        feed.hold(20, nil, slots: 2, highlight: 1, glyph: "truth")
        #expect(feed.tracker.state == .interrupted)
        #expect(feed.committed[0] == "change")
        #expect(feed.committed[1] == nil)
        // Resuming the same presentation must not throw away what was collected.
        let hack = feed.tracker.hackID
        feed.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
        #expect(feed.tracker.hackID == hack)
        #expect(feed.committed == ["change", "perspective"])
    }

    @Test("A slot count that changes mid-hack is a conflict, not a new length")
    func slotCountConflict() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 4, highlight: 0, glyph: "change")
        feed.hold(4, .presenting, slots: 5, highlight: 0)
        #expect(feed.tracker.slotCountConflict)
        #expect(feed.tracker.expectedSlotCount == nil)
        #expect(feed.count(.slotCountConflict) == 1)
    }

    @Test("Joining a presentation late leaves the slots already past as missing")
    func joinLate() throws {
        var feed = try feed()
        feed.hold(6, .presenting, slots: 4, highlight: 2, glyph: "begin")
        feed.hold(6, .presenting, slots: 4, highlight: 3, glyph: "new")
        feed.hold(2, .input, slots: 4, highlight: 0, timerBar: true)
        #expect(feed.committed == [nil, nil, "begin", "new"])
        #expect(feed.statuses == [.missing, .missing, .confirmed, .confirmed])
        #expect(feed.tracker.confirmedPrefix.isEmpty)
    }

    @Test("Covered indicators are admitted as obstruction, not mistaken for leaving the screen")
    func indicatorsCovered() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(feed.committed[0] == "change")
        #expect(!feed.tracker.indicatorsObstructed)

        // A banner or the Picture in Picture window lands on the strip: the header still reads,
        // but the indicators stop being legible.
        feed.hold(12, .presenting, slots: nil)
        #expect(feed.tracker.indicatorsObstructed)
        // What was collected survives, and nothing new is invented.
        #expect(feed.committed[0] == "change")
        #expect(feed.count(.slotCommitted) == 1)

        // It clears as soon as they are readable again.
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        #expect(!feed.tracker.indicatorsObstructed)
    }

    @Test("The indicator advancing during input moves the display, though it commits nothing")
    func inputHighlightBumpsRevision() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(6, .presenting, slots: 2, highlight: 1, glyph: "perspective")
        feed.hold(2, .input, slots: 2, highlight: 0, timerBar: true)
        let settled = feed.tracker.revision
        let events = feed.step(.input, slots: 2, highlight: 1, timerBar: true)
        // No decision is taken -- reading the strip is not a commit -- but every
        // surface still has to redraw, which is what `revision` drives.
        #expect(events.isEmpty)
        #expect(feed.tracker.inputSlotIndex == 1)
        #expect(feed.tracker.revision > settled,
                "the highlight moved and nothing downstream would have noticed")
    }

    @Test("Resetting the tracker leaves nothing of the old session behind")
    func resetClearsEverything() throws {
        var feed = try feed()
        feed.step(.command)
        feed.hold(6, .presenting, slots: 2, highlight: 0, glyph: "change")
        feed.hold(2, .presenting, slots: 2, highlight: 1)
        feed.tracker.reset()
        #expect(feed.tracker.slots.isEmpty)
        #expect(feed.tracker.state == .inactive)
        #expect(feed.tracker.confirmedPrefix.isEmpty)
        #expect(feed.tracker.expectedSlotCount == nil)
        #expect(feed.tracker.isFrozen == false)
    }
}

@Suite("Obscured indicator fallback", .enabled(if: ReferenceData.shapesAvailable))
struct ObscuredIndicatorTests {
    private func feed() throws -> Feed { Feed(table: try ReferenceData.glyphTable()) }

    @Test("Covered indicators leave text readable and retain dashed observations without predictions")
    func textFallback() throws {
        var f = try feed()
        f.hold(4, .presenting, glyph: "see")
        f.hold(4, .presenting)
        #expect(f.tracker.state == .presenting)
        #expect(f.statuses == [.inferred])
        #expect(f.committed == ["see"])
        #expect(f.tracker.confirmedPrefix.isEmpty)
        #expect(f.tracker.expectedSlotCount == nil)
        #expect(f.count(.slotCommitted) == 0)
        #expect(f.count(.slotInferred) == 1)
        #expect(f.tracker.indicatorsObstructed)
    }

    @Test("Nested partial shapes become one provisional observation; identical consecutive shapes remain separate")
    func growingAndRepeatedShapes() throws {
        var f = try feed()
        for _ in 0..<2 {
            f.hold(3, .presenting, glyph: "see")
            f.hold(3, .presenting, glyph: "advance")
            // Recorded blanks last 100 ms: only two 20 Hz samples fit.
            f.hold(2, .presenting)
        }
        #expect(f.committed == ["advance", "advance"])
        #expect(f.statuses == [.inferred, .inferred])
        #expect(f.tracker.confirmedPrefix.isEmpty)
    }

    @Test("A brief blank cannot split a drawing; unrelated shapes with no blank stay uncertain")
    func refusesFalseBoundaries() throws {
        var f = try feed()
        f.hold(3, .presenting, glyph: "see")
        f.step(.presenting)
        f.hold(3, .presenting, glyph: "advance")
        #expect(f.tracker.slots.count == 1)
        #expect(f.count(.slotInferred) == 0)
        f.hold(3, .presenting, glyph: "all")
        f.hold(4, .presenting)
        #expect(f.statuses == [.uncertain])
        #expect(f.tracker.confirmedPrefix.isEmpty)
    }

    @Test("Restored indicators discard guessed positions and establish the actual slot")
    func restoredAnchor() throws {
        var f = try feed()
        f.hold(3, .presenting, glyph: "see")
        f.hold(4, .presenting)
        f.hold(3, .presenting, glyph: "advance")
        f.hold(3, .presenting, slots: 4, highlight: 2, glyph: "all")
        f.step(.presenting, slots: 4, highlight: 3)
        #expect(f.statuses == [.missing, .missing, .confirmed, .observing])
        #expect(f.committed == [nil, nil, "all", nil])
        #expect(f.tracker.confirmedPrefix.isEmpty)
    }

    @Test("The independent input timer overrides a lagging presentation header even with no indicators")
    func independentTimer() throws {
        var f = try feed()
        f.hold(3, .presenting, glyph: "see")
        f.step(.presenting, glyph: "all", timerBar: true, headerLag: 0.2)
        #expect(f.tracker.state == .input)
        #expect(f.tracker.phaseSource == .inputTimer)
        #expect(f.tracker.isFrozen)
        #expect(f.committed == ["see"])
        #expect(f.statuses == [.inferred])
        f.hold(10, nil, glyph: "advance", timerBar: true)
        #expect(f.committed == ["see"])
        #expect(f.tracker.state == .input)
    }

    @Test("A timer without indicators stops collection without confirming an unfinished known slot")
    func timerCannotPromotePartialShape() throws {
        var f = try feed()
        f.hold(3, .presenting, slots: 2, highlight: 0, glyph: "see")
        f.step(nil, glyph: "advance", timerBar: true)
        #expect(f.tracker.state == .input)
        #expect(f.statuses[0] == .inferred)
        #expect(f.tracker.confirmedPrefix.isEmpty)
        #expect(f.count(.slotCommitted) == 0)
    }

    @Test("Commands, unknown phases and stale text cannot produce inferred entries")
    func fallbackGates() throws {
        for phase in [GamePhase.command, .input, .unknown] {
            var f = try feed()
            f.hold(4, phase, glyph: "see")
            f.hold(4, phase)
            #expect(f.tracker.slots.isEmpty)
        }
        var f = try feed()
        for _ in 0..<4 { f.step(.presenting, glyph: "see", headerLag: 3) }
        #expect(f.tracker.slots.isEmpty)
    }

    @Test("A capture gap breaks temporal fallback rather than joining unrelated frames")
    func gapBreaksContinuity() throws {
        var f = try feed()
        f.hold(3, .presenting, glyph: "see")
        f.step(.presenting, after: 2)
        f.hold(4, .presenting)
        #expect(f.count(.slotInferred) == 0)
        #expect(f.tracker.confirmedPrefix.isEmpty)
    }

    @Test("Temporal observations are bounded even when no sequence length is visible")
    func boundedFallback() throws {
        var f = try feed()
        for _ in 0..<10 {
            f.hold(3, .presenting, glyph: "see")
            f.hold(4, .presenting)
        }
        #expect(f.tracker.slots.count == SequenceTable.maximumLength)
        #expect(f.tracker.expectedSlotCount == nil)
    }
}

/// The input highlight on the Island and in the window. Shape evidence plays
/// no part here, so this needs no reference table and always runs.
@Suite("Input highlight hysteresis")
struct InputHighlightHysteresisTests {
    private struct Strip {
        var tracker = PresentationTracker(sessionID: CaptureSessionID(rawValue: 1))
        var time = 100.0

        @discardableResult
        mutating func step(_ phase: GamePhase, slots: Int, highlight: Int?,
                           timerBar: Bool = false) -> [TrackingEvent] {
            time += 0.05
            let reading = SlotStripReading(slotCount: slots, highlightedIndex: highlight,
                                           markerCentersX: (0..<slots).map { (Double($0) + 0.5) / Double(slots) },
                                           hasInputTimerBar: timerBar)
            return tracker.accept(FrameEvidence(
                sessionID: tracker.sessionID, time: time,
                header: HeaderReading(phase: phase, matchedText: phase.rawValue, confidence: 0.9, sourceTime: time),
                slots: reading, shape: ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
                hasValidCalibration: true, hasInputTimerBar: timerBar))
        }

        mutating func hold(_ count: Int, _ phase: GamePhase, slots: Int, highlight: Int?,
                           timerBar: Bool = false) {
            for _ in 0..<count { step(phase, slots: slots, highlight: highlight, timerBar: timerBar) }
        }

        /// A three-slot presentation, then input on slot `inputSlot`.
        static func inInput(on inputSlot: Int) -> Strip {
            var strip = Strip()
            strip.step(.command, slots: 3, highlight: nil)
            for index in 0..<3 { strip.hold(6, .presenting, slots: 3, highlight: index) }
            strip.hold(4, .input, slots: 3, highlight: inputSlot, timerBar: true)
            return strip
        }
    }

    @Test("One input frame without a highlight neither moves nor redraws the slot")
    func singleFrameDropoutHeld() {
        var strip = Strip.inInput(on: 1)
        #expect(strip.tracker.state == .input)
        #expect(strip.tracker.inputSlotIndex == 1)
        let settled = strip.tracker.revision
        // The gold leaves one indicator a frame before it lights the next. The
        // Island blanked on that frame and came back 0.15 s later.
        let events = strip.step(.input, slots: 3, highlight: nil, timerBar: true)
        #expect(events.isEmpty)
        #expect(strip.tracker.inputSlotIndex == 1)
        #expect(strip.tracker.revision == settled, "a held slot must not send an update")
        strip.step(.input, slots: 3, highlight: 1, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 1)
        #expect(strip.tracker.revision == settled)
        // Several frames inside the grace are still between indicators.
        strip.hold(5, .input, slots: 3, highlight: nil, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 1)
        #expect(strip.tracker.revision == settled)
        // The real move is shown at once.
        strip.step(.input, slots: 3, highlight: 2, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 2)
        #expect(strip.tracker.revision > settled)
    }

    @Test("A highlight gone for longer than the grace still clears the input slot")
    func longDropoutClears() {
        var strip = Strip.inInput(on: 0)
        let grace = strip.tracker.policy.indicatorObstructionGrace
        // Frames 50 ms apart, the last one still inside the grace.
        let inside = Int((grace / 0.05).rounded(.down)) - 1
        strip.hold(inside, .input, slots: 3, highlight: nil, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 0)
        let before = strip.tracker.revision
        strip.hold(3, .input, slots: 3, highlight: nil, timerBar: true)
        #expect(strip.tracker.state == .input)
        #expect(strip.tracker.inputSlotIndex == nil)
        #expect(strip.tracker.revision > before)
        // It returns the moment the strip shows a highlight again.
        strip.step(.input, slots: 3, highlight: 1, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 1)
    }

    @Test("Leaving input drops a held slot immediately")
    func leavingInputClears() {
        var strip = Strip.inInput(on: 2)
        strip.step(.input, slots: 3, highlight: nil, timerBar: true)
        #expect(strip.tracker.inputSlotIndex == 2)
        strip.step(.completed, slots: 3, highlight: nil)
        #expect(strip.tracker.state == .completed)
        #expect(strip.tracker.inputSlotIndex == nil)
    }
}
