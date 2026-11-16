/// The pace area's objects as the app and the replay drive them, so either
/// arm, Swift or C++ (`GlyphRecognitionCxx`), can stand behind them. Each
/// protocol is the set of members `LiveGlyphOutput`, `GameHeaderReader` and
/// `GlyphReplay` use.

/// How often frames are analyzed: `AnalysisRateController`.
public protocol AnalysisPacing {
    var policy: AnalysisRateController.Policy { get }
    var mode: AnalysisRateController.Mode { get }
    var enteredCandidate: Bool { get }
    var switchedScreen: Bool { get }
    mutating func decide(at time: Double, gate: LumaGateReading?, busy: Bool, inHack: Bool,
                         constrained: Bool) -> AnalysisRateController.Decision
    mutating func advanceStill(at time: Double, busy: Bool, inHack: Bool,
                               constrained: Bool) -> AnalysisRateController.Decision
    mutating func reset()
    static func headerInterval(mode: AnalysisRateController.Mode, inHack: Bool, constrained: Bool) -> Double?
}

extension AnalysisRateController: AnalysisPacing {}

/// The shared OCR lane: `GameTextSchedule`. `admitsHeader` is asked only for
/// a header read that is otherwise due, as the Swift schedule asks it.
public protocol GameTextScheduling {
    var inFlight: GameTextSchedule.Request? { get }
    mutating func take(at time: Double, panelCandidate: Bool, resultEligible: Bool, minimumInterval: Double,
                       gearCandidate: Bool, headerPriority: Bool, portalCandidate: Bool, commandCandidate: Bool,
                       readsHeader: Bool, headerInterval: Double?, gearInterval: Double,
                       gearPanelPace: GameTextSchedule.Pace?,
                       admitsHeader: () -> Bool) -> GameTextSchedule.Request?
    mutating func finish(_ request: GameTextSchedule.Request, panelPresent: Bool, untitledPanel: Bool)
    mutating func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double,
                                   previousPanelUnconfirmed: Bool) -> GameTextSchedule.Request?
}

extension GameTextScheduling {
    /// `GameTextSchedule.take`'s defaults, for callers that leave them out.
    public mutating func take(at time: Double, panelCandidate: Bool, resultEligible: Bool,
                              minimumInterval: Double = 0.1, gearCandidate: Bool = false,
                              headerPriority: Bool = false, portalCandidate: Bool = false,
                              commandCandidate: Bool = false, readsHeader: Bool = true,
                              headerInterval: Double? = nil, gearInterval: Double = 0.2,
                              gearPanelPace: GameTextSchedule.Pace? = nil) -> GameTextSchedule.Request? {
        take(at: time, panelCandidate: panelCandidate, resultEligible: resultEligible,
             minimumInterval: minimumInterval, gearCandidate: gearCandidate, headerPriority: headerPriority,
             portalCandidate: portalCandidate, commandCandidate: commandCandidate, readsHeader: readsHeader,
             headerInterval: headerInterval, gearInterval: gearInterval, gearPanelPace: gearPanelPace,
             admitsHeader: { true })
    }

    /// `GameTextSchedule.finish`'s defaults: no panel found, not untitled.
    public mutating func finish(_ request: GameTextSchedule.Request, panelPresent: Bool = false) {
        finish(request, panelPresent: panelPresent, untitledPanel: false)
    }

    /// `GameTextSchedule.observeGearPanel`'s default: the previous panel is settled.
    public mutating func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double) -> GameTextSchedule.Request? {
        observeGearPanel(bounds, at: time, previousPanelUnconfirmed: false)
    }
}

extension GameTextSchedule: GameTextScheduling {}

extension GameTextSchedule.Request {
    /// For the C++ arm, which makes requests outside this module, where the
    /// memberwise initializer is not visible.
    public static func make(id: Int, mode: GameTextSchedule.Mode, sourceTime: Double) -> Self {
        Self(id: id, mode: mode, sourceTime: sourceTime)
    }
}

/// The capture's game language: `GameLanguageMemory`. Shared by the readers
/// across threads, as the Swift class is.
public protocol GameLanguageRemembering: AnyObject, Sendable {
    var current: GameLanguage { get }
    var isConfirmed: Bool { get }
    var state: (language: GameLanguage, isConfirmed: Bool) { get }
    var isAutomatic: Bool { get }
    func alternatives(at time: Double, on screen: GameLanguageMemory.Screen) -> [GameLanguage]
    func found(_ found: GameLanguage)
    func panelReadingLanguage(at time: Double, bounds: GearDropPanelBounds) -> GameLanguage?
    func rememberPanelReading(_ language: GameLanguage, at time: Double, bounds: GearDropPanelBounds)
    static func startingGuess(remembered: GameLanguage?, preferredLanguages: [String]) -> GameLanguage
}

extension GameLanguageMemory: GameLanguageRemembering {}

/// One language's phrase matchers: `GameText` without the headers, which
/// the tracker area matches.
public protocol GameTextMatching: Sendable {
    var language: GameLanguage { get }
    func notice(_ text: String) -> (notice: CommandNoticeReading.Notice, language: String)?
    func isDroneFooter(_ text: String) -> Bool
    func isHackingLabel(_ text: String) -> Bool
    func hackingLabelLanguage(_ text: String) -> GameLanguage?
    func bonusTitleLanguage(_ text: String) -> GameLanguage?
    func isSpeedLabel(_ text: String) -> Bool
    func title(_ text: String) -> GameText.Title
    func effect(_ text: String) -> String?
    func item(named name: String, clipped: Bool) -> String?
}

extension GameTextMatching {
    public func item(named name: String) -> String? { item(named: name, clipped: false) }
}

extension GameText: GameTextMatching {}

/// Portal screens between hacks: `PortalLevelObserver`.
public protocol PortalLevelObserving {
    mutating func accept(_ evidence: PortalScreenEvidence)
    mutating func claim(at time: Double) -> PortalScreenEvidence?
}

extension PortalLevelObserver: PortalLevelObserving {}

/// Resonator levels from a portal screen's labels: `PortalScreenParser`.
public protocol PortalScreenParsing: Sendable {
    func read(lines: [ResultTextLine], badgeHue: Double?, at time: Double, faction: PortalFaction?,
              yellowLabels: Set<Int>) -> PortalScreenEvidence
    static func isLevelOneYellow(hues: [Double]) -> Bool
}

extension PortalScreenParser: PortalScreenParsing {}

extension PortalLevelEstimate {
    /// For the C++ arm, which makes estimates outside this module, where the
    /// memberwise initializer is not visible.
    public static func make(level: Int?, lowest: Int, highest: Int, confidence: Confidence, conflict: Bool,
                            resonators: [Int]?, unreadSlots: Int?, badgeLevels: [Int]?, glyphCount: Int?,
                            factionCode: String?) -> Self {
        Self(level: level, lowest: lowest, highest: highest, confidence: confidence, conflict: conflict,
             resonators: resonators, unreadSlots: unreadSlots, badgeLevels: badgeLevels, glyphCount: glyphCount,
             factionCode: factionCode)
    }
}
