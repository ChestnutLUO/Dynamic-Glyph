import GlyphRecognition

/// Every logic object the app and the replay drive, from one arm of the logic
/// layer: the Swift types (`makeSwiftLogicSet`) or the C++ ones
/// (`makeCxxLogicSet` in `GlyphRecognitionCxx`).
///
/// The objects with state are the starting values of one capture session or
/// replay; the caller keeps and mutates its own copies. The Swift ones are
/// values and the C++ ones references, so a set is used for one session only.
/// What a call site makes again later, or per read, comes as a factory, so
/// both arms are made at the same moments the Swift values were. Both arms
/// are built from the same Glyph table and `GameText` packs.
public struct RecognitionLogicSet {
    /// "swift" or "cpp": the arm, for logs, reports and the Power section.
    public let name: String

    // MARK: Session state

    public var tracker: any PresentationTracking
    public var resultSession: any ResultObserving
    public var resultEvidenceSchedule: any ResultEvidenceScheduling
    public var commandScreen: any CommandScreenWatching
    public var commandContext: any CommandPhaseContexting
    public var gearTracker: any GearDropTracking
    public var gearSession: any GearDropSessioning
    public var gearEvidenceSchedule: any GearEvidenceScheduling
    public var gearDisplay: any GearDropDisplaying
    /// Nil without a Glyph table: gear-only capture checks no input.
    public var inputValidator: (any PlayerInputValidating)?
    /// Nil without a Glyph table or a sequence table.
    public let predictor: (any SequencePredicting)?
    public var pace: any AnalysisPacing
    public var textSchedule: any GameTextScheduling
    /// Shared with whatever reports the session's language: a class in both arms.
    public let languageMemory: any GameLanguageRemembering
    /// A class in both arms; the caller holds this one for the session.
    public let commandNoticeCapture: any CommandNoticeCapturing
    public var portalObserver: any PortalLevelObserving

    // MARK: Text logic, made per language as the Swift values were

    public let textMatcher: @Sendable (GameLanguage) -> any GameTextMatching
    public let headerPhraseMatcher: @Sendable (GameLanguage) -> any HeaderPhraseMatching
    public let resultTextParser: @Sendable (GameLanguage) -> any ResultTextParsing
    public let gearTextParser: @Sendable (GameLanguage) -> any GearDropTextParsing
    /// `GearDropTextParsing.position(of:in:)` of the same arm.
    public let gearLinePosition: @Sendable (ResultTextLine, GearDropPanelBounds) -> Int?
    public let commandNoticeParser: @Sendable (GameLanguage) -> any CommandNoticeParsing
    public let portalScreenParser: any PortalScreenParsing

    // MARK: Rules

    /// `PortalLevelRules.estimate(screen:glyphCount:glyphCountSettled:)`.
    public let portalLevelEstimate: @Sendable (PortalScreenEvidence?, Int?, Bool) -> PortalLevelEstimate?
    /// `HackResultSummary(result:comparison:)`.
    public let resultSummary: @Sendable (HackResult, [ValidatorResultComparison.Entry]) -> HackResultSummary

    // MARK: Factories, for what a call site makes again

    /// A tracker with another policy, as the replay's ablations make one.
    public let makeTracker: (PresentationTracker.Policy) -> any PresentationTracking
    /// A fresh observer: capture starts one over when continuity is lost.
    public let makePortalObserver: () -> any PortalLevelObserving
    /// A fresh schedule for each gear group.
    public let makeGearEvidenceSchedule: () -> any GearEvidenceScheduling
    /// The OCR lane's title-language memory. Swift in both arms: it orders
    /// Vision's language families, which stay in Swift.
    public let makeGearTitleMemory: @Sendable () -> GearTitleLanguageMemory

    public init(name: String, tracker: any PresentationTracking, resultSession: any ResultObserving,
                resultEvidenceSchedule: any ResultEvidenceScheduling, commandScreen: any CommandScreenWatching,
                commandContext: any CommandPhaseContexting,
                gearTracker: any GearDropTracking, gearSession: any GearDropSessioning,
                gearEvidenceSchedule: any GearEvidenceScheduling, gearDisplay: any GearDropDisplaying,
                inputValidator: (any PlayerInputValidating)?, predictor: (any SequencePredicting)?,
                pace: any AnalysisPacing, textSchedule: any GameTextScheduling,
                languageMemory: any GameLanguageRemembering, commandNoticeCapture: any CommandNoticeCapturing,
                portalObserver: any PortalLevelObserving,
                textMatcher: @escaping @Sendable (GameLanguage) -> any GameTextMatching,
                headerPhraseMatcher: @escaping @Sendable (GameLanguage) -> any HeaderPhraseMatching,
                resultTextParser: @escaping @Sendable (GameLanguage) -> any ResultTextParsing,
                gearTextParser: @escaping @Sendable (GameLanguage) -> any GearDropTextParsing,
                gearLinePosition: @escaping @Sendable (ResultTextLine, GearDropPanelBounds) -> Int?,
                commandNoticeParser: @escaping @Sendable (GameLanguage) -> any CommandNoticeParsing,
                portalScreenParser: any PortalScreenParsing,
                portalLevelEstimate: @escaping @Sendable (PortalScreenEvidence?, Int?, Bool) -> PortalLevelEstimate?,
                resultSummary: @escaping @Sendable (HackResult, [ValidatorResultComparison.Entry]) -> HackResultSummary,
                makeTracker: @escaping (PresentationTracker.Policy) -> any PresentationTracking,
                makePortalObserver: @escaping () -> any PortalLevelObserving,
                makeGearEvidenceSchedule: @escaping () -> any GearEvidenceScheduling,
                makeGearTitleMemory: @escaping @Sendable () -> GearTitleLanguageMemory) {
        self.name = name
        self.tracker = tracker
        self.resultSession = resultSession
        self.resultEvidenceSchedule = resultEvidenceSchedule
        self.commandScreen = commandScreen
        self.commandContext = commandContext
        self.gearTracker = gearTracker
        self.gearSession = gearSession
        self.gearEvidenceSchedule = gearEvidenceSchedule
        self.gearDisplay = gearDisplay
        self.inputValidator = inputValidator
        self.predictor = predictor
        self.pace = pace
        self.textSchedule = textSchedule
        self.languageMemory = languageMemory
        self.commandNoticeCapture = commandNoticeCapture
        self.portalObserver = portalObserver
        self.textMatcher = textMatcher
        self.headerPhraseMatcher = headerPhraseMatcher
        self.resultTextParser = resultTextParser
        self.gearTextParser = gearTextParser
        self.gearLinePosition = gearLinePosition
        self.commandNoticeParser = commandNoticeParser
        self.portalScreenParser = portalScreenParser
        self.portalLevelEstimate = portalLevelEstimate
        self.resultSummary = resultSummary
        self.makeTracker = makeTracker
        self.makePortalObserver = makePortalObserver
        self.makeGearEvidenceSchedule = makeGearEvidenceSchedule
        self.makeGearTitleMemory = makeGearTitleMemory
    }

    /// The text logic `GearDropScreenReader` reads a panel with.
    public var gearReaderLogic: GearDropScreenReader.Logic {
        GearDropScreenReader.Logic(textParser: gearTextParser, position: gearLinePosition, text: textMatcher)
    }

    /// The text logic `CommandNoticeReader` reads a notice with.
    public var commandReaderLogic: CommandNoticeReader.Logic {
        CommandNoticeReader.Logic(parser: commandNoticeParser, text: textMatcher)
    }
}

/// The Swift arm: the types the app and the replay have always run. A nil
/// `table` is gear-only capture: no input validator and no predictor. The
/// language memory starts at `language`, read automatically when
/// `automaticLanguage`, and tells `onLanguageFound` of each change.
public func makeSwiftLogicSet(table: GlyphTable?, sequenceTable: SequenceTable?, sessionID: CaptureSessionID,
                              language: GameLanguage = .english, automaticLanguage: Bool = false,
                              onLanguageFound: @escaping @Sendable (GameLanguage) -> Void = { _ in })
    -> RecognitionLogicSet {
    makeSwiftLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID,
                      languages: GameLanguageMemory(language: language, isAutomatic: automaticLanguage,
                                                    onChange: onLanguageFound))
}

/// The Swift arm around a language memory the caller already shares.
public func makeSwiftLogicSet(table: GlyphTable?, sequenceTable: SequenceTable?, sessionID: CaptureSessionID,
                              languages: GameLanguageMemory) -> RecognitionLogicSet {
    RecognitionLogicSet(
        name: "swift",
        tracker: PresentationTracker(sessionID: sessionID),
        resultSession: ResultObservationSession(),
        resultEvidenceSchedule: ResultEvidenceSchedule(),
        commandScreen: CommandScreenWatch(),
        commandContext: CommandPhaseContext(),
        gearTracker: GearDropTracker(),
        gearSession: GearDropObservationSession(),
        gearEvidenceSchedule: GearEvidenceSchedule(),
        gearDisplay: GearDropDisplayTracker(standalone: table == nil),
        inputValidator: table.map { PlayerInputValidator(table: $0, sessionID: sessionID) },
        predictor: table == nil ? nil : sequenceTable.map(SequencePredictor.init(table:)),
        pace: AnalysisRateController(),
        textSchedule: GameTextSchedule(),
        languageMemory: languages,
        commandNoticeCapture: CommandNoticeCapture(),
        portalObserver: PortalLevelObserver(),
        textMatcher: { GameText($0) },
        headerPhraseMatcher: { HeaderPhraseMatcher(language: $0) },
        resultTextParser: { ResultTextParser(language: $0) },
        gearTextParser: { GearDropTextParser(language: $0) },
        gearLinePosition: { GearDropTextParser.position(of: $0, in: $1) },
        commandNoticeParser: { CommandNoticeParser(language: $0) },
        portalScreenParser: PortalScreenParser(),
        portalLevelEstimate: { PortalLevelRules.estimate(screen: $0, glyphCount: $1, glyphCountSettled: $2) },
        resultSummary: { HackResultSummary(result: $0, comparison: $1) },
        makeTracker: { PresentationTracker(sessionID: sessionID, policy: $0) },
        makePortalObserver: { PortalLevelObserver() },
        makeGearEvidenceSchedule: { GearEvidenceSchedule() },
        makeGearTitleMemory: { GearTitleLanguageMemory() })
}
