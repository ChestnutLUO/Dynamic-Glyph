import GlyphCoreCxx
import GlyphRecognition

/// The C++ arm of player input validation, over `glyph_logic_input.h`. Same
/// inputs and outputs as `PlayerInputValidator`; the rules run in C++.
///
/// A reference type around a C++ handle, so a copy shares its state, unlike
/// the Swift struct. Not thread-safe: one serial queue owns it, as it owns
/// the Swift value.
public final class CxxPlayerInputValidator: PlayerInputValidating {
    public let sessionID: CaptureSessionID
    public let policy: PlayerInputValidator.Policy
    private let pointer: OpaquePointer
    /// Glyph index to Glyph: the table's name-sorted list.
    private let glyphs: [GlyphID]
    private let indexByGlyph: [GlyphID: Int32]
    private var cachedResults: [InputCheckResult] = []
    private var cachedRevision = 0

    public convenience init(table: GlyphTable, sessionID: CaptureSessionID) {
        self.init(table: table, sessionID: sessionID, policy: PlayerInputValidator.Policy())
    }

    public init(table: GlyphTable, sessionID: CaptureSessionID, policy: PlayerInputValidator.Policy) {
        self.sessionID = sessionID
        self.policy = policy
        // The same normalized templates the Swift validator compares with.
        let recognizer = GlyphFrameRecognizer(table: table)
        let known = table.glyphs.compactMap { id in recognizer.expectedEdges(for: id).map { (id, $0) } }
        glyphs = known.map(\.0)
        indexByGlyph = Dictionary(uniqueKeysWithValues: known.enumerated().map { ($0.element.0, Int32($0.offset)) })
        let templates = known.map { InputEdgeSets.set($0.1) }
        var corePolicy = gl_input_policy(minimumSamples: Int64(policy.minimumSamples), minimumSpan: policy.minimumSpan,
                                         minimumDifferingSamples: Int64(policy.minimumDifferingSamples),
                                         minimumDifferingSpan: policy.minimumDifferingSpan,
                                         minimumPartialCoverage: policy.minimumPartialCoverage,
                                         maximumFrameGap: policy.maximumFrameGap)
        let created = templates.withUnsafeBufferPointer { buffer in
            gl_input_validator_create(buffer.baseAddress, Int32(buffer.count), sessionID.rawValue, &corePolicy)
        }
        guard let created else { preconditionFailure("gl_input_validator_create refused \(templates.count) Glyphs") }
        pointer = created
    }

    deinit { gl_input_validator_destroy(pointer) }

    /// `PlayerInputValidator.results`. Every change to the results bumps the
    /// revision, so they are read across the ABI only when it moved.
    public var results: [InputCheckResult] {
        refreshResults()
        return cachedResults
    }

    public var revision: Int { Int(gl_input_validator_revision(pointer)) }

    @discardableResult
    public func accept(_ evidence: FrameEvidence, tracker: some PresentationTracking,
                       edgeEvidence: [GlyphEdgeEvidence]) -> [InputCheckEvent] {
        let context = PlayerInputValidator.Context(tracker)
        return call(evidence, context: context, edgeEvidence: edgeEvidence) { frame, coreContext, evidence, count, events in
            gl_input_validator_accept_tracker(pointer, tracker.sessionID.rawValue, frame, coreContext, evidence, count, events)
        }
    }

    @discardableResult
    public func accept(_ evidence: FrameEvidence, context: PlayerInputValidator.Context,
                       edgeEvidence: [GlyphEdgeEvidence]) -> [InputCheckEvent] {
        call(evidence, context: context, edgeEvidence: edgeEvidence) { frame, coreContext, evidence, count, events in
            gl_input_validator_accept(pointer, frame, coreContext, evidence, count, events)
        }
    }

    @discardableResult
    public func finish(at time: Double) -> [InputCheckEvent] {
        var count: Int32 = 0
        let events = gl_input_validator_finish(pointer, time, &count)
        return convert(events, count: count)
    }

    // MARK: - Values across the ABI

    private typealias CoreAccept = (UnsafePointer<gl_input_frame>, UnsafePointer<gl_input_context>,
                                    UnsafePointer<gl_input_edge_evidence>?, Int32,
                                    UnsafeMutablePointer<Int32>) -> UnsafePointer<gl_input_event>?

    private func call(_ evidence: FrameEvidence, context: PlayerInputValidator.Context,
                      edgeEvidence: [GlyphEdgeEvidence], _ body: CoreAccept) -> [InputCheckEvent] {
        var frame = gl_input_frame(
            sessionID: evidence.sessionID.rawValue, time: evidence.time,
            hasSlots: evidence.slots != nil, slotCount: Int64(evidence.slots?.slotCount ?? 0),
            hasHighlightedIndex: evidence.slots?.highlightedIndex != nil,
            highlightedIndex: Int64(evidence.slots?.highlightedIndex ?? 0),
            shapeAvailable: evidence.shape.kind != .unavailable, shapeNoStroke: evidence.shape.kind == .noStroke,
            hasValidCalibration: evidence.hasValidCalibration)
        let slots = context.slots.map { slot in
            gl_input_slot(index: Int64(slot.index), isConfirmed: slot.status == .confirmed,
                          glyph: slot.glyph.flatMap { indexByGlyph[$0] } ?? -1)
        }
        // Every edge's samples back to back, each edge pointing at its run.
        let flat = edgeEvidence.flatMap(\.samples)
        var count: Int32 = 0
        let events: UnsafePointer<gl_input_event>? = slots.withUnsafeBufferPointer { slotBuffer in
            flat.withUnsafeBufferPointer { sampleBuffer in
                var offset = 0
                let coreEvidence = edgeEvidence.map { item -> gl_input_edge_evidence in
                    defer { offset += item.samples.count }
                    return gl_input_edge_evidence(lower: UInt8(item.edge.lower.rawValue),
                                                  upper: UInt8(item.edge.upper.rawValue),
                                                  samples: sampleBuffer.baseAddress.map { $0 + offset },
                                                  sampleCount: Int32(item.samples.count))
                }
                var coreContext = gl_input_context(
                    isInputState: context.state == .input, hackID: Int64(context.hackID),
                    slots: slotBuffer.baseAddress, slotObservationCount: Int32(slotBuffer.count),
                    hasExpectedSlotCount: context.expectedSlotCount != nil,
                    expectedSlotCount: Int64(context.expectedSlotCount ?? 0),
                    observedPresentation: context.observedPresentation,
                    slotCountConflict: context.slotCountConflict, indicatorsObstructed: context.indicatorsObstructed)
                return coreEvidence.withUnsafeBufferPointer { evidenceBuffer in
                    body(&frame, &coreContext, evidenceBuffer.baseAddress, Int32(evidenceBuffer.count), &count)
                }
            }
        }
        return convert(events, count: count)
    }

    private func convert(_ events: UnsafePointer<gl_input_event>?, count: Int32) -> [InputCheckEvent] {
        guard let events, count > 0 else { return [] }
        return UnsafeBufferPointer(start: events, count: Int(count)).map { event in
            InputCheckEvent.bridged(
                kind: Self.kind(event.kind), time: event.time, hackID: Int(event.hackID),
                slotIndex: Int(event.slotIndex), attemptID: Int(event.attemptID), reason: Self.reason(event.reason),
                result: event.hasResult ? result(event.result) : nil,
                edgeEvidence: event.edgeEvidence.map { base in
                    UnsafeBufferPointer(start: base, count: Int(event.edgeEvidenceCount)).map { item in
                        GlyphEdgeEvidence.bridged(
                            edge: GlyphPath.Edge(NodeIndex(rawValue: Int(item.lower))!,
                                                 NodeIndex(rawValue: Int(item.upper))!),
                            samples: item.samples.map { Array(UnsafeBufferPointer(start: $0, count: Int(item.sampleCount))) }
                                ?? [])
                    }
                } ?? [])
        }
    }

    private func refreshResults() {
        let current = revision
        guard current != cachedRevision else { return }
        var count: Int32 = 0
        let base = gl_input_validator_results(pointer, &count)
        cachedResults = base.map { UnsafeBufferPointer(start: $0, count: Int(count)).map(result) } ?? []
        cachedRevision = current
    }

    private func result(_ value: gl_input_result) -> InputCheckResult {
        InputCheckResult.bridged(
            sessionID: CaptureSessionID(rawValue: value.sessionID), hackID: Int(value.hackID),
            slotIndex: Int(value.slotIndex), attemptID: Int(value.attemptID),
            expectedGlyph: glyphs[Int(value.expectedGlyph)], verdict: Self.verdict(value.verdict),
            reason: Self.reason(value.reason), sourceTime: value.sourceTime,
            startTime: value.startTime.has ? value.startTime.value : nil,
            liftTime: value.liftTime.has ? value.liftTime.value : nil,
            samples: value.samples.map { base in
                UnsafeBufferPointer(start: base, count: Int(value.sampleCount)).map { sample in
                    InputCheckSample.bridged(time: sample.time, edges: InputEdgeSets.edges(sample.edges),
                                             partialEdges: InputEdgeSets.edges(sample.partialEdges))
                }
            } ?? [],
            windowEnd: Self.windowEnd(value.windowEnd))
    }

    private static func kind(_ value: gl_input_event_kind) -> InputCheckEvent.Kind {
        switch value {
        case GL_INPUT_EVENT_STARTED: return .started
        case GL_INPUT_EVENT_DRAWING_SAMPLE: return .drawingSample
        case GL_INPUT_EVENT_LIFTED: return .lifted
        case GL_INPUT_EVENT_SAMPLE: return .sample
        case GL_INPUT_EVENT_VERDICT: return .verdict
        case GL_INPUT_EVENT_FINISHED: return .finished
        default: return .unchecked
        }
    }

    private static func verdict(_ value: gl_input_verdict) -> InputCheckVerdict {
        switch value {
        case GL_INPUT_VERDICT_MATCHED: return .matched
        case GL_INPUT_VERDICT_DIFFERS: return .differs
        default: return .unavailable
        }
    }

    private static func windowEnd(_ value: gl_input_window_end) -> InputCheckWindowEnd {
        switch value {
        case GL_INPUT_WINDOW_END_OPEN: return .open
        case GL_INPUT_WINDOW_END_CLEAR_ARRAY: return .clearArray
        default: return .interrupted
        }
    }

    /// `gl_input_reason` minus its NONE, in `InputCheckUnavailableReason`'s order.
    private static let reasons: [InputCheckUnavailableReason] = [
        .missedStart, .unconfirmedExpectation, .lastSlot, .multiSlotJump, .backwardMove,
        .shortWindow, .disagreeingSamples, .frameGap, .stripLoss, .phaseChange,
        .invalidCalibration, .slotCountConflict, .ambiguousBoundary, .endOfStream,
        .unclosedWindow, .partialEdge
    ]

    private static func reason(_ value: gl_input_reason) -> InputCheckUnavailableReason? {
        let index = Int(value.rawValue)
        return index >= 1 && index <= reasons.count ? reasons[index - 1] : nil
    }
}

/// `Set<GlyphPath.Edge>` as the core's 128-bit mask, bit `lower * 11 + upper`.
enum InputEdgeSets {
    private static let edgeByBit: [GlyphPath.Edge?] = (0..<128).map { bit in
        let lower = bit / NodeIndex.count, upper = bit % NodeIndex.count
        guard lower <= upper, let a = NodeIndex(rawValue: lower), let b = NodeIndex(rawValue: upper) else { return nil }
        return GlyphPath.Edge(a, b)
    }

    static func set(_ edges: Set<GlyphPath.Edge>) -> gl_input_edge_set {
        var bits: (UInt64, UInt64) = (0, 0)
        for edge in edges {
            let bit = edge.lower.rawValue * NodeIndex.count + edge.upper.rawValue
            if bit < 64 { bits.0 |= 1 << UInt64(bit) } else { bits.1 |= 1 << UInt64(bit - 64) }
        }
        return gl_input_edge_set(bits: bits)
    }

    static func edges(_ set: gl_input_edge_set) -> Set<GlyphPath.Edge> {
        var edges = Set<GlyphPath.Edge>()
        for (word, value) in [set.bits.0, set.bits.1].enumerated() where value != 0 {
            for offset in 0..<64 where value & (1 << UInt64(offset)) != 0 {
                if let edge = edgeByBit[word * 64 + offset] { edges.insert(edge) }
            }
        }
        return edges
    }
}

/// The C++ arm of sequence prediction, over `glyph_logic_input.h`.
///
/// Glyph indices across the ABI are into this predictor's own vocabulary:
/// every name in the sequence table, sorted as `GlyphID` sorts. An observed
/// Glyph outside it matches no sequence, as in Swift. Not thread-safe: an
/// outlook reuses the handle's buffers.
public final class CxxSequencePredictor: SequencePredicting {
    private let pointer: OpaquePointer
    private let vocabulary: [GlyphID]
    private let indexByGlyph: [GlyphID: Int32]

    public init(table: SequenceTable) {
        let vocabulary = Set(table.sequences.joined()).sorted()
        let indexByGlyph = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($0.element, Int32($0.offset)) })
        self.vocabulary = vocabulary
        self.indexByGlyph = indexByGlyph
        // Names and sequences each back to back, every entry pointing at its run.
        let names = vocabulary.map { $0.name.utf8.map { CChar(bitPattern: $0) } }
        let nameBytes = Array(names.joined())
        let sequences = table.sequences.map { $0.map { indexByGlyph[$0]! } }
        let sequenceIndices = Array(sequences.joined())
        let lengths = sequences.map { Int32($0.count) }
        let created: OpaquePointer? = nameBytes.withUnsafeBufferPointer { byteBuffer in
            sequenceIndices.withUnsafeBufferPointer { indexBuffer in
                var byteOffset = 0
                let strings = names.map { name -> gc_string in
                    defer { byteOffset += name.count }
                    return gc_string(bytes: byteBuffer.baseAddress.map { $0 + byteOffset }, length: Int32(name.count))
                }
                var indexOffset = 0
                let starts = sequences.map { sequence -> UnsafePointer<Int32>? in
                    defer { indexOffset += sequence.count }
                    return indexBuffer.baseAddress.map { $0 + indexOffset }
                }
                return strings.withUnsafeBufferPointer { stringBuffer in
                    starts.withUnsafeBufferPointer { startBuffer in
                        lengths.withUnsafeBufferPointer { lengthBuffer in
                            gl_sequence_predictor_create(stringBuffer.baseAddress, Int32(stringBuffer.count),
                                                         startBuffer.baseAddress, lengthBuffer.baseAddress,
                                                         Int32(lengthBuffer.count))
                        }
                    }
                }
            }
        }
        guard let created else { preconditionFailure("gl_sequence_predictor_create refused the table") }
        pointer = created
    }

    deinit { gl_sequence_predictor_destroy(pointer) }

    public func outlook(observed: [GlyphID], expectedLength: Int?) -> SequenceOutlook {
        outlook(observed: observed, expectedLength: expectedLength, displayCandidateLimit: 8)
    }

    /// `SequencePredictor.outlook(observed:expectedLength:displayCandidateLimit:)`.
    public func outlook(observed: [GlyphID], expectedLength: Int?, displayCandidateLimit: Int) -> SequenceOutlook {
        precondition(displayCandidateLimit >= 0, "Can't take a prefix of negative length")
        let indices = observed.map { indexByGlyph[$0] ?? -1 }
        var out = gl_sequence_outlook()
        let done = indices.withUnsafeBufferPointer { buffer in
            gl_sequence_predictor_outlook(pointer, buffer.baseAddress, Int32(buffer.count), expectedLength != nil,
                                          Int64(expectedLength ?? 0), Int32(clamping: displayCandidateLimit), &out)
        }
        precondition(done, "gl_sequence_predictor_outlook refused its arguments")
        func glyphs(_ list: gl_glyph_list) -> [GlyphID] {
            guard let base = list.glyphs, list.count > 0 else { return [] }
            return UnsafeBufferPointer(start: base, count: Int(list.count)).map { vocabulary[Int($0)] }
        }
        let echoed: [GlyphID] = out.observed.glyphs.map { base in
            UnsafeBufferPointer(start: base, count: Int(out.observed.count)).enumerated().map { position, index in
                index >= 0 ? vocabulary[Int(index)] : observed[position]
            }
        } ?? []
        let candidates = out.candidates.map { base in
            UnsafeBufferPointer(start: base, count: Int(out.shownCandidateCount)).map {
                SequenceCandidate(glyphs: glyphs($0.glyphs), weight: $0.weight)
            }
        } ?? []
        let alternatives = out.suffixAlternatives.map { base in
            UnsafeBufferPointer(start: base, count: Int(out.suffixAlternativeCount)).map(glyphs)
        } ?? []
        return SequenceOutlook(state: Self.state(out.state), observed: echoed,
                               expectedLength: out.hasExpectedLength ? Int(out.expectedLength) : nil,
                               candidateCount: Int(out.candidateCount), candidates: candidates,
                               predictedSuffix: glyphs(out.predictedSuffix), suffixAlternatives: alternatives,
                               observationMayBeComplete: out.observationMayBeComplete)
    }

    private static func state(_ value: gl_prediction_state) -> PredictionState {
        switch value {
        case GL_PREDICTION_STATE_UNOBSERVED: return .unobserved
        case GL_PREDICTION_STATE_AMBIGUOUS: return .ambiguous
        case GL_PREDICTION_STATE_RESOLVED: return .resolved
        case GL_PREDICTION_STATE_CONTRADICTED: return .contradicted
        case GL_PREDICTION_STATE_LENGTH_CONFLICT: return .lengthConflict
        default: return .unavailable
        }
    }
}
