/// What the app and the replay drive in the results area: the Swift types or
/// the C++ arm's. Each protocol is exactly
/// the members `LiveGlyphOutput` and `GlyphReplay` use.
///
/// The Swift types are values and the C++ arm's are references, so a copy of
/// a C++ object is the same object. The exceptions are `tracker` and
/// `comparison`, which the app keeps across a hack's retirement: the C++ arm
/// hands those out as values too.

/// A hack's result as the app reads it from `ResultObserving.tracker`.
public protocol HackResultTracking {
    var result: HackResult { get }
    var revision: Int { get }
}

/// The validator comparison as the app reads it from
/// `ResultObserving.comparison`.
public protocol ValidatorResultComparing {
    var supersededAttemptIDs: Set<Int> { get }
    func compare(_ result: HackResult) -> [ValidatorResultComparison.Entry]
}

/// The one-hack result observer: `ResultObservationSession` or the C++ arm's.
public protocol ResultObserving {
    associatedtype Tracker: HackResultTracking
    associatedtype Comparison: ValidatorResultComparing

    var context: ResultReadContext? { get }
    var tracker: Tracker? { get }
    var comparison: Comparison? { get }

    /// Through the protocol `imageAnalyzed` and `commands` have no defaults:
    /// the replay passes `true` where it relied on the default. The
    /// presentation is either arm's tracker.
    mutating func observe<Presentation: PresentationTracking>(
        _ evidence: FrameEvidence, presentation: Presentation, panelCandidate: Bool,
        imageAnalyzed: Bool, commands: HackCommandSummary?) -> HackResult?
    mutating func accept(_ evidence: ResultFrameEvidence)
    mutating func accept(_ events: [InputCheckEvent])
    mutating func finish(at time: Double, reason: String)
}

/// Which result readings keep their image: `ResultEvidenceSchedule` or the
/// C++ arm's.
public protocol ResultEvidenceScheduling {
    mutating func select(_ evidence: ResultFrameEvidence, decision: Bool) -> ResultEvidenceSchedule.Selection?
}

/// Whether the command notice band is watched: `CommandScreenWatch` or the
/// C++ arm's.
public protocol CommandScreenWatching {
    var watching: Bool { get }
    mutating func observe(at time: Double, calibrated: Bool, commandPhase: Bool,
                          complete: Bool) -> CommandScreenWatch.Action
    mutating func stop()
    mutating func reset()
}

/// Whether the command phase is current, from header readings and notices:
/// `CommandPhaseContext` or the C++ arm's.
public protocol CommandPhaseContexting {
    var leave: Double { get set }
    mutating func header(_ reading: HeaderReading)
    mutating func notice(at time: Double)
    mutating func noticeRead(at sourceTime: Double?)
    func isCurrent(at time: Double) -> Bool
    mutating func reset()
}

public extension CommandPhaseContexting {
    /// A reading of `phase` without its text: an unknown one recognised nothing.
    mutating func header(_ phase: GamePhase, at sourceTime: Double) {
        header(HeaderReading(phase: phase, matchedText: "", confidence: 0, sourceTime: sourceTime))
    }
}

/// Result page text to evidence: `ResultTextParser` or the C++ arm's.
public protocol ResultTextParsing {
    func read(lines: [ResultTextLine], context: ResultReadContext, at time: Double,
              appearances: [ResultSlotAppearance]) -> ResultFrameEvidence
}

extension HackResultTracker: HackResultTracking {}
extension ValidatorResultComparison: ValidatorResultComparing {}
extension ResultObservationSession: ResultObserving {}
extension ResultEvidenceSchedule: ResultEvidenceScheduling {}
extension CommandScreenWatch: CommandScreenWatching {}
extension CommandPhaseContext: CommandPhaseContexting {}
extension ResultTextParser: ResultTextParsing {}

extension ValidatorResultComparison.Entry {
    /// An entry made outside this module, as the C++ arm makes its own. The
    /// synthesized initializer is internal and its labels are taken.
    public init(slotIndex: Int, attemptID: Int?, verdict: InputCheckVerdict?, outcome: GameSlotOutcome,
                status: ValidatorResultComparison.Status, drawSeconds: Double?) {
        self.slotIndex = slotIndex
        self.attemptID = attemptID
        self.validatorVerdict = verdict
        self.gameOutcome = outcome
        self.status = status
        self.drawSeconds = drawSeconds
    }
}
