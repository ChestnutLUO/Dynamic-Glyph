import Foundation
import GlyphCoreCxx
import GlyphRecognition

/// The C++ arm of the presentation tracker, over `glyph_logic_tracker.h`.
///
/// Glyphs cross the ABI as indices into `glyphs`, the name-sorted Glyph list
/// fixed at creation. Both arms must see the same table: a Glyph in the
/// evidence that is not in `glyphs` reaches the C++ tracker as "no Glyph",
/// where the Swift tracker would still collect it. Pass the `GlyphTable` the
/// Glyph recognizer uses (or its `glyphs`), so every recognized shape is in it.
///
/// A reference, unlike `PresentationTracker`: copying it does not snapshot
/// it. Not thread-safe; one serial queue owns it, as the Swift value was owned.
public final class CxxPresentationTracker: PresentationTracking {
    public let sessionID: CaptureSessionID
    /// Name-sorted and without duplicates: index `n` in the ABI is `glyphs[n]`.
    public let glyphs: [GlyphID]

    private let handle: OpaquePointer
    private let indexByGlyph: [GlyphID: Int32]
    // Kept between frames and grown on demand, so a steady capture does not
    // allocate them again.
    private var eventBuffer = [gl_tracking_event](repeating: gl_tracking_event(), count: 16)
    private var markerBuffer: [Double] = []
    private var partialBuffer: [Double] = []
    private var edgeBuffer: [gc_edge] = []
    private var extensionBuffer: [Int32] = []

    public init(sessionID: CaptureSessionID, policy: PresentationTracker.Policy = PresentationTracker.Policy(),
                glyphs: [GlyphID]) {
        let sorted = Array(Set(glyphs)).sorted()
        self.sessionID = sessionID
        self.glyphs = sorted
        indexByGlyph = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, Int32($0.offset)) })
        var cPolicy = Self.cPolicy(policy)
        let created = CxxStrings(sorted.map(\.name)).withStrings { names in
            gl_tracker_create(sessionID.rawValue, &cPolicy, names.baseAddress, Int32(names.count))
        }
        guard let created else { preconditionFailure("gl_tracker_create failed") }
        handle = created
    }

    /// The Glyphs of `table`, the table the shape evidence was recognized with.
    public convenience init(sessionID: CaptureSessionID,
                            policy: PresentationTracker.Policy = PresentationTracker.Policy(),
                            table: GlyphTable) {
        self.init(sessionID: sessionID, policy: policy, glyphs: table.glyphs)
    }

    deinit { gl_tracker_destroy(handle) }

    // MARK: - PresentationTracking

    public var policy: PresentationTracker.Policy { Self.policy(gl_tracker_policy(handle)) }
    public var state: TrackingState { Self.state(gl_tracker_state(handle)) }
    public var phaseSource: PhaseSource { Self.source(gl_tracker_phase_source(handle)) }
    public var hackID: Int { Int(gl_tracker_hack_id(handle)) }
    public var revision: Int { Int(gl_tracker_revision(handle)) }
    public var lastEvidenceTime: Double? { Self.optional(gl_tracker_last_evidence_time(handle)) }
    public var lastPhaseTime: Double? { Self.optional(gl_tracker_last_phase_time(handle)) }
    public var lastIndicatorTime: Double? { Self.optional(gl_tracker_last_indicator_time(handle)) }
    public var expectedSlotCount: Int? { Self.optional(gl_tracker_expected_slot_count(handle)) }
    public var currentSlotIndex: Int? { Self.optional(gl_tracker_current_slot_index(handle)) }
    public var inputSlotIndex: Int? { Self.optional(gl_tracker_input_slot_index(handle)) }
    public var indicatorsObstructed: Bool { gl_tracker_indicators_obstructed(handle) }
    public var slotCountConflict: Bool { gl_tracker_slot_count_conflict(handle) }
    public var isFrozen: Bool { gl_tracker_is_frozen(handle) }
    public var observedPresentationForCurrentHack: Bool { gl_tracker_observed_presentation_for_current_hack(handle) }

    public var slots: [SlotObservation] {
        let count = Int(gl_tracker_slots(handle, nil, 0))
        guard count > 0 else { return [] }
        var buffer = [gl_slot_observation](repeating: gl_slot_observation(), count: count)
        _ = buffer.withUnsafeMutableBufferPointer { gl_tracker_slots(handle, $0.baseAddress, Int32(count)) }
        return buffer.map { slot in
            let alternatives: [GlyphID] = (0..<Int(slot.alternativeCount)).compactMap { index in
                slot.alternatives.flatMap { glyph($0[index]) }
            }
            return SlotObservation(index: Int(slot.index), status: Self.status(slot.status), glyph: glyph(slot.glyph),
                                   alternatives: alternatives,
                                   firstSampleTime: Self.optional(slot.firstSampleTime),
                                   lastSampleTime: Self.optional(slot.lastSampleTime),
                                   sampleCount: Int(slot.sampleCount),
                                   boundaryReason: slot.hasBoundaryReason ? Self.string(slot.boundaryReason) : nil)
        }
    }

    public var confirmedPrefix: [GlyphID] {
        let count = Int(gl_tracker_confirmed_prefix(handle, nil, 0))
        guard count > 0 else { return [] }
        var buffer = [Int32](repeating: -1, count: count)
        _ = buffer.withUnsafeMutableBufferPointer { gl_tracker_confirmed_prefix(handle, $0.baseAddress, Int32(count)) }
        return buffer.compactMap(glyph)
    }

    @discardableResult
    public func accept(_ evidence: FrameEvidence) -> [TrackingEvent] {
        markerBuffer.removeAll(keepingCapacity: true)
        partialBuffer.removeAll(keepingCapacity: true)
        edgeBuffer.removeAll(keepingCapacity: true)
        extensionBuffer.removeAll(keepingCapacity: true)
        if let slots = evidence.slots { markerBuffer.append(contentsOf: slots.markerCentersX) }
        if let partial = evidence.partialSlots { partialBuffer.append(contentsOf: partial.markerCentersX) }
        for edge in evidence.shape.edges {
            edgeBuffer.append(gc_edge(lower: UInt8(clamping: edge.lower.rawValue), upper: UInt8(clamping: edge.upper.rawValue)))
        }
        for id in evidence.shape.extensions { if let index = indexByGlyph[id] { extensionBuffer.append(index) } }

        var frame = gl_frame_evidence()
        frame.sessionID = evidence.sessionID.rawValue
        frame.time = evidence.time
        if let header = evidence.header {
            frame.hasHeader = true
            frame.header.phase = Self.cPhase(header.phase)
            frame.header.confidence = header.confidence
            frame.header.sourceTime = header.sourceTime
        }
        if let slots = evidence.slots {
            frame.hasSlots = true
            frame.slots.slotCount = Int32(clamping: slots.slotCount)
            frame.slots.highlightedIndex = Self.cOptional(slots.highlightedIndex)
            frame.slots.markerCount = Int32(clamping: slots.markerCentersX.count)
            frame.slots.hasInputTimerBar = slots.hasInputTimerBar
            frame.slots.isPartlyCovered = slots.isPartlyCovered
        }
        frame.slotRejection = Self.cRejection(evidence.slotRejection)
        frame.shape.kind = Self.cShapeKind(evidence.shape.kind)
        frame.shape.glyph = evidence.shape.glyph.flatMap { indexByGlyph[$0] } ?? -1
        frame.shape.edgeCount = Int32(edgeBuffer.count)
        frame.shape.extensionCount = Int32(extensionBuffer.count)
        frame.hasValidCalibration = evidence.hasValidCalibration
        frame.hasInputTimerBar = evidence.hasInputTimerBar
        if let partial = evidence.partialSlots {
            frame.hasPartialSlots = true
            frame.partialSlots = Self.cPartial(partial)
        }
        frame.hasPartialInputTimerBar = evidence.hasPartialInputTimerBar

        var matchedText = evidence.header?.matchedText ?? ""
        let count = matchedText.withUTF8 { text in
            markerBuffer.withUnsafeBufferPointer { markers in
                partialBuffer.withUnsafeBufferPointer { partial in
                    edgeBuffer.withUnsafeBufferPointer { edges in
                        extensionBuffer.withUnsafeBufferPointer { extensions in
                            frame.header.matchedText = gc_string(
                                bytes: text.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                length: Int32(text.count))
                            frame.slots.markerCentersX = markers.baseAddress
                            frame.partialSlots.markerCentersX = partial.baseAddress
                            frame.shape.edges = edges.baseAddress
                            frame.shape.extensions = extensions.baseAddress
                            return eventBuffer.withUnsafeMutableBufferPointer { out in
                                Int(gl_tracker_accept(handle, &frame, out.baseAddress, Int32(out.count)))
                            }
                        }
                    }
                }
            }
        }
        if count > eventBuffer.count {
            eventBuffer = [gl_tracking_event](repeating: gl_tracking_event(), count: count)
            _ = eventBuffer.withUnsafeMutableBufferPointer { gl_tracker_last_events(handle, $0.baseAddress, Int32(count)) }
        }
        return eventBuffer.prefix(count).map(event)
    }

    public func invalidatePhase() { gl_tracker_invalidate_phase(handle) }

    public func reset() { gl_tracker_reset(handle) }

    // MARK: - Conversion

    private func glyph(_ index: Int32) -> GlyphID? {
        index >= 0 && Int(index) < glyphs.count ? glyphs[Int(index)] : nil
    }

    private func event(_ event: gl_tracking_event) -> TrackingEvent {
        TrackingEvent(kind: Self.kind(event.kind), time: event.time, hackID: Int(event.hackID),
                      slotIndex: Self.optional(event.slotIndex), glyph: glyph(event.glyph),
                      reason: Self.string(event.reason), sampleCount: Int(event.sampleCount))
    }

    static func string(_ text: gc_string) -> String {
        guard let bytes = text.bytes, text.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.length)), as: UTF8.self)
    }

    private static func optional(_ value: gc_opt_double) -> Double? { value.has ? value.value : nil }
    private static func optional(_ value: gc_opt_int32) -> Int? { value.has ? Int(value.value) : nil }

    private static func cOptional(_ value: Int?) -> gc_opt_int32 {
        value.map { gc_opt_int32(has: true, value: Int32(clamping: $0)) } ?? gc_opt_int32(has: false, value: 0)
    }

    static func cPolicy(_ policy: PresentationTracker.Policy) -> gl_tracking_policy {
        gl_tracking_policy(minimumStableInterval: policy.minimumStableInterval,
                           minimumStableSamples: Int32(clamping: policy.minimumStableSamples),
                           maximumFrameGap: policy.maximumFrameGap,
                           unknownPhaseGrace: policy.unknownPhaseGrace,
                           stalenessThreshold: policy.stalenessThreshold,
                           slotCountVotesRequired: Int32(clamping: policy.slotCountVotesRequired),
                           indicatorObstructionGrace: policy.indicatorObstructionGrace,
                           minimumBlankInterval: policy.minimumBlankInterval,
                           entersPresentationFromIndicators: policy.entersPresentationFromIndicators,
                           closesLastSlotOnRelease: policy.closesLastSlotOnRelease,
                           minimumStripAbsenceForNewHack: policy.minimumStripAbsenceForNewHack)
    }

    static func policy(_ c: gl_tracking_policy) -> PresentationTracker.Policy {
        var policy = PresentationTracker.Policy()
        policy.minimumStableInterval = c.minimumStableInterval
        policy.minimumStableSamples = Int(c.minimumStableSamples)
        policy.maximumFrameGap = c.maximumFrameGap
        policy.unknownPhaseGrace = c.unknownPhaseGrace
        policy.stalenessThreshold = c.stalenessThreshold
        policy.slotCountVotesRequired = Int(c.slotCountVotesRequired)
        policy.indicatorObstructionGrace = c.indicatorObstructionGrace
        policy.minimumBlankInterval = c.minimumBlankInterval
        policy.entersPresentationFromIndicators = c.entersPresentationFromIndicators
        policy.closesLastSlotOnRelease = c.closesLastSlotOnRelease
        policy.minimumStripAbsenceForNewHack = c.minimumStripAbsenceForNewHack
        return policy
    }

    static func cPhase(_ phase: GamePhase) -> gl_game_phase {
        switch phase {
        case .unknown: return GL_GAME_PHASE_UNKNOWN
        case .command: return GL_GAME_PHASE_COMMAND
        case .presenting: return GL_GAME_PHASE_PRESENTING
        case .input: return GL_GAME_PHASE_INPUT
        case .completed: return GL_GAME_PHASE_COMPLETED
        }
    }

    static func phase(_ phase: gl_game_phase) -> GamePhase {
        switch phase {
        case GL_GAME_PHASE_COMMAND: return .command
        case GL_GAME_PHASE_PRESENTING: return .presenting
        case GL_GAME_PHASE_INPUT: return .input
        case GL_GAME_PHASE_COMPLETED: return .completed
        default: return .unknown
        }
    }

    private static func state(_ state: gl_tracking_state) -> TrackingState {
        switch state {
        case GL_TRACKING_STATE_COMMAND: return .command
        case GL_TRACKING_STATE_PRESENTING: return .presenting
        case GL_TRACKING_STATE_INPUT: return .input
        case GL_TRACKING_STATE_COMPLETED: return .completed
        case GL_TRACKING_STATE_INTERRUPTED: return .interrupted
        default: return .inactive
        }
    }

    /// `PartialSlotStripReading` without its centres, which the caller
    /// points at for the call.
    static func cPartial(_ partial: PartialSlotStripReading) -> gl_partial_slot_reading {
        var reading = gl_partial_slot_reading()
        reading.markerCount = Int32(clamping: partial.markerCentersX.count)
        reading.highlightedMarker = cOptional(partial.highlightedMarker)
        reading.coveredFrom = partial.coveredFrom
        reading.coveredTo = partial.coveredTo
        reading.centerPitch = partial.centerPitch
        reading.centerTolerance = partial.centerTolerance
        return reading
    }

    private static func source(_ source: gl_phase_source) -> PhaseSource {
        switch source {
        case GL_PHASE_SOURCE_HEADER_TEXT: return .headerText
        case GL_PHASE_SOURCE_RETAINED: return .retained
        case GL_PHASE_SOURCE_INPUT_TIMER: return .inputTimer
        case GL_PHASE_SOURCE_PARTIAL_INPUT_TIMER: return .partialInputTimer
        case GL_PHASE_SOURCE_INDICATOR_TRANSITION: return .indicatorTransition
        default: return .none
        }
    }

    private static func status(_ status: gl_slot_status) -> SlotObservation.Status {
        switch status {
        case GL_SLOT_STATUS_OBSERVING: return .observing
        case GL_SLOT_STATUS_CONFIRMED: return .confirmed
        case GL_SLOT_STATUS_INFERRED: return .inferred
        case GL_SLOT_STATUS_MISSING: return .missing
        case GL_SLOT_STATUS_UNCERTAIN: return .uncertain
        default: return .pending
        }
    }

    private static func kind(_ kind: gl_tracking_event_kind) -> TrackingEvent.Kind {
        switch kind {
        case GL_TRACKING_EVENT_HACK_STARTED: return .hackStarted
        case GL_TRACKING_EVENT_SLOT_ADVANCED: return .slotAdvanced
        case GL_TRACKING_EVENT_SLOT_COMMITTED: return .slotCommitted
        case GL_TRACKING_EVENT_SLOT_INFERRED: return .slotInferred
        case GL_TRACKING_EVENT_SLOT_MISSING: return .slotMissing
        case GL_TRACKING_EVENT_SLOT_UNCERTAIN: return .slotUncertain
        case GL_TRACKING_EVENT_EVIDENCE_INVALIDATED: return .evidenceInvalidated
        case GL_TRACKING_EVENT_SLOT_COUNT_CONFLICT: return .slotCountConflict
        case GL_TRACKING_EVENT_SEQUENCE_FROZEN: return .sequenceFrozen
        case GL_TRACKING_EVENT_HACK_COMPLETED: return .hackCompleted
        case GL_TRACKING_EVENT_STALE_EVIDENCE_REJECTED: return .staleEvidenceRejected
        default: return .phaseChanged
        }
    }

    private static func cRejection(_ rejection: SlotStripRejection?) -> gl_slot_rejection {
        switch rejection {
        case nil: return GL_SLOT_REJECTION_NONE
        case .bandUnavailable: return GL_SLOT_REJECTION_BAND_UNAVAILABLE
        case .noMarkers: return GL_SLOT_REJECTION_NO_MARKERS
        case .tooManyMarkers: return GL_SLOT_REJECTION_TOO_MANY_MARKERS
        case .unevenSpacing: return GL_SLOT_REJECTION_UNEVEN_SPACING
        case .inconsistentMarkerWidths: return GL_SLOT_REJECTION_INCONSISTENT_MARKER_WIDTHS
        case .multipleHighlights: return GL_SLOT_REJECTION_MULTIPLE_HIGHLIGHTS
        case .incompleteMarkerHeight: return GL_SLOT_REJECTION_INCOMPLETE_MARKER_HEIGHT
        case .incompleteStrip: return GL_SLOT_REJECTION_INCOMPLETE_STRIP
        case .coveredByOverlay: return GL_SLOT_REJECTION_COVERED_BY_OVERLAY
        }
    }

    private static func cShapeKind(_ kind: ShapeEvidence.Kind) -> gl_shape_kind {
        switch kind {
        case .unavailable: return GL_SHAPE_KIND_UNAVAILABLE
        case .noStroke: return GL_SHAPE_KIND_NO_STROKE
        case .unrecognizedStroke: return GL_SHAPE_KIND_UNRECOGNIZED_STROKE
        case .unexplainedInk: return GL_SHAPE_KIND_UNEXPLAINED_INK
        case .ambiguousShape: return GL_SHAPE_KIND_AMBIGUOUS_SHAPE
        case .uniqueVisibleShape: return GL_SHAPE_KIND_UNIQUE_VISIBLE_SHAPE
        }
    }
}

/// The C++ arm of `HeaderPhraseMatcher`, over `glyph_logic_tracker.h`.
///
/// Safe to share: each read holds a lock for the call, as the C handle keeps
/// its result text until its next call.
public final class CxxHeaderPhraseMatcher: HeaderPhraseMatching, @unchecked Sendable {
    public let phrases: [HeaderPhraseMatcher.Phrase]
    public let minimumConfidence: Double

    private let handle: OpaquePointer
    private let lock = NSLock()

    public init(phrases: [HeaderPhraseMatcher.Phrase] = HeaderPhraseMatcher.englishPortrait,
                minimumConfidence: Double = 0.35) {
        self.phrases = phrases
        self.minimumConfidence = minimumConfidence
        let created = CxxStrings(phrases.flatMap(\.words)).withStrings { words -> OpaquePointer? in
            var offset = 0
            var cPhrases: [gl_header_phrase] = []
            cPhrases.reserveCapacity(phrases.count)
            for phrase in phrases {
                cPhrases.append(gl_header_phrase(
                    phase: CxxPresentationTracker.cPhase(phrase.phase),
                    words: words.baseAddress.map { $0 + offset },
                    wordCount: Int32(phrase.words.count),
                    requiresExactMatch: phrase.requiresExactMatch,
                    matchesWithin: phrase.matchesWithin))
                offset += phrase.words.count
            }
            return cPhrases.withUnsafeBufferPointer {
                gl_header_matcher_create($0.baseAddress, Int32($0.count), minimumConfidence)
            }
        }
        guard let created else { preconditionFailure("gl_header_matcher_create failed") }
        handle = created
    }

    /// `HeaderPhraseMatcher(language:)`: the headers of one game language, and English.
    public convenience init(language: GameLanguage) {
        self.init(phrases: GameText(language).headerPhrases, minimumConfidence: language.confidence.header)
    }

    deinit { gl_header_matcher_destroy(handle) }

    public func read(lines: [(text: String, confidence: Double)]) -> HeaderReading {
        CxxStrings(lines.map(\.text)).withStrings { texts in
            var cLines: [gl_header_line] = []
            cLines.reserveCapacity(lines.count)
            for (index, line) in lines.enumerated() {
                cLines.append(gl_header_line(text: texts[index], confidence: line.confidence))
            }
            return cLines.withUnsafeBufferPointer { buffer in
                lock.lock()
                defer { lock.unlock() }
                let reading = gl_header_matcher_read(handle, buffer.baseAddress, Int32(buffer.count))
                return HeaderReading(phase: CxxPresentationTracker.phase(reading.phase),
                                     matchedText: CxxPresentationTracker.string(reading.matchedText),
                                     confidence: reading.confidence, sourceTime: reading.sourceTime)
            }
        }
    }
}

/// Several Swift strings as `gc_string`s over one contiguous UTF-8 buffer,
/// valid for the closure.
private struct CxxStrings {
    private let bytes: [UInt8]
    private let lengths: [Int]

    init(_ strings: [String]) {
        var bytes: [UInt8] = []
        var lengths: [Int] = []
        lengths.reserveCapacity(strings.count)
        for string in strings {
            let utf8 = string.utf8
            bytes.append(contentsOf: utf8)
            lengths.append(utf8.count)
        }
        self.bytes = bytes
        self.lengths = lengths
    }

    func withStrings<T>(_ body: (UnsafeBufferPointer<gc_string>) -> T) -> T {
        bytes.withUnsafeBufferPointer { raw in
            var strings: [gc_string] = []
            strings.reserveCapacity(lengths.count)
            var offset = 0
            for length in lengths {
                let start = raw.baseAddress.map { UnsafeRawPointer($0 + offset).assumingMemoryBound(to: CChar.self) }
                strings.append(gc_string(bytes: start, length: Int32(length)))
                offset += length
            }
            return strings.withUnsafeBufferPointer(body)
        }
    }
}
