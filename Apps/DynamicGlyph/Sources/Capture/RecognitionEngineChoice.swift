import Foundation
import GlyphRecognition
import GlyphRecognitionCxx
import GlyphRecognitionImages

/// Which engine a capture session runs its pixel steps on. Chosen in
/// Settings (Old or New) or Diagnostics and read once when a capture starts;
/// C++ unless chosen (`AppPreferences.defaultRecognitionEngine`).
enum RecognitionEngineChoice: String, CaseIterable, Sendable {
    /// The pipeline shipped before the C++ engine became the default: Core
    /// Image and Core Graphics conversions, then the Swift detectors.
    case swift
    /// The same algorithms in C++, reading the capture's planes with
    /// `directPlanes`.
    case cpp

    /// For the picker: proper names, so not translated.
    var label: String {
        switch self {
        case .swift: return "Swift"
        case .cpp: return "C++"
        }
    }
}

/// Which arm of the logic layer a capture session runs: the presentation
/// tracker, the result, gear and command sessions, the schedules, the
/// language memory and the text parsers.
/// Independent of the engine, which reads the pixels.
enum RecognitionLogicChoice: String, CaseIterable, Sendable {
    /// The Swift types, as shipped.
    case swift
    /// The same rules in C++, behind the same protocols.
    case cpp

    /// For the picker: proper names, so not translated.
    var label: String {
        switch self {
        case .swift: return "Swift"
        case .cpp: return "C++"
        }
    }
}

/// The power cuts, each a switch. Unless a player or
/// tester set them, a capture runs `AppPreferences.defaultRecognitionCuts`.
/// The Swift arm honours `swiftEngineCuts`; the others remove conversions it
/// needs.
enum RecognitionCut: String, CaseIterable, Sendable, Comparable {
    /// Luma and colour straight from the capture's planes: no Core Image
    /// render, no Core Graphics decode. C++ arm only.
    case directPlanes
    /// The frame's CGImage is rendered only when the text lane takes a read,
    /// not on every analysed frame. Both arms.
    case lazyImage
    /// The node array is hunted in the rows the luma gate calls the array
    /// area, not over the header, the strip and the keyboard. C++ arm only.
    case huntBand
    /// Ring components are found on every second pixel, then measured on the
    /// full pixels inside each box. C++ arm only.
    case huntHalf
    /// The drone footer's label and the command band, when the frame is not
    /// rendered, are rendered only if the capture's planes show they may
    /// hold something for their detectors. Both arms. Among
    /// `AppPreferences.defaultRecognitionCuts` since it was measured on an
    /// iPhone 13 mini: it reads the same and saves Core Image work on the
    /// graphics processor, not CPU time.
    case planeGate
    /// A portal screen stops being offered to the text lane once one read
    /// decides its level or two in a row agree, until another screen shows
    /// (`PortalReadLimiter`). Both arms.
    case portalSettle
    /// A header read is skipped while the header's pixels are still against
    /// the last real read, under a second old, in a hack too; that read's
    /// reading is issued again (`GameHeaderReader.skipsStillHeaders`). Both
    /// arms. Among `AppPreferences.defaultRecognitionCuts` since it was
    /// measured on an iPhone 13 mini, where most of its saving was the
    /// accurate OCR of a CJK header.
    case headerStillSkip
    /// A gear read due on a drop panel whose rows are all confirmed is
    /// answered with the read that settled it, issued again, while the
    /// panel's pixels and bounds stay still and that read is under a second
    /// old (`GearSettleLimiter`). Both arms. Not among
    /// `AppPreferences.defaultRecognitionCuts`: unmeasured on a phone, it
    /// runs only when a tester turns it on.
    case gearSettle
    /// A result read due on a hack's result panel, once the result is
    /// complete and the last two reads agreed, is answered with the last
    /// read, issued again, while the panel's pixels stay still and that read
    /// is under a second old (`ResultSettleLimiter`). Both arms. Not among
    /// `AppPreferences.defaultRecognitionCuts`: unmeasured on a phone, it
    /// runs only when a tester turns it on.
    case resultSettle
    /// A gear read leaves out its rereads of a row the panel pass read whole
    /// with a clearly red quantity and of an empty cell, and the numeric
    /// quantity pass in a non-English game
    /// (`GearDropScreenReader.RowRereads.lean`). Both arms. Among
    /// `AppPreferences.defaultRecognitionCuts` since it was measured on an
    /// iPhone 13 mini: it reads the same gear with well under half the gear
    /// passes.
    case gearLeanRead
    /// A gear read of a portal or Bonus panel with a name read, in an
    /// automatic game language a screen has confirmed, keeps its unresolved
    /// rows in that language (`GearDropScreenReader.mayShowAnotherLanguage`);
    /// any other read, results and notices still look for another language.
    /// Both arms. Not among `AppPreferences.defaultRecognitionCuts`: measured
    /// by replay only, it runs only when a tester turns it on.
    case gearLanguageSettle
    /// With `headerStillSkip` only: a header that is not still is compared
    /// again without the cells under the app's own Picture in Picture
    /// window, found in the top band in this frame and the last read's
    /// (`GameHeaderReader.masksHeaderWindow`). Without `headerStillSkip` it
    /// does nothing. Both arms. Not among
    /// `AppPreferences.defaultRecognitionCuts`: unmeasured on a phone, it
    /// runs only when a tester turns it on.
    case headerWindowMask
    /// A header-only read, and a command read's header request, is left out
    /// while the app's own Picture in Picture window, found in the top band
    /// when such a read is due, covers at least half of the header's rows;
    /// no reading is issued for it (`GameHeaderReader.skipsCoveredHeaders`).
    /// Both arms. Not among `AppPreferences.defaultRecognitionCuts`:
    /// measured by replay only, it runs only when a tester turns it on.
    case headerCoverSkip

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The cuts the Swift engine's session honours, all `LiveGlyphOutput`'s.
    static let swiftEngineCuts: Set<RecognitionCut> = [.lazyImage, .planeGate, .portalSettle, .headerStillSkip,
                                                         .gearSettle, .resultSettle, .gearLeanRead,
                                                         .gearLanguageSettle, .headerWindowMask,
                                                         .headerCoverSkip]
}

extension Set where Element == RecognitionCut {
    /// For logs and the Power section: "none", or the cuts' names in the
    /// order they are listed, space separated.
    var summary: String {
        isEmpty ? "none" : sorted().map(\.rawValue).joined(separator: " ")
    }
}

/// The engine a session runs its pixel steps on, the cuts it runs with, and,
/// when that is not the engine chosen, why.
struct RecognitionEngineSetup {
    let engine: FrameRecognitionEngine
    let choice: RecognitionEngineChoice
    let cuts: Set<RecognitionCut>
    /// Why the chosen C++ engine could not take the shape list, so the Swift
    /// engine runs instead; nil when the choice runs.
    let fallback: String?

    /// For the capture log, the Power section and the benchmark: the engine
    /// that ran by its own name, and the choice and why when they differ.
    var label: String { Self.label(name: engine.name, choice: choice, fallback: fallback) }

    /// "cpp", or "swift (chose cpp: 513 Glyphs, the C++ engine takes at most 512)".
    static func label(name: String, choice: RecognitionEngineChoice, fallback: String?) -> String {
        guard name != choice.rawValue || fallback != nil else { return name }
        return "\(name) (chose \(choice.rawValue)" + (fallback.map { ": \($0)" } ?? "") + ")"
    }

    /// The capture log's line for the session's arms: the engine that ran
    /// and the one chosen, with why they differ, the logic likewise, and the
    /// cuts in effect.
    func logLine(logic: String, logicChoice: RecognitionLogicChoice) -> String {
        "recognition engine \(engine.name) (chose \(choice.rawValue)"
            + (fallback.map { ", which can't take this Glyph list: \($0)" } ?? "")
            + ") · logic \(logic) (chose \(logicChoice.rawValue)) · cuts \(cuts.summary)"
    }
}

/// The engine a capture session's `LiveGlyphOutput` runs its pixel steps on.
/// A nil `table` reads panels only, as gear-only capture does. The cuts that
/// live inside the engine (`directPlanes`, `huntBand`, `huntHalf`) are handed
/// to it here; `lazyImage`, `planeGate`, `portalSettle`, `headerStillSkip`,
/// `gearSettle`, `resultSettle`, `gearLeanRead`, `gearLanguageSettle`,
/// `headerWindowMask` and `headerCoverSkip` are `LiveGlyphOutput`'s own.
///
/// A player can import a shape list larger than the C++ core holds
/// (`CxxFrameRecognitionEngine.check`); the Swift engine takes any list, so
/// it runs that session instead, with the cuts it honours, and says why.
func makeRecognitionEngine(choice: RecognitionEngineChoice, table: GlyphTable?,
                           cuts: Set<RecognitionCut>) -> RecognitionEngineSetup {
    switch choice {
    case .swift:
        return RecognitionEngineSetup(engine: SwiftFrameRecognitionEngine(table: table), choice: choice, cuts: cuts,
                                      fallback: nil)
    case .cpp:
        var engineCuts: CxxEngineCuts = []
        if cuts.contains(.directPlanes) { engineCuts.insert(.directPlanes) }
        if cuts.contains(.huntBand) { engineCuts.insert(.huntBand) }
        if cuts.contains(.huntHalf) { engineCuts.insert(.huntHalf) }
        do {
            return RecognitionEngineSetup(engine: try CxxFrameRecognitionEngine(table: table, cuts: engineCuts),
                                          choice: choice, cuts: cuts, fallback: nil)
        } catch {
            return RecognitionEngineSetup(engine: SwiftFrameRecognitionEngine(table: table), choice: choice,
                                          cuts: cuts.intersection(RecognitionCut.swiftEngineCuts),
                                          fallback: String(describing: error))
        }
    }
}

/// The logic set a capture session's `LiveGlyphOutput` drives, built from the
/// same tables as its engine. A nil `table` reads panels only. The language
/// memory starts at `language`, follows the game when `automaticLanguage`,
/// and tells `onLanguageFound` of each change; the set's memory is the one
/// the session shares with its records and the Power section.
func makeRecognitionLogic(choice: RecognitionLogicChoice, table: GlyphTable?, sequenceTable: SequenceTable?,
                          sessionID: CaptureSessionID, language: GameLanguage, automaticLanguage: Bool,
                          onLanguageFound: @escaping @Sendable (GameLanguage) -> Void = { _ in }) -> RecognitionLogicSet {
    switch choice {
    case .swift:
        return makeSwiftLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID, language: language,
                                 automaticLanguage: automaticLanguage, onLanguageFound: onLanguageFound)
    case .cpp:
        return makeCxxLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID, language: language,
                               automaticLanguage: automaticLanguage, onLanguageFound: onLanguageFound)
    }
}
