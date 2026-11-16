import GlyphRecognition
import GlyphRecognitionImages

/// The C++ arm of the logic layer as one `RecognitionLogicSet`, with the same
/// parameters as `makeSwiftLogicSet`. Every decision runs in C++; Vision,
/// the pixel detection inside the command capture and the data tables stay
/// in Swift. The tracker, the result session and the validator index the
/// Glyphs of `table`, the table the shape evidence is recognized with, and
/// the parsers are made from the same `GameText` packs as the Swift ones.
public func makeCxxLogicSet(table: GlyphTable?, sequenceTable: SequenceTable?, sessionID: CaptureSessionID,
                            language: GameLanguage = .english, automaticLanguage: Bool = false,
                            onLanguageFound: @escaping @Sendable (GameLanguage) -> Void = { _ in })
    -> RecognitionLogicSet {
    let glyphs = table?.glyphs ?? []
    return RecognitionLogicSet(
        name: "cpp",
        tracker: CxxPresentationTracker(sessionID: sessionID, glyphs: glyphs),
        resultSession: CxxResultObservationSession(glyphs: glyphs),
        resultEvidenceSchedule: CxxResultEvidenceSchedule(),
        commandScreen: CxxCommandScreenWatch(),
        commandContext: CxxCommandPhaseContext(),
        gearTracker: CxxGearDropTracker(),
        gearSession: CxxGearDropObservationSession(),
        gearEvidenceSchedule: CxxGearEvidenceSchedule(),
        gearDisplay: CxxGearDropDisplayTracker(standalone: table == nil),
        inputValidator: table.map { CxxPlayerInputValidator(table: $0, sessionID: sessionID) },
        predictor: table == nil ? nil : sequenceTable.map(CxxSequencePredictor.init(table:)),
        pace: CxxAnalysisRateController(),
        textSchedule: CxxGameTextSchedule(),
        languageMemory: CxxGameLanguageMemory(language: language, isAutomatic: automaticLanguage,
                                              onChange: onLanguageFound),
        commandNoticeCapture: CxxCommandNoticeCapture(),
        portalObserver: CxxPortalLevelObserver(),
        // Made per call, as the Swift values are: the C++ handles keep their
        // output between calls, so one is never shared across reads.
        textMatcher: { CxxGameText($0) },
        headerPhraseMatcher: { CxxHeaderPhraseMatcher(language: $0) },
        resultTextParser: { CxxResultTextParser(language: $0) },
        gearTextParser: { CxxGearDropTextParser(language: $0) },
        gearLinePosition: { CxxGearDropTextParser.position(of: $0, in: $1) },
        commandNoticeParser: { CxxCommandNoticeParser(language: $0) },
        portalScreenParser: CxxPortalScreenParser(),
        portalLevelEstimate: { CxxPortalLevelRules.estimate(screen: $0, glyphCount: $1, glyphCountSettled: $2) },
        resultSummary: { CxxHackResultSummary.make(result: $0, comparison: $1) },
        makeTracker: { CxxPresentationTracker(sessionID: sessionID, policy: $0, glyphs: glyphs) },
        makePortalObserver: { CxxPortalLevelObserver() },
        makeGearEvidenceSchedule: { CxxGearEvidenceSchedule() },
        makeGearTitleMemory: { GearTitleLanguageMemory() })
}
