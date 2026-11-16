import GlyphRecognition
import GlyphRecognitionCxx
import GlyphRecognitionImages

/// Which arm of the engine A/B runs the replay's pixel steps: the Swift
/// engine or its C++ port. Unlike `--ablate`, which removes pipeline
/// rules, the engine and its cuts change only how the pixels are read.
enum ReplayEngine: String, CaseIterable, Sendable {
    case swift
    case cpp

    static func parse(_ name: String) throws -> ReplayEngine {
        guard let engine = ReplayEngine(rawValue: name) else {
            throw ReplayError.usage("--engine needs " + allCases.map(\.rawValue).joined(separator: " or "))
        }
        return engine
    }
}

/// The power cuts, by the names the app and the ablation replays use.
enum ReplayCut: String, CaseIterable, Sendable {
    /// No effect on decoded pictures, which have no planes: accepted so a
    /// replay arm runs with the same flags as on the device.
    case directPlanes
    /// No effect: the replay renders no image beyond the decoded picture.
    case lazyImage
    case huntBand
    case huntHalf
    /// No effect: the replay renders no region on its own for the gate to
    /// skip, and decoded pictures have no planes.
    case planeGate
    /// A portal screen is no longer read once its levels have settled
    /// (`PortalReadLimiter`), in the live and exhaustive gear modes alike.
    case portalSettle
    /// No effect: the app's header reader skips still headers, and the
    /// replay reads headers through its own lane, which has no unchanged or
    /// still skip. Accepted so a replay arm runs with the same flags as on the
    /// device; the cut is measured through the app's tests and benchmark.
    case headerStillSkip
    /// A gear read due on a settled panel whose pixels and bounds stay still
    /// is answered with the read that settled it (`GearSettleLimiter`), in
    /// the live, exhaustive and gear-only modes alike.
    case gearSettle
    /// A result read due on a complete result whose panel stays still is
    /// answered with the last read (`ResultSettleLimiter`), in the live and
    /// exhaustive result modes alike.
    case resultSettle
    /// A gear read leaves out rereads of clearly red rows the panel pass
    /// read whole and of empty cells, and the numeric quantity pass
    /// (`GearDropScreenReader.RowRereads.lean`), in every gear mode.
    case gearLeanRead
    /// A gear read of a portal or Bonus panel with a name read, in an
    /// automatic game language a screen has confirmed, keeps its unresolved
    /// rows in that language (`GearDropScreenReader.mayShowAnotherLanguage`).
    case gearLanguageSettle
    /// No effect, as `headerStillSkip`: the replay's header lane has no
    /// still skip for the window mask to refine, and a decoded picture holds
    /// no Picture in Picture window of the app's. Accepted so a replay arm
    /// runs with the same flags as on the device; the cut is measured
    /// through the app's tests and benchmark.
    case headerWindowMask
    /// No effect, as `headerStillSkip`: the cut lives in the app's header
    /// reader, and the replay reads headers through its own lane, which
    /// never looks for the app's window. Accepted so a replay arm runs with
    /// the same flags as on the device; the cut is measured through the
    /// app's tests, its replay driver and the benchmark.
    case headerCoverSkip

    /// Cuts that only the C++ engine carries.
    var needsCpp: Bool { self == .directPlanes || self == .huntBand || self == .huntHalf }

    static func parse(_ list: String) throws -> Set<ReplayCut> {
        var result: Set<ReplayCut> = []
        for name in list.split(separator: ",").map(String.init) where !name.isEmpty {
            guard let cut = ReplayCut(rawValue: name) else {
                throw ReplayError.usage("unknown cut \(name); known: " + allCases.map(\.rawValue).joined(separator: ", "))
            }
            result.insert(cut)
        }
        return result
    }

    /// Refuses a C++ cut on the Swift engine, which would otherwise run the
    /// baseline under a cut's name.
    static func validate(_ cuts: Set<ReplayCut>, engine: ReplayEngine) throws {
        let refused = cuts.filter(\.needsCpp).map(\.rawValue).sorted()
        guard engine == .cpp || refused.isEmpty else {
            throw ReplayError.usage("--cut \(refused.joined(separator: ",")) needs --engine cpp")
        }
    }

    static func engineCuts(_ cuts: Set<ReplayCut>) -> CxxEngineCuts {
        var result: CxxEngineCuts = []
        if cuts.contains(.directPlanes) { result.insert(.directPlanes) }
        if cuts.contains(.huntBand) { result.insert(.huntBand) }
        if cuts.contains(.huntHalf) { result.insert(.huntHalf) }
        return result
    }
}

/// Refuses `--engine cpp` for a shape list the core cannot hold, rather than
/// reporting a Swift run under the C++ engine's name.
func makeReplayEngine(_ engine: ReplayEngine, cuts: Set<ReplayCut>, table: GlyphTable,
                      layout: GameUILayout) throws -> FrameRecognitionEngine {
    switch engine {
    case .swift:
        return SwiftFrameRecognitionEngine(table: table, layout: layout)
    case .cpp:
        do {
            return try CxxFrameRecognitionEngine(table: table, layout: layout, cuts: ReplayCut.engineCuts(cuts))
        } catch {
            throw ReplayError.usage("--engine cpp can't take this Glyph list (\(error)); use --engine swift")
        }
    }
}

/// Which arm of the logic layer drives the replay: the tracker, the
/// sessions, the schedules and the parsers, in Swift or through the C++
/// logic layer. Independent of `--engine`, which reads the pixels.
enum ReplayLogic: String, CaseIterable, Sendable {
    case swift
    case cpp

    static func parse(_ name: String) throws -> ReplayLogic {
        guard let logic = ReplayLogic(rawValue: name) else {
            throw ReplayError.usage("--logic needs " + allCases.map(\.rawValue).joined(separator: " or "))
        }
        return logic
    }
}

func makeReplayLogicSet(_ logic: ReplayLogic, table: GlyphTable, sequenceTable: SequenceTable?,
                        sessionID: CaptureSessionID, language: GameLanguage?) -> RecognitionLogicSet {
    // Nil reads the language automatically, starting from English.
    switch logic {
    case .swift:
        return makeSwiftLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID,
                                 language: language ?? .english, automaticLanguage: language == nil)
    case .cpp:
        return makeCxxLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID,
                               language: language ?? .english, automaticLanguage: language == nil)
    }
}
