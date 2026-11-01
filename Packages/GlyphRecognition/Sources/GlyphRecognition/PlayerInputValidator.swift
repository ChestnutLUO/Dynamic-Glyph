public enum InputCheckVerdict: String, Sendable, Hashable, Codable {
    case matched, differs, unavailable

    public var symbol: String {
        switch self {
        case .matched: return "✓"
        case .differs: return "!"
        case .unavailable: return "?"
        }
    }
}

public enum InputCheckUnavailableReason: String, Sendable, Hashable {
    case missedStart, unconfirmedExpectation, lastSlot, multiSlotJump, backwardMove
    case shortWindow, disagreeingSamples, frameGap, stripLoss, phaseChange
    case invalidCalibration, slotCountConflict, ambiguousBoundary, endOfStream
    /// The next slot advanced before any clear closed this attempt's window.
    case unclosedWindow
    /// The drawing read as missing an edge that was partly lit: drawn, most
    /// likely, but too bowed for the recognizer to accept.
    case partialEdge
}

public enum InputCheckWindowEnd: String, Sendable {
    /// Published from agreeing samples while the drawing is still on screen.
    case open
    case clearArray, interrupted
}

/// A completed comparison, attached to an attempt rather than the current highlight.
public struct InputCheckResult: Sendable, Equatable {
    public let sessionID: CaptureSessionID
    public let hackID: Int
    public let slotIndex: Int
    public let attemptID: Int
    public let expectedGlyph: GlyphID
    public let verdict: InputCheckVerdict
    public let reason: InputCheckUnavailableReason?
    public let sourceTime: Double
    public let startTime: Double?
    public let liftTime: Double?
    public let samples: [InputCheckSample]
    public var windowEnd: InputCheckWindowEnd = .interrupted
}

public struct InputCheckSample: Sendable, Equatable {
    public let time: Double
    public let edges: Set<GlyphPath.Edge>
    /// Edges below the recognizer's threshold that were still substantially
    /// lit, so neither present nor clearly absent.
    public var partialEdges: Set<GlyphPath.Edge> = []
}

/// Diagnostic transitions include unchecked attempts, which need no display mark.
public struct InputCheckEvent: Sendable {
    public enum Kind: String, Sendable { case started, drawingSample, lifted, sample, verdict, finished, unchecked }
    public let kind: Kind
    public let time: Double
    public let hackID: Int
    public let slotIndex: Int
    public let attemptID: Int
    public let reason: InputCheckUnavailableReason?
    public let result: InputCheckResult?
    public let edgeEvidence: [GlyphEdgeEvidence]
}

/// Validates only the post-lift drawing. Never feeds observations back into
/// presentation tracking and never unions the player's moving trail.
///
/// The post-lift window is read as runs of identical edge sets. A run shorter
/// than `minimumSamples` / `minimumSpan` is the stroke settling, not a reading:
/// in the recording a correct `shield` kept a stray `4-a` for its first two
/// post-lift samples and a correct `mind` lacked `5-a` for its first four.
/// Only stable runs vote. A match is published as soon as one exists, so it
/// can be seen before the player starts the next Glyph; a mismatch needs a
/// longer run and a clear that closes the window, because a false error costs
/// more than a late one.
public struct PlayerInputValidator: Sendable {
    public struct Policy: Sendable {
        public var minimumSamples = 3
        public var minimumSpan = 0.1
        public var minimumDifferingSamples = 5
        public var minimumDifferingSpan = 0.2
        /// An edge short of the recognizer's 80% with at least this much of
        /// its length lit may well have been drawn. A freehand stroke bows away
        /// from the straight line sampled between two nodes: a correct `truth`
        /// read its 3-5 edge at 58-79% in every frame after lift. Such an edge
        /// cannot count as missing. 30% is a starting point, above the partial
        /// support undrawn edges showed in the recordings, not a tuned value.
        public var minimumPartialCoverage = 0.3
        /// More than two nominal 20 Hz sampling intervals breaks continuity.
        public var maximumFrameGap = 0.1
        public init() {}
    }

    /// An immutable view also allows boundary rules to be tested without
    /// constructing a presentation from pixels in every input test.
    public struct Context: Sendable {
        public let state: TrackingState
        public let hackID: Int
        public let slots: [SlotObservation]
        public let expectedSlotCount: Int?
        public let observedPresentation: Bool
        public let slotCountConflict: Bool
        public let indicatorsObstructed: Bool

        public init(state: TrackingState, hackID: Int, slots: [SlotObservation],
                    expectedSlotCount: Int?, observedPresentation: Bool,
                    slotCountConflict: Bool = false, indicatorsObstructed: Bool = false) {
            self.state = state
            self.hackID = hackID
            self.slots = slots
            self.expectedSlotCount = expectedSlotCount
            self.observedPresentation = observedPresentation
            self.slotCountConflict = slotCountConflict
            self.indicatorsObstructed = indicatorsObstructed
        }

        public init(_ tracker: PresentationTracker) {
            self.init(state: tracker.state, hackID: tracker.hackID, slots: tracker.slots,
                      expectedSlotCount: tracker.expectedSlotCount,
                      observedPresentation: tracker.observedPresentationForCurrentHack,
                      slotCountConflict: tracker.slotCountConflict,
                      indicatorsObstructed: tracker.indicatorsObstructed)
        }
    }

    private struct Attempt: Sendable {
        let index: Int
        let id: Int
        let glyph: GlyphID
        let expected: Set<GlyphPath.Edge>
        let start: Double?
        var lift: Double?
        var samples: [InputCheckSample] = []
        /// The verdict shown while the window is still open, if any.
        var published: InputCheckResult?
    }

    private struct Sample: Sendable {
        let time: Double
        let clear: Bool
        let edges: [GlyphEdgeEvidence]

        /// The previous drawing is gone. Touch-down on the next stroke can
        /// erase it and add new ink within one 20 Hz sample, so ink that
        /// reaches no lattice edge ends a post-lift window as a clear does.
        var showsNoDrawing: Bool { clear || !edges.contains(where: \.isPresent) }
    }

    public let sessionID: CaptureSessionID
    public let policy: Policy
    public private(set) var results: [InputCheckResult] = []
    public private(set) var revision = 0
    private let recognizer: GlyphFrameRecognizer
    private var hackID: Int?
    private var previousTime: Double?
    private var index: Int?
    private var clearTime: Double?
    private var attempt: Attempt?
    private var pendingIndex: Int?
    private var pendingSample: Sample?
    private var awaitingClear = false
    private var nextAttemptID = 0
    private var events: [InputCheckEvent] = []

    public init(table: GlyphTable, sessionID: CaptureSessionID, policy: Policy = Policy()) {
        self.sessionID = sessionID
        self.policy = policy
        recognizer = GlyphFrameRecognizer(table: table)
    }

    @discardableResult
    public mutating func accept(_ evidence: FrameEvidence, tracker: PresentationTracker,
                                edgeEvidence: [GlyphEdgeEvidence]) -> [InputCheckEvent] {
        guard tracker.sessionID == sessionID else { return [] }
        return accept(evidence, context: Context(tracker), edgeEvidence: edgeEvidence)
    }

    @discardableResult
    public mutating func accept(_ evidence: FrameEvidence, context: Context,
                                edgeEvidence: [GlyphEdgeEvidence]) -> [InputCheckEvent] {
        events = []
        guard evidence.sessionID == sessionID else { return [] }
        guard evidence.time.isFinite else {
            invalidate(.frameGap, at: previousTime ?? 0)
            return events
        }
        if hackID != context.hackID {
            hackID = context.hackID
            if !results.isEmpty { results = []; revision += 1 }
            discardAttempt()
            previousTime = nil
        }
        if let previousTime {
            if evidence.time == previousTime { return [] }
            if evidence.time < previousTime || evidence.time - previousTime > policy.maximumFrameGap + 1e-9 {
                invalidate(.frameGap, at: evidence.time)
                self.previousTime = max(previousTime, evidence.time)
                return events
            }
        }
        previousTime = evidence.time
        guard context.state == .input, context.observedPresentation else {
            invalidate(.phaseChange, at: evidence.time)
            return events
        }
        guard !context.slotCountConflict, let count = context.expectedSlotCount else {
            invalidate(.slotCountConflict, at: evidence.time)
            return events
        }
        guard !context.indicatorsObstructed, let strip = evidence.slots,
              strip.slotCount == count, let highlighted = strip.highlightedIndex,
              highlighted >= 0, highlighted < count else {
            invalidate(.stripLoss, at: evidence.time)
            return events
        }
        guard evidence.hasValidCalibration, evidence.shape.kind != .unavailable else {
            invalidate(.invalidCalibration, at: evidence.time)
            return events
        }
        if let drawing = attempt,
           !context.slots.contains(where: {
               $0.index == drawing.index && $0.status == .confirmed && $0.glyph == drawing.glyph
           }) {
            emit(.unchecked, attempt: drawing, at: evidence.time, reason: .unconfirmedExpectation)
            if drawing.published != nil {
                results.removeAll { $0.attemptID == drawing.id }
                revision += 1
            }
            discardAttempt()
            index = highlighted
            awaitingClear = true
            return events
        }
        let sample = Sample(time: evidence.time, clear: evidence.shape.kind == .noStroke,
                            edges: edgeEvidence)
        guard let current = index else {
            index = highlighted
            consume(sample, context: context)
            return events
        }
        if highlighted != current {
            // Keep the first candidate frame; it is part of the post-lift
            // window if the next independent sample confirms this advance.
            guard pendingIndex == highlighted, let first = pendingSample else {
                if pendingIndex != nil { invalidate(.ambiguousBoundary, at: evidence.time) }
                pendingIndex = highlighted
                pendingSample = sample
                return events
            }
            pendingIndex = nil
            pendingSample = nil
            if highlighted != current + 1 {
                let reason: InputCheckUnavailableReason = highlighted < current ? .backwardMove : .multiSlotJump
                // Neither a jump nor a backward move establishes completion,
                // but a verdict already reached from agreeing samples stands.
                end(reason, at: evidence.time, showingUnavailable: false)
                if highlighted < current {
                    let retained = results.filter { $0.slotIndex < highlighted }
                    if retained != results { results = retained; revision += 1 }
                }
                discardAttempt()
                index = highlighted
                if sample.clear { clearTime = sample.time }
                return events
            }
            if attempt?.lift != nil { invalidate(.unclosedWindow, at: evidence.time) }
            if attempt == nil {
                begin(index: current, start: nil, at: first.time, context: context)
            }
            index = highlighted
            clearTime = nil
            awaitingClear = true
            if var drawing = attempt {
                drawing.lift = first.time
                attempt = drawing
                emit(.lifted, attempt: drawing, at: first.time)
            }
            consume(first, context: context)
            consume(sample, context: context)
        } else {
            if pendingIndex != nil {
                invalidate(.ambiguousBoundary, at: evidence.time)
                index = highlighted
            }
            consume(sample, context: context)
        }
        return events
    }

    /// A replay or capture can end without another frame announcing it.
    @discardableResult
    public mutating func finish(at time: Double) -> [InputCheckEvent] {
        events = []
        invalidate(.endOfStream, at: time)
        return events
    }

    private mutating func consume(_ sample: Sample, context: Context) {
        if var drawing = attempt, drawing.lift != nil {
            if sample.showsNoDrawing {
                let outcome = drawing.start == nil
                    ? (verdict: InputCheckVerdict.unavailable, reason: InputCheckUnavailableReason?.some(.missedStart))
                    : assessment(of: drawing, closed: true) ?? (.unavailable, .shortWindow)
                complete(drawing, verdict: outcome.verdict, reason: outcome.reason, at: sample.time,
                         windowEnd: .clearArray)
                attempt = nil
                clearTime = sample.time
                awaitingClear = false
            } else {
                drawing.samples.append(InputCheckSample(time: sample.time,
                    edges: Set(sample.edges.filter(\.isPresent).map(\.edge)),
                    partialEdges: Set(sample.edges.filter {
                        !$0.isPresent && $0.coverage >= policy.minimumPartialCoverage
                    }.map(\.edge))))
                emit(.sample, attempt: drawing, at: sample.time, edges: sample.edges)
                if drawing.start != nil, let outcome = assessment(of: drawing, closed: false),
                   outcome.verdict != drawing.published?.verdict || outcome.reason != drawing.published?.reason {
                    let result = makeResult(drawing, verdict: outcome.verdict, reason: outcome.reason,
                                            at: sample.time, windowEnd: .open)
                    drawing.published = result
                    store(result)
                    emit(.verdict, attempt: drawing, at: sample.time, reason: outcome.reason, result: result)
                }
                attempt = drawing
            }
            return
        }
        if awaitingClear {
            if sample.showsNoDrawing { awaitingClear = false; clearTime = sample.time }
            return
        }
        if sample.clear {
            if let attempt {
                // Clearing without an advance is not a proven submission.
                emit(.unchecked, attempt: attempt, at: sample.time, reason: .ambiguousBoundary)
                self.attempt = nil
            }
            clearTime = sample.time
        } else if attempt == nil, let index {
            begin(index: index, start: clearTime, at: sample.time, context: context, edges: sample.edges)
            clearTime = nil
        } else if let attempt {
            emit(.drawingSample, attempt: attempt, at: sample.time, edges: sample.edges)
        }
    }

    private mutating func begin(index: Int, start: Double?, at time: Double, context: Context,
                                edges: [GlyphEdgeEvidence] = []) {
        guard index < (context.expectedSlotCount ?? 0) - 1,
              let slot = context.slots.first(where: { $0.index == index }),
              slot.status == .confirmed, let glyph = slot.glyph,
              let expected = recognizer.expectedEdges(for: glyph) else { return }
        nextAttemptID += 1
        let drawing = Attempt(index: index, id: nextAttemptID, glyph: glyph,
                              expected: expected, start: start)
        attempt = drawing
        if start != nil, results.contains(where: { $0.slotIndex == index }) {
            results.removeAll { $0.slotIndex == index }
            revision += 1
        }
        emit(.started, attempt: drawing, at: time,
             reason: start == nil ? .missedStart : nil, edges: edges)
    }

    /// The verdict the post-lift samples support so far, or nil while an open
    /// window supports none yet.
    private func assessment(of drawing: Attempt, closed: Bool)
        -> (verdict: InputCheckVerdict, reason: InputCheckUnavailableReason?)? {
        typealias Run = (edges: Set<GlyphPath.Edge>, samples: [InputCheckSample])
        var runs: [Run] = []
        for sample in drawing.samples {
            if let last = runs.last, last.edges == sample.edges {
                runs[runs.count - 1].samples.append(sample)
            } else {
                runs.append((sample.edges, [sample]))
            }
        }
        func holds(_ run: Run, samples: Int, span: Double) -> Bool {
            guard let first = run.samples.first, let last = run.samples.last else { return false }
            return run.samples.count >= samples && last.time - first.time + 1e-9 >= span
        }
        // An empty set is ink without any lattice edge: not a reading of the drawing.
        let stable = runs.filter {
            !$0.edges.isEmpty && holds($0, samples: policy.minimumSamples, span: policy.minimumSpan)
        }
        let readings = Set(stable.map(\.edges))
        if readings.count > 1 { return (.unavailable, .disagreeingSamples) }
        if readings.first == drawing.expected { return (.matched, nil) }
        guard closed else { return nil }
        let differing = stable.filter {
            holds($0, samples: policy.minimumDifferingSamples, span: policy.minimumDifferingSpan)
        }
        guard !differing.isEmpty else { return (.unavailable, .shortWindow) }
        // Every stable run has the same reading here. A longer run is needed
        // to warn, but partial support in any stable run makes a missing edge
        // uncertain, even if a flicker separates it from the longer run.
        let undecided = stable.contains { run in
            let missing = drawing.expected.subtracting(run.edges)
            return run.samples.contains { !$0.partialEdges.isDisjoint(with: missing) }
        }
        return undecided ? (.unavailable, .partialEdge) : (.differs, nil)
    }

    private func makeResult(_ drawing: Attempt, verdict: InputCheckVerdict,
                            reason: InputCheckUnavailableReason?, at time: Double,
                            windowEnd: InputCheckWindowEnd) -> InputCheckResult {
        // An unchanged verdict keeps the time it was first shown, so closing
        // the window neither restarts the check mark nor moves the verdict.
        let unchanged = drawing.published.map { $0.verdict == verdict && $0.reason == reason } ?? false
        return InputCheckResult(sessionID: sessionID, hackID: hackID ?? 0,
            slotIndex: drawing.index, attemptID: drawing.id, expectedGlyph: drawing.glyph,
            verdict: verdict, reason: reason,
            sourceTime: unchanged ? drawing.published?.sourceTime ?? time : time,
            startTime: drawing.start, liftTime: drawing.lift, samples: drawing.samples,
            windowEnd: windowEnd)
    }

    private mutating func store(_ result: InputCheckResult) {
        results.removeAll { $0.slotIndex == result.slotIndex }
        results.append(result)
        results.sort { $0.slotIndex < $1.slotIndex }
        revision += 1
    }

    private mutating func complete(_ drawing: Attempt, verdict: InputCheckVerdict,
                                   reason: InputCheckUnavailableReason?, at time: Double,
                                   windowEnd: InputCheckWindowEnd = .interrupted) {
        let result = makeResult(drawing, verdict: verdict, reason: reason, at: time, windowEnd: windowEnd)
        store(result)
        emit(.finished, attempt: drawing, at: time, reason: reason, result: result)
    }

    /// Ends the open attempt without a clear. Before lift nothing is shown: the
    /// player is still drawing, and a new attempt after a lost start reports
    /// itself once it lifts. After lift a verdict already published stands.
    private mutating func end(_ reason: InputCheckUnavailableReason, at time: Double,
                              showingUnavailable: Bool) {
        guard let drawing = attempt else { return }
        attempt = nil
        if drawing.lift == nil {
            emit(.unchecked, attempt: drawing, at: time, reason: reason)
        } else if let published = drawing.published {
            complete(drawing, verdict: published.verdict, reason: published.reason, at: time)
        } else if showingUnavailable {
            complete(drawing, verdict: .unavailable, reason: reason, at: time)
        } else {
            emit(.unchecked, attempt: drawing, at: time, reason: reason)
        }
    }

    private mutating func invalidate(_ reason: InputCheckUnavailableReason, at time: Double) {
        end(reason, at: time, showingUnavailable: true)
        discardAttempt()
    }

    private mutating func discardAttempt() {
        attempt = nil
        index = nil
        clearTime = nil
        pendingIndex = nil
        pendingSample = nil
        awaitingClear = false
    }

    private mutating func emit(_ kind: InputCheckEvent.Kind, attempt: Attempt, at time: Double,
                               reason: InputCheckUnavailableReason? = nil,
                               result: InputCheckResult? = nil, edges: [GlyphEdgeEvidence] = []) {
        events.append(InputCheckEvent(kind: kind, time: time, hackID: hackID ?? 0,
            slotIndex: attempt.index, attemptID: attempt.id, reason: reason,
            result: result, edgeEvidence: edges))
    }
}
