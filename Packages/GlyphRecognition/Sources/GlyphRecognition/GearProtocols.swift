/// The gear objects the app and the replay drive, so either arm of the logic
/// layer, Swift or C++, can stand behind them. Each protocol
/// is the members `LiveGlyphOutput` and `GlyphReplay` use; the Swift types
/// conform as they are, and `GlyphRecognitionCxx` has the C++ arm.

/// `GearDropTracker`.
public protocol GearDropTracking {
    var isObserving: Bool { get }
    var currentPanelSettled: Bool { get }
    var readingDisposition: GearDropTracker.ReadingDisposition { get }
    mutating func accept(_ evidence: GearDropFrameEvidence) -> GearDropSummary?
    mutating func observe(at time: Double, panelCandidate: Bool, continuityLost: Bool,
                          pendingReadSourceTime: Double?) -> GearDropSummary?
    mutating func loseContinuity(at time: Double) -> GearDropSummary?
    mutating func finish(at time: Double, reason: String) -> GearDropSummary?
}

extension GearDropTracking {
    /// The app's call: continuity is handled by `loseContinuity(at:)`.
    public mutating func observe(at time: Double, panelCandidate: Bool,
                                 pendingReadSourceTime: Double? = nil) -> GearDropSummary? {
        observe(at: time, panelCandidate: panelCandidate, continuityLost: false,
                pendingReadSourceTime: pendingReadSourceTime)
    }
}

/// `GearDropObservationSession`.
public protocol GearDropSessioning {
    var waiting: [GearDropObservationSession.Wait] { get }
    var events: [GearDropObservationSession.Event] { get }
    var isAssociationUncertain: Bool { get }
    @discardableResult
    mutating func prepareFrame(at time: Double, continuityLost: Bool) -> Bool
    mutating func observe(at time: Double, hackID: Int, inputVisible: Bool, gameProgressVisible: Bool,
                          inputPhase: TrackingState)
    mutating func accept(_ result: HackResult)
    mutating func close(_ group: GearDropSummary) -> GearDropSummary
    mutating func invalidate(at time: Double, reason: String)
}

extension GearDropSessioning {
    /// The gear-only replay's call, outside any Glyph hack.
    public mutating func observe(at time: Double, hackID: Int, inputVisible: Bool,
                                 gameProgressVisible: Bool = false) {
        observe(at: time, hackID: hackID, inputVisible: inputVisible, gameProgressVisible: gameProgressVisible,
                inputPhase: .input)
    }
}

/// `GearEvidenceSchedule`.
public protocol GearEvidenceScheduling {
    func shouldSave(stage: GearDropStage, at time: Double) -> Bool
    mutating func didEnqueue(stage: GearDropStage, at time: Double)
}

/// `GearDropDisplayTracker`.
public protocol GearDropDisplaying {
    var display: GearDropDisplay? { get }
    var revision: Int { get }
    mutating func update(waiting: [GearDropObservationSession.Wait], reading: Bool,
                         associationUncertain: Bool, at time: Double)
    mutating func finished(_ group: GearDropSummary)
    mutating func ended(hackID: Int, at time: Double)
}

/// `GearDropTextParser`: the panel read, one row's text, and where a line sits.
public protocol GearDropTextParsing {
    func read(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> GearDropFrameEvidence
    func showsUntitledPanel(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> Bool
    func parseEntry(_ text: String, row: Int, column: Int, clipped: Bool) -> GearDropEntry?
    static func position(of line: ResultTextLine, in bounds: GearDropPanelBounds) -> Int?
}

extension GearDropTracker: GearDropTracking {}
extension GearDropObservationSession: GearDropSessioning {}
extension GearEvidenceSchedule: GearEvidenceScheduling {}
extension GearDropDisplayTracker: GearDropDisplaying {}
extension GearDropTextParser: GearDropTextParsing {}

// The queue's values are made by the session, so their memberwise
// initializers are internal. The C++ arm, in another module, builds them
// from the values the C++ session holds.
extension GearDropObservationSession.Wait {
    public init(hack hackID: Int, startedAt: Double, lastProgress: Double, finalBonus: Int?) {
        self.init(hackID: hackID, startedAt: startedAt, lastProgress: lastProgress, finalBonus: finalBonus)
    }
}

extension GearDropObservationSession.Event {
    public init(at time: Double, hackID: Int?, reason: String) {
        self.init(time: time, hackID: hackID, reason: reason)
    }
}
