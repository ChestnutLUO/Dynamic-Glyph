/// Where the tracker believes the game is. Distinct from `GamePhase`, which is
/// a single frame's reading: this survives unreadable frames and adds the
/// `interrupted` case that no header ever spells out.
public enum TrackingState: String, Sendable, Equatable {
    case inactive, command, presenting, input, completed, interrupted
}

/// Turns timestamped frame evidence into a presented sequence.
///
/// Pure: no images, no clock, no framework. Everything it knows arrives as
/// `FrameEvidence`, which makes every rule in it testable by handing it a list
/// of values — including the cases that are hard to stage on a phone, such as
/// an out-of-order result from a previous capture session.
///
/// A Glyph is only confirmed in the sequence when an *independently detected*
/// boundary says the slot ended. An
/// exact shape match or a blank frame cannot confirm a slot. When the header
/// establishes presentation but indicators are covered, blank-separated shapes
/// may be retained as inferred entries, excluded from prediction and guidance.
public struct PresentationTracker: Sendable {
    public struct Policy: Sendable, Equatable {
        /// Two supporting samples this far apart make a shape stable. The
        /// field capture puts about 50 ms between samples, so this is one
        /// sampling interval, chosen as a starting policy rather than a
        /// validated threshold.
        public var minimumStableInterval = 0.045
        public var minimumStableSamples = 2
        /// A larger jump between source timestamps means frames were lost, and
        /// geometric continuity with them cannot be assumed.
        public var maximumFrameGap = 1.0
        /// How long a phase survives an unreadable header before the tracker
        /// admits it no longer knows.
        public var unknownPhaseGrace = 0.75
        /// Display-only: evidence older than this is shown as stale.
        public var stalenessThreshold = 1.5
        /// Agreeing strip readings needed before a slot count is trusted.
        public var slotCountVotesRequired = 2
        /// How long the indicators may be unreadable mid-hack before the
        /// display admits they are obscured rather than merely between frames.
        public var indicatorObstructionGrace = 0.35
        /// A sustained clear array separates provisional observations. This is
        /// not proof of a game slot boundary, even when the header is legible.
        /// The annotated recording has 100 ms blank intervals: at 20 Hz that
        /// gives two samples 50 ms apart. Require both, allowing clock rounding.
        public var minimumBlankInterval = 0.045
        /// Whether a stable empty strip followed by a slot-0 highlight may
        /// establish presentation when the header cannot. Off only to measure
        /// what that path contributes.
        public var entersPresentationFromIndicators = true
        /// Whether the last slot may close on its released indicator over a
        /// clear array (see `releaseLastSlot`). Off only to measure what that
        /// rule contributes.
        public var closesLastSlotOnRelease = true
        /// How long the strip must have been out of sight since the tracker
        /// last saw a presentation before a fresh empty-strip -> slot-0
        /// transition may start a new hack. After the last Glyph the game
        /// shows that same empty strip for about half a second before the
        /// countdown; between hacks the command channel alone hides the strip
        /// for 2.5 s or more in the recordings.
        public var minimumStripAbsenceForNewHack = 1.5

        public init() {}
    }

    /// A shape seen repeatedly within the slot that is currently open.
    private struct Hypothesis {
        let glyph: GlyphID
        let edges: Set<GlyphPath.Edge>
        var times: [Double]

        func isStable(_ policy: Policy) -> Bool {
            times.count >= policy.minimumStableSamples &&
                (times.last ?? 0) - (times.first ?? 0) >= policy.minimumStableInterval
        }
    }

    public let sessionID: CaptureSessionID
    public let policy: Policy

    public private(set) var state: TrackingState = .inactive
    public private(set) var phaseSource: PhaseSource = .none
    public private(set) var hackID = 0
    public private(set) var slots: [SlotObservation] = []
    public private(set) var currentSlotIndex: Int?
    /// The highlighted indicator during player input, for optional highlighting
    /// of the slot the player is on. Never a source of shape evidence.
    public private(set) var inputSlotIndex: Int?
    public private(set) var slotCountConflict = false
    /// Bumped whenever anything a renderer shows has changed.
    public private(set) var revision = 0
    /// Source time of the most recent accepted frame.
    public private(set) var lastEvidenceTime: Double?
    /// Source time of the most recent frame whose header was actually read.
    public private(set) var lastPhaseTime: Double?
    public private(set) var isFrozen = false
    /// Whether the slots currently held were collected from a presentation this
    /// tracker actually watched. A hack whose presentation was never legible
    /// must not inherit the previous hack's answer just because its slot
    /// indicator reads cleanly.
    public private(set) var observedPresentationForCurrentHack = false
    /// Source time when the indicator strip was last read successfully, and
    /// whether it has since stopped being readable while a hack was in progress.
    ///
    /// A notification banner or the Picture in Picture window on the strip looks
    /// exactly like leaving the Glyph screen, and the two must not be confused:
    /// one keeps what was collected and waits, the other is a new hack.
    public private(set) var lastIndicatorTime: Double?
    public private(set) var indicatorsObstructed = false
    /// When a window was first seen over the strip outside a hack.
    private var coveredSince: Double?

    /// Everything a renderer draws, so a change to any of it bumps `revision`.
    private struct DisplayState: Equatable {
        let state: TrackingState
        let phaseSource: PhaseSource
        let hackID: Int
        let currentSlotIndex: Int?
        let inputSlotIndex: Int?
        let indicatorsObstructed: Bool
        let slots: [SlotObservation]
    }

    private var displayState: DisplayState {
        DisplayState(state: state, phaseSource: phaseSource, hackID: hackID,
                     currentSlotIndex: currentSlotIndex, inputSlotIndex: inputSlotIndex,
                     indicatorsObstructed: indicatorsObstructed, slots: slots)
    }

    private var hypotheses: [Hypothesis] = []
    private var slotCountVotes: [Int: Int] = [:]
    private var inferredFromIndex: Int?
    private var nextInferredIndex: Int?
    private var blankSince: Double?
    /// When the last slot's indicator was first seen released over a clear
    /// array. See `releaseLastSlot`.
    private var lastSlotReleasedSince: Double?
    private struct IndicatorPrelude {
        let reading: SlotStripReading
        let firstTime: Double
        var lastTime: Double
        var samples: Int
    }
    private var indicatorPrelude: IndicatorPrelude?
    /// Source time the input highlight was last actually read. A single frame
    /// of a readable strip with no highlight, which the game draws as the
    /// gold moves from one indicator to the next, keeps the slot for up to
    /// `indicatorObstructionGrace` rather than blanking every surface and
    /// bringing it back a frame later.
    private var inputHighlightTime: Double?
    private var indicatorPhaseAnchor: SlotStripReading?
    /// Set only by a newly verified prelude, not by the continuing anchor.
    private var freshIndicatorStart = false
    /// Source time of the most recent frame with a readable strip.
    private var lastStripReadingTime: Double?
    /// The strip has been out of sight for `minimumStripAbsenceForNewHack`
    /// since the tracker was last in presentation. Only then can a fresh
    /// prelude be told apart from the tail of the presentation just shown.
    private var stripReturnedAfterAbsence = false

    public init(sessionID: CaptureSessionID, policy: Policy = Policy()) {
        self.sessionID = sessionID
        self.policy = policy
    }

    /// The slot count the strip has independently and repeatedly shown.
    /// Nil while unproven or contradicted — never a guess from the number of
    /// Glyphs that happen to have been recognized.
    public var expectedSlotCount: Int? {
        guard !slotCountConflict else { return nil }
        let qualified = slotCountVotes.filter { $0.value >= policy.slotCountVotesRequired }
        guard qualified.count == 1, let only = qualified.first else { return nil }
        return only.key
    }

    /// The contiguous run of confirmed Glyphs from slot zero.
    ///
    /// This, and only this, may be given to the predictor: a table prefix
    /// lookup has no way to express "the second Glyph is unknown", so feeding
    /// it slot 3 in slot 2's place would silently answer a different question.
    public var confirmedPrefix: [GlyphID] {
        var prefix: [GlyphID] = []
        for slot in slots {
            guard slot.status == .confirmed, let glyph = slot.glyph else { break }
            prefix.append(glyph)
        }
        return prefix
    }

    // MARK: - Evidence

    @discardableResult
    public mutating func accept(_ evidence: FrameEvidence) -> [TrackingEvent] {
        guard evidence.sessionID == sessionID else {
            return [TrackingEvent(kind: .staleEvidenceRejected, time: evidence.time, hackID: hackID,
                                  reason: "evidence from capture session \(evidence.sessionID)")]
        }
        var events: [TrackingEvent] = []

        if let last = lastEvidenceTime {
            if evidence.time < last {
                events += invalidateTentative(at: evidence.time, reason: "source time moved backwards")
                state = .interrupted
                phaseSource = .none
                lastStripReadingTime = nil
                lastPhaseTime = nil
            } else if evidence.time - last > policy.maximumFrameGap {
                events += invalidateTentative(at: evidence.time,
                                              reason: "frame gap of \((evidence.time - last).secondsDescription)")
                state = .interrupted
                phaseSource = .none
            }
        }
        lastEvidenceTime = evidence.time
        if evidence.slots != nil {
            if lastStripReadingTime.map({ evidence.time - $0 >= policy.minimumStripAbsenceForNewHack }) ?? true {
                stripReturnedAfterAbsence = true
            }
            lastStripReadingTime = evidence.time
        }

        let before = displayState
        events += applyPhase(evidence)
        events += applySlots(evidence)
        events += applyFallback(evidence)
        events += applyShape(evidence)
        if state == .presenting { stripReturnedAfterAbsence = false }
        // Not `if !events.isEmpty`. The indicator advancing during player input
        // is the single most important thing a renderer can show, and it
        // produces no event: it is a reading, not a decision. Keying redraws on
        // events alone left both the Picture in Picture highlight and the Live
        // Activity frozen for the whole of the input phase.
        if !events.isEmpty || displayState != before { revision += 1 }
        return events
    }

    /// A new source-clock epoch invalidates phase timing, not hack identity,
    /// committed slots, or the separately owned result and gear observations.
    public mutating func invalidatePhase() {
        lastPhaseTime = nil
        if state != .inactive { state = .interrupted }
        phaseSource = .none
        revision += 1
    }

    /// The user asked for a clean slate, or the session is ending.
    public mutating func reset() {
        state = .inactive
        phaseSource = .none
        slots = []
        hypotheses = []
        slotCountVotes = [:]
        currentSlotIndex = nil
        inputSlotIndex = nil
        inputHighlightTime = nil
        slotCountConflict = false
        isFrozen = false
        observedPresentationForCurrentHack = false
        lastIndicatorTime = nil
        indicatorsObstructed = false
        coveredSince = nil
        lastEvidenceTime = nil
        lastPhaseTime = nil
        inferredFromIndex = nil
        nextInferredIndex = nil
        blankSince = nil
        lastSlotReleasedSince = nil
        indicatorPrelude = nil
        indicatorPhaseAnchor = nil
        freshIndicatorStart = false
        lastStripReadingTime = nil
        stripReturnedAfterAbsence = false
        revision += 1
    }

    // MARK: - Phase

    private mutating func applyPhase(_ evidence: FrameEvidence) -> [TrackingEvent] {
        var events: [TrackingEvent] = []
        var resolved: GamePhase = .unknown
        var source: PhaseSource = .none

        if let header = evidence.header, header.phase != .unknown,
           header.sourceTime <= evidence.time,
           evidence.time - header.sourceTime <= policy.unknownPhaseGrace {
            resolved = header.phase
            source = .headerText
            // The header's own frame time, so a lagging analysis shortens the
            // grace period instead of silently extending it.
            lastPhaseTime = max(lastPhaseTime ?? -.infinity, min(header.sourceTime, evidence.time))
        } else if indicatorPhaseAnchor == nil,
                  let last = lastPhaseTime, last.isFinite, evidence.time >= last,
                  evidence.time - last <= policy.unknownPhaseGrace,
                  let retained = currentPhase {
            // The header is briefly unreadable. Keep what was established.
            resolved = retained
            source = .retained
        }

        let indicatorPresentation = presentationFromIndicators(evidence,
            contradictoryHeader: source == .headerText && resolved != .presenting)
        if source != .headerText, indicatorPresentation {
            resolved = .presenting
            source = .indicatorTransition
        }

        // The countdown bar is evidence from THIS frame. A header reading is
        // not: text recognition runs behind the sampler, so a header saying
        // "presenting" can be several frames old while the bar in front of us
        // says the player is already drawing. When they disagree, the current
        // frame wins -- collecting player strokes as presentation evidence is
        // the failure this whole design exists to prevent.
        if evidence.hasInputTimerBar, evidence.hasValidCalibration, observedPresentationForCurrentHack,
           state == .presenting || state == .input || state == .interrupted,
           resolved != .command, resolved != .completed {
            resolved = .input
            source = .inputTimer
            lastPhaseTime = evidence.time
        }

        let target = trackingState(for: resolved)
        guard target != state else { phaseSource = source; return events }

        if state == .presenting {
            if target == .input {
                if source == .inputTimer,
                   evidence.slots == nil, let index = currentSlotIndex {
                    // A timer without readable indicators can stop collection,
                    // but must not promote a possibly unfinished shape.
                    inferredFromIndex = min(inferredFromIndex ?? index, index)
                }
                events += finalizeCurrentSlot(at: evidence.time,
                                              reason: "presentation ended, player input began")
            } else {
                // The presentation was abandoned rather than finished.
                // Tentative evidence is discarded; committed slots stay.
                events += invalidateTentative(at: evidence.time,
                                              reason: "left presentation for \(target.rawValue)")
            }
        }

        if target == .presenting {
            if shouldStartNewHack(given: evidence.slots,
                                  freshIndicatorStart: source == .indicatorTransition && freshIndicatorStart
                                      && stripReturnedAfterAbsence) {
                events += startHack(at: evidence.time)
            } else {
                events.append(TrackingEvent(kind: .phaseChanged, time: evidence.time, hackID: hackID,
                                            reason: "resumed presentation after \(state.rawValue)"))
            }
        }

        if target == .command {
            // Command-entry shapes are drawn on the same array with the same
            // vocabulary and must never reach a slot. Command entry is also
            // where the next hack begins, so the sequence retained from the
            // last one stops being an answer to anything from here.
            hypotheses = []
            currentSlotIndex = nil
            observedPresentationForCurrentHack = false
            events += discardRetainedSequence(at: evidence.time, reason: "command channel opened")
        }

        if target == .input, !observedPresentationForCurrentHack {
            // Player input reached without ever seeing this hack's presentation.
            // Whatever is held belongs to an earlier hack.
            events += discardRetainedSequence(at: evidence.time,
                                              reason: "input began but no presentation was observed")
        }

        if target == .input, !isFrozen {
            isFrozen = true
            events.append(TrackingEvent(kind: .sequenceFrozen, time: evidence.time, hackID: hackID,
                                        reason: "player input began; presented sequence retained"))
        }

        if target == .completed {
            // The summary stays on screen, but the hack is over: the next
            // screen to appear must not treat these slots as its own.
            observedPresentationForCurrentHack = false
            isFrozen = true
            events.append(TrackingEvent(kind: .hackCompleted, time: evidence.time, hackID: hackID,
                                        reason: "completion screen"))
        }

        events.append(TrackingEvent(kind: .phaseChanged, time: evidence.time, hackID: hackID,
                                    reason: "\(state.rawValue) -> \(target.rawValue) via \(source.rawValue)"))
        state = target
        phaseSource = source
        if target != .input {
            inputSlotIndex = nil
            inputHighlightTime = nil
        }
        return events
    }

    /// A presentation screen is a new hack unless it is the same one resuming
    /// after frames the header could not be read in. Getting this wrong in
    /// either direction is expensive: too eager and a glitch erases a collected
    /// sequence, too reluctant and the previous hack's Glyphs are shown for the
    /// new one.
    private func shouldStartNewHack(given reading: SlotStripReading?, freshIndicatorStart: Bool) -> Bool {
        guard state == .interrupted, hackID > 0, !isFrozen else { return true }
        // A verified empty-strip -> slot-0 transition after the strip was gone
        // is a new presentation, even when the missed countdown left the old
        // hack unfrozen and the new hack has exactly the same number of slots.
        // Without the absence it may be this hack's own released tail
        // followed by input lighting slot 0, and starting a hack there would
        // discard the answer and collect the player's strokes.
        if freshIndicatorStart { return true }
        if let reading, let expected = expectedSlotCount, reading.slotCount != expected { return true }
        return false
    }

    /// A selected row alone cannot identify presentation: input uses the same
    /// row. Require its stable, empty, unselected prelude and subsequent slot-0
    /// transition. Keep that phase only while no countdown bar is drawn and with
    /// compatible visible indicators; never restart from a mid-input highlight.
    private mutating func presentationFromIndicators(_ evidence: FrameEvidence,
                                                     contradictoryHeader: Bool) -> Bool {
        freshIndicatorStart = false
        guard policy.entersPresentationFromIndicators,
              !contradictoryHeader, state != .input, evidence.hasValidCalibration,
              !evidence.hasInputTimerBar, let reading = evidence.slots else {
            indicatorPrelude = nil
            indicatorPhaseAnchor = nil
            return false
        }
        func agrees(_ other: SlotStripReading) -> Bool {
            reading.slotCount == other.slotCount && reading.markerCentersX.count == other.markerCentersX.count &&
                zip(reading.markerCentersX, other.markerCentersX).allSatisfy { abs($0 - $1) <= 0.02 }
        }
        if let anchor = indicatorPhaseAnchor {
            if state == .presenting, !slotCountConflict, agrees(anchor) {
                if let selected = reading.highlightedIndex, selected >= (anchor.highlightedIndex ?? 0) {
                    indicatorPhaseAnchor = reading
                    return true
                }
                // After the last Glyph the game drops the last indicator's
                // highlight and keeps the strip up until the countdown. That is
                // the tail of this presentation, not a departure from it:
                // ending the phase here discarded the last slot on the very
                // frame `releaseLastSlot` needs in order to close it. The
                // anchor is kept, so the input highlight on slot 0 still ends it.
                if reading.highlightedIndex == nil, anchor.highlightedIndex == reading.slotCount - 1 {
                    return true
                }
            }
            indicatorPhaseAnchor = nil
        }
        if reading.highlightedIndex == nil, evidence.shape.kind == .noStroke {
            if var prelude = indicatorPrelude, agrees(prelude.reading),
               evidence.time > prelude.lastTime,
               evidence.time - prelude.lastTime <= policy.maximumFrameGap {
                prelude.samples += 1
                prelude.lastTime = evidence.time
                indicatorPrelude = prelude
            } else {
                indicatorPrelude = IndicatorPrelude(reading: reading, firstTime: evidence.time,
                                                     lastTime: evidence.time, samples: 1)
            }
            return false
        }
        defer { indicatorPrelude = nil }
        guard reading.highlightedIndex == 0, let prelude = indicatorPrelude,
              agrees(prelude.reading), prelude.samples >= policy.minimumStableSamples,
              prelude.lastTime - prelude.firstTime >= policy.minimumStableInterval,
              evidence.time >= prelude.lastTime,
              evidence.time - prelude.lastTime <= policy.maximumFrameGap else { return false }
        indicatorPhaseAnchor = reading
        freshIndicatorStart = true
        return true
    }

    private var currentPhase: GamePhase? {
        switch state {
        case .command: return .command
        case .presenting: return .presenting
        case .input: return .input
        case .completed: return .completed
        case .inactive, .interrupted: return nil
        }
    }

    private func trackingState(for phase: GamePhase) -> TrackingState {
        switch phase {
        case .unknown: return state == .inactive ? .inactive : .interrupted
        case .command: return .command
        case .presenting: return .presenting
        case .input: return .input
        case .completed: return .completed
        }
    }

    /// Everything about the previous hack is discarded here, exactly once.
    private mutating func startHack(at time: Double) -> [TrackingEvent] {
        hackID += 1
        slots = []
        hypotheses = []
        slotCountVotes = [:]
        slotCountConflict = false
        currentSlotIndex = nil
        inputSlotIndex = nil
        inputHighlightTime = nil
        inferredFromIndex = nil
        nextInferredIndex = nil
        blankSince = nil
        lastIndicatorTime = nil
        indicatorsObstructed = false
        coveredSince = nil
        isFrozen = false
        observedPresentationForCurrentHack = true
        return [TrackingEvent(kind: .hackStarted, time: time, hackID: hackID,
                              reason: "presentation screen after \(state.rawValue)")]
    }

    // MARK: - Slots

    private mutating func applySlots(_ evidence: FrameEvidence) -> [TrackingEvent] {
        // Readability is tracked whether or not the reading is usable, because
        // "the indicators stopped being legible mid-hack" is itself evidence.
        if state == .presenting || state == .input {
            if evidence.slots != nil {
                lastIndicatorTime = evidence.time
                indicatorsObstructed = false
            } else if lastIndicatorTime == nil || evidence.time - (lastIndicatorTime ?? evidence.time) > policy.indicatorObstructionGrace {
                indicatorsObstructed = true
            }
        } else if evidence.hasValidCalibration, evidence.slotRejection == .coveredByOverlay {
            // On the Glyph screen but outside a known hack, a window over the
            // strip is the reason no hack can be seen starting at all. Say so
            // rather than keep waiting for one. A cached calibration outlives
            // the Glyph screen, so it starts only where the array itself is in
            // view, clear or showing a Glyph; the player drawing keeps it.
            let arrayInView = evidence.shape.kind == .noStroke || evidence.shape.kind == .uniqueVisibleShape
            if coveredSince == nil, arrayInView { coveredSince = evidence.time }
            indicatorsObstructed = coveredSince.map {
                evidence.time - $0 >= policy.indicatorObstructionGrace
            } ?? false
        } else {
            coveredSince = nil
            indicatorsObstructed = false
        }
        guard let reading = evidence.slots else { return [] }
        var events: [TrackingEvent] = []

        if state == .presenting || state == .input {
            slotCountVotes[reading.slotCount, default: 0] += 1
            let qualified = slotCountVotes.filter { $0.value >= policy.slotCountVotesRequired }
            if qualified.count > 1, !slotCountConflict {
                slotCountConflict = true
                events += invalidateTentative(at: evidence.time, reason: "slot count changed mid-hack")
                events.append(TrackingEvent(kind: .slotCountConflict, time: evidence.time, hackID: hackID,
                                            reason: "counts \(qualified.keys.sorted().map(String.init).joined(separator: "/"))"))
            }
        }

        switch state {
        case .presenting:
            ensureSlots(upTo: reading.slotCount - 1)
            guard let highlighted = reading.highlightedIndex else {
                events += releaseLastSlot(evidence, strip: reading)
                return events
            }
            lastSlotReleasedSince = nil
            if let first = inferredFromIndex {
                // Do not promote guessed positions when the strip returns.
                // Discard that region and re-anchor on the actual highlight.
                for index in first..<slots.count { slots[index] = SlotObservation(index: index) }
                if slots.count > reading.slotCount { slots.removeLast(slots.count - reading.slotCount) }
                currentSlotIndex = nil
                hypotheses = []
                inferredFromIndex = nil
                nextInferredIndex = nil
                blankSince = nil
                events.append(TrackingEvent(kind: .evidenceInvalidated, time: evidence.time, hackID: hackID,
                                            reason: "indicators restored; inferred positions discarded"))
            }
            guard let open = currentSlotIndex else {
                events += openSlot(highlighted, at: evidence.time)
                return events
            }
            if highlighted > open {
                events += finalizeCurrentSlot(at: evidence.time,
                                              reason: "indicator advanced to slot \(highlighted + 1)")
                // Any slot the highlight skipped over never produced evidence.
                for skipped in (open + 1)..<highlighted {
                    ensureSlots(upTo: skipped)
                    slots[skipped].status = .missing
                    slots[skipped].boundaryReason = "indicator skipped this slot"
                    events.append(TrackingEvent(kind: .slotMissing, time: evidence.time, hackID: hackID,
                                                slotIndex: skipped, reason: "indicator skipped this slot"))
                }
                events += openSlot(highlighted, at: evidence.time)
                events.append(TrackingEvent(kind: .slotAdvanced, time: evidence.time, hackID: hackID,
                                            slotIndex: highlighted, reason: "verified indicator transition"))
            } else if highlighted < open {
                // The strip cannot walk backwards during one presentation.
                events += invalidateTentative(at: evidence.time,
                                              reason: "indicator moved back to slot \(highlighted + 1)")
            }
        case .input:
            if slots.contains(where: { $0.status == .inferred }) {
                inputSlotIndex = nil
                inputHighlightTime = nil
            } else if let highlighted = reading.highlightedIndex {
                inputSlotIndex = highlighted
                inputHighlightTime = evidence.time
            } else if let seen = inputHighlightTime, evidence.time >= seen,
                      evidence.time - seen <= policy.indicatorObstructionGrace {
                // Between indicators, not off them: hold the slot.
            } else {
                inputSlotIndex = nil
                inputHighlightTime = nil
            }
        default:
            break
        }
        return events
    }

    /// Once the last Glyph has been shown the game clears the array and
    /// drops the highlight from the last indicator, while the strip stays. The
    /// header then goes unreadable for about half a second before the
    /// countdown appears, and on a phone, where text is read behind the
    /// sampler, that can outlast the grace a stale header reading gets: the
    /// tracker left the presentation and threw away a last Glyph it had
    /// already seen. So this frame's own pixels close that slot instead.
    ///
    /// Only the last slot, only over a clear array held for the same interval
    /// that separates provisional shapes, and only once a shape in it is
    /// stable: a highlight that flickers while a Glyph is still being drawn,
    /// or drops before one appears, closes nothing.
    private mutating func releaseLastSlot(_ evidence: FrameEvidence,
                                          strip: SlotStripReading) -> [TrackingEvent] {
        guard policy.closesLastSlotOnRelease,
              let open = currentSlotIndex, open == strip.slotCount - 1, inferredFromIndex == nil,
              evidence.shape.kind == .noStroke,
              hypotheses.contains(where: { $0.isStable(policy) }) else {
            lastSlotReleasedSince = nil
            return []
        }
        let since = lastSlotReleasedSince ?? evidence.time
        lastSlotReleasedSince = since
        guard evidence.time - since >= policy.minimumBlankInterval else { return [] }
        lastSlotReleasedSince = nil
        return finalizeCurrentSlot(at: evidence.time,
                                   reason: "last indicator released after the array cleared")
    }

    private mutating func ensureSlots(upTo index: Int) {
        guard index >= 0 else { return }
        while slots.count <= index { slots.append(SlotObservation(index: slots.count)) }
    }

    private mutating func openSlot(_ index: Int, at time: Double) -> [TrackingEvent] {
        ensureSlots(upTo: index)
        var events: [TrackingEvent] = []
        // Joining a presentation already in progress leaves real holes behind.
        for earlier in 0..<index where slots[earlier].status == .pending {
            slots[earlier].status = .missing
            slots[earlier].boundaryReason = "presentation was already past this slot"
            events.append(TrackingEvent(kind: .slotMissing, time: time, hackID: hackID,
                                        slotIndex: earlier, reason: "joined presentation late"))
        }
        if !slots[index].isSettled {
            slots[index].status = .observing
            slots[index].boundaryReason = nil
        }
        currentSlotIndex = index
        hypotheses = []
        lastSlotReleasedSince = nil
        return events
    }

    private mutating func finalizeCurrentSlot(at time: Double, reason: String) -> [TrackingEvent] {
        guard let index = currentSlotIndex else { return [] }
        currentSlotIndex = nil
        defer { hypotheses = [] }
        ensureSlots(upTo: index)
        guard !slots[index].isSettled else { return [] }

        let stable = hypotheses.filter { $0.isStable(policy) }
        slots[index].boundaryReason = reason

        guard !stable.isEmpty else {
            let sawSomething = !hypotheses.isEmpty
            slots[index].status = sawSomething ? .uncertain : .missing
            if sawSomething {
                slots[index].alternatives = hypotheses.map(\.glyph).sorted()
                return [TrackingEvent(kind: .slotUncertain, time: time, hackID: hackID, slotIndex: index,
                                      reason: "\(reason); no shape held long enough",
                                      sampleCount: hypotheses.reduce(0) { $0 + $1.times.count })]
            }
            return [TrackingEvent(kind: .slotMissing, time: time, hackID: hackID, slotIndex: index,
                                  reason: "\(reason); no shape evidence")]
        }

        if stable.count == 1 {
            return commit(stable[0], at: index, time: time, reason: reason, alternatives: [])
        }

        // Several stable shapes in one slot. The documented temporal rule: a
        // drawing that grows produces nested edge sets -- `see` is a prefix of
        // `advance`, `all` of `clear_all` -- and the completed shape is the
        // largest. Anything not nested is a missed boundary or noise, and the
        // slot is left uncertain rather than resolved by picking a side.
        let ordered = stable.sorted { $0.edges.count < $1.edges.count }
        let nested = zip(ordered, ordered.dropFirst()).allSatisfy { $0.edges.isStrictSubset(of: $1.edges) }
        guard nested, let largest = ordered.last else {
            slots[index].status = .uncertain
            slots[index].alternatives = stable.map(\.glyph).sorted()
            return [TrackingEvent(kind: .slotUncertain, time: time, hackID: hackID, slotIndex: index,
                                  reason: "\(reason); \(stable.count) unrelated stable shapes",
                                  sampleCount: stable.reduce(0) { $0 + $1.times.count })]
        }
        return commit(largest, at: index, time: time, reason: "\(reason); grew through \(ordered.count) nested shapes",
                      alternatives: ordered.dropLast().map(\.glyph))
    }

    private mutating func commit(_ hypothesis: Hypothesis, at index: Int, time: Double,
                                 reason: String, alternatives: [GlyphID]) -> [TrackingEvent] {
        let inferred = inferredFromIndex.map { index >= $0 } ?? false
        slots[index].status = inferred ? .inferred : .confirmed
        slots[index].glyph = hypothesis.glyph
        slots[index].alternatives = alternatives
        slots[index].firstSampleTime = hypothesis.times.first
        slots[index].lastSampleTime = hypothesis.times.last
        slots[index].sampleCount = hypothesis.times.count
        slots[index].boundaryReason = reason
        return [TrackingEvent(kind: inferred ? .slotInferred : .slotCommitted, time: time, hackID: hackID, slotIndex: index,
                              glyph: hypothesis.glyph, reason: reason, sampleCount: hypothesis.times.count)]
    }

    // MARK: - Shapes

    /// Text tells us this is a presentation; a clear-array interval segments
    /// the visible shapes. Neither supplies verified positions or total length.
    private mutating func applyFallback(_ evidence: FrameEvidence) -> [TrackingEvent] {
        guard state == .presenting, !isFrozen, evidence.hasValidCalibration,
              evidence.slots == nil else { blankSince = nil; return [] }
        // Only enter the fallback from actual presentation text, not a retained
        // phase that might now be command entry or player input.
        guard phaseSource == .headerText else { blankSince = nil; return [] }
        if inferredFromIndex == nil {
            let first = currentSlotIndex ?? slots.firstIndex(where: { !$0.isSettled }) ?? slots.count
            inferredFromIndex = first
            nextInferredIndex = first
        }
        if evidence.shape.kind == .noStroke {
            if blankSince == nil { blankSince = evidence.time }
            if let since = blankSince, evidence.time - since >= policy.minimumBlankInterval,
               let index = currentSlotIndex, !hypotheses.isEmpty {
                let events = finalizeCurrentSlot(at: evidence.time,
                                                reason: "clear array during presentation; position unverified")
                nextInferredIndex = index + 1
                return events
            }
            return []
        }
        blankSince = nil
        if evidence.shape.kind == .uniqueVisibleShape, currentSlotIndex == nil,
           let index = nextInferredIndex, index < (expectedSlotCount ?? SequenceTable.maximumLength) {
            return openSlot(index, at: evidence.time)
        }
        return []
    }

    private mutating func applyShape(_ evidence: FrameEvidence) -> [TrackingEvent] {
        // Player strokes, command gestures and anything drawn while the phase
        // is in doubt are all dropped here, before they can reach a slot.
        guard state == .presenting, phaseSource != .none, let index = currentSlotIndex,
              evidence.hasValidCalibration else { return [] }
        guard evidence.shape.kind == .uniqueVisibleShape, let glyph = evidence.shape.glyph else { return [] }
        guard !slots[index].isSettled else { return [] }

        if let existing = hypotheses.firstIndex(where: { $0.glyph == glyph }) {
            // Only a genuinely later source frame is another observation.
            if let last = hypotheses[existing].times.last, evidence.time <= last { return [] }
            hypotheses[existing].times.append(evidence.time)
        } else {
            hypotheses.append(Hypothesis(glyph: glyph, edges: evidence.shape.edges, times: [evidence.time]))
        }
        slots[index].status = .observing
        slots[index].firstSampleTime = slots[index].firstSampleTime ?? evidence.time
        slots[index].lastSampleTime = evidence.time
        return []
    }

    /// Drops a sequence that belongs to a finished or unobserved hack, keeping
    /// the tracker's own phase state. Silent when there is nothing to drop, so
    /// it can be called on every command frame.
    private mutating func discardRetainedSequence(at time: Double, reason: String) -> [TrackingEvent] {
        guard !slots.isEmpty || !slotCountVotes.isEmpty else { return [] }
        let discarded = slots.compactMap(\.glyph).map(\.name).joined(separator: ",")
        slots = []
        hypotheses = []
        slotCountVotes = [:]
        slotCountConflict = false
        currentSlotIndex = nil
        inputSlotIndex = nil
        inputHighlightTime = nil
        isFrozen = false
        inferredFromIndex = nil
        nextInferredIndex = nil
        blankSince = nil
        return [TrackingEvent(kind: .evidenceInvalidated, time: time, hackID: hackID,
                              reason: discarded.isEmpty ? reason : "\(reason); discarded \(discarded)")]
    }

    private mutating func invalidateTentative(at time: Double, reason: String) -> [TrackingEvent] {
        indicatorPrelude = nil
        indicatorPhaseAnchor = nil
        blankSince = nil
        nextInferredIndex = nil
        guard !hypotheses.isEmpty || currentSlotIndex != nil else { return [] }
        hypotheses = []
        if let index = currentSlotIndex, !slots[index].isSettled {
            slots[index].status = .pending
            slots[index].firstSampleTime = nil
            slots[index].lastSampleTime = nil
        }
        currentSlotIndex = nil
        return [TrackingEvent(kind: .evidenceInvalidated, time: time, hackID: hackID, reason: reason)]
    }
}
