/// What the app and the replay drive on a presentation tracker: the Swift
/// `PresentationTracker` or the C++ arm's `CxxPresentationTracker`.
/// Exactly the members `LiveGlyphOutput` and `GlyphReplay` use.
///
/// Creation is not part of it: the C++ arm also needs the Glyph list its
/// indices refer to, so whoever chooses the arm creates the tracker.
///
/// `PresentationTracker` is a value and the C++ arm a reference, so a copy of
/// the C++ arm is the same tracker, not a snapshot of it.
public protocol PresentationTracking {
    var sessionID: CaptureSessionID { get }
    var policy: PresentationTracker.Policy { get }
    var state: TrackingState { get }
    var phaseSource: PhaseSource { get }
    var hackID: Int { get }
    var revision: Int { get }
    var slots: [SlotObservation] { get }
    var lastEvidenceTime: Double? { get }
    var lastPhaseTime: Double? { get }
    var lastIndicatorTime: Double? { get }
    var expectedSlotCount: Int? { get }
    var currentSlotIndex: Int? { get }
    var inputSlotIndex: Int? { get }
    var indicatorsObstructed: Bool { get }
    var slotCountConflict: Bool { get }
    var isFrozen: Bool { get }
    var confirmedPrefix: [GlyphID] { get }
    /// What the input validator's context reads, beside the members above.
    var observedPresentationForCurrentHack: Bool { get }

    @discardableResult
    mutating func accept(_ evidence: FrameEvidence) -> [TrackingEvent]
    mutating func invalidatePhase()
    mutating func reset()
}

extension PresentationTracker: PresentationTracking {}

/// Header text to a phase: the Swift `HeaderPhraseMatcher` or the C++ arm's
/// `CxxHeaderPhraseMatcher`, as `HeaderTextRecognizer` uses it. Sendable, as
/// the recognizer that holds it is: header reads run off the capture queue.
public protocol HeaderPhraseMatching: Sendable {
    func read(lines: [(text: String, confidence: Double)]) -> HeaderReading
}

extension HeaderPhraseMatcher: HeaderPhraseMatching {}
