import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionCxx
import GlyphRecognitionImages

/// What a logic set's language memory reported, from whichever thread.
private final class FoundLanguages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GameLanguage] = []
    func append(_ language: GameLanguage) { lock.withLock { stored.append(language) } }
    var values: [GameLanguage] { lock.withLock { stored } }
}

/// The engine A/B's choice and cuts: how they are kept between launches, and
/// what the factory makes of them.
@Suite("Recognition engine choice")
struct RecognitionEngineChoiceTests {
    private func isolated() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-engine-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    @Test("A fresh install runs the C++ engine with the Swift logic and exactly the seven measured cuts")
    func defaults() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.recognitionEngine == .cpp)
        #expect(preferences.recognitionLogic == .swift)
        #expect(preferences.recognitionCuts == [.directPlanes, .lazyImage, .huntBand, .huntHalf, .planeGate,
                                                .headerStillSkip, .gearLeanRead])
        // The constants the Diagnostics pickers' `@AppStorage`, the Settings
        // choice and the benchmark take their defaults from.
        #expect(AppPreferences.defaultRecognitionEngine == preferences.recognitionEngine)
        #expect(AppPreferences.defaultRecognitionLogic == preferences.recognitionLogic)
        #expect(AppPreferences.defaultRecognitionCuts == preferences.recognitionCuts)
        #expect(BenchmarkEngines(AppPreferences.defaultRecognitionEngine) == .cpp)
        #expect(BenchmarkLogic(AppPreferences.defaultRecognitionLogic) == .swift)
        // Nothing was written by reading.
        for key in [AppPreferences.recognitionEngineKey, AppPreferences.recognitionLogicKey,
                    AppPreferences.recognitionCutsKey] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test("A stored engine, logic or list of cuts wins over the defaults, an empty list too")
    func storedValuesWin() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        // As an earlier build stored them: the raw values under the keys.
        defaults.set("swift", forKey: AppPreferences.recognitionEngineKey)
        #expect(preferences.recognitionEngine == .swift)
        defaults.set("cpp", forKey: AppPreferences.recognitionLogicKey)
        #expect(preferences.recognitionLogic == .cpp)
        defaults.set([String](), forKey: AppPreferences.recognitionCutsKey)
        #expect(preferences.recognitionCuts.isEmpty, "a tester who turned every cut off keeps them off")
        defaults.set(["planeGate", "lazyImage"], forKey: AppPreferences.recognitionCutsKey)
        #expect(preferences.recognitionCuts == [.lazyImage, .planeGate])
        // And through the setters, into a new launch.
        preferences.recognitionCuts = []
        preferences.recognitionEngine = .swift
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(relaunched.recognitionCuts.isEmpty && relaunched.recognitionEngine == .swift)
        #expect(defaults.stringArray(forKey: AppPreferences.recognitionCutsKey) == [])
    }

    @Test("The engine and the cuts survive into a new instance, as into a new launch")
    func roundTrip() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.recognitionEngine = .cpp
        preferences.recognitionCuts = [.huntHalf, .directPlanes]
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(relaunched.recognitionEngine == .cpp)
        #expect(relaunched.recognitionCuts == [.directPlanes, .huntHalf])
        relaunched.recognitionCuts = []
        #expect(preferences.recognitionCuts.isEmpty)
        relaunched.recognitionEngine = .swift
        #expect(preferences.recognitionEngine == .swift)
    }

    @Test("Values this build doesn't know read as the defaults, not a crash")
    func unknownValues() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("rust", forKey: AppPreferences.recognitionEngineKey)
        defaults.set(["lazyImage", "futureCut"], forKey: AppPreferences.recognitionCutsKey)
        #expect(preferences.recognitionEngine == AppPreferences.defaultRecognitionEngine)
        // A list is the tester's: the names this build knows are kept.
        #expect(preferences.recognitionCuts == [.lazyImage])
        // Something that is not a list of names is not a choice.
        defaults.set(7, forKey: AppPreferences.recognitionCutsKey)
        #expect(preferences.recognitionCuts == AppPreferences.defaultRecognitionCuts)
    }

    @Test("The logic arm is Swift on a fresh install, survives a relaunch, and an unknown value reads as Swift")
    func logicRoundTrip() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.recognitionLogic == .swift)
        preferences.recognitionLogic = .cpp
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(relaunched.recognitionLogic == .cpp)
        // Independent of the engine beside it, still the default.
        #expect(relaunched.recognitionEngine == AppPreferences.defaultRecognitionEngine)
        relaunched.recognitionLogic = .swift
        #expect(preferences.recognitionLogic == .swift)
        defaults.set("rust", forKey: AppPreferences.recognitionLogicKey)
        #expect(preferences.recognitionLogic == .swift)
        #expect(RecognitionLogicChoice.allCases.map(\.label) == ["Swift", "C++"])
    }

    @Test("The logic factory makes each arm's objects from the same tables, and none of the Glyph ones for gear only",
          arguments: RecognitionLogicChoice.allCases)
    func logicFactory(choice: RecognitionLogicChoice) throws {
        let found = FoundLanguages()
        let table = SetupDemo.builtInTable
        let names = table.glyphs.prefix(3).map(\.name)
        let sequences = try SequenceTable.parse(csv: names.joined(separator: ",") + "\n" + names.reversed().joined(separator: ","))
        let logic = makeRecognitionLogic(choice: choice, table: table, sequenceTable: sequences,
                                         sessionID: CaptureSessionID(rawValue: 7), language: .english,
                                         automaticLanguage: true) { found.append($0) }
        #expect(logic.name == choice.rawValue)
        #expect(logic.tracker.sessionID == CaptureSessionID(rawValue: 7))
        #expect(logic.tracker.state == .inactive && logic.resultSession.context == nil)
        #expect(logic.inputValidator != nil && logic.predictor != nil)
        switch choice {
        case .swift:
            #expect(logic.tracker is PresentationTracker && logic.resultSession is ResultObservationSession)
            #expect(logic.inputValidator is PlayerInputValidator && logic.pace is AnalysisRateController)
            #expect(logic.languageMemory is GameLanguageMemory && logic.commandNoticeCapture is CommandNoticeCapture)
        case .cpp:
            #expect(logic.tracker is CxxPresentationTracker && logic.resultSession is CxxResultObservationSession)
            #expect(logic.inputValidator is CxxPlayerInputValidator && logic.pace is CxxAnalysisRateController)
            #expect(logic.languageMemory is CxxGameLanguageMemory
                    && logic.commandNoticeCapture is CxxCommandNoticeCapture)
        }
        // The language memory starts where asked and reports what it finds.
        #expect(logic.languageMemory.current == .english && logic.languageMemory.isAutomatic)
        logic.languageMemory.found(.japanese)
        #expect(logic.languageMemory.current == .japanese && found.values == [.japanese])
        // The parsers read the game's own phrases as the Swift ones do.
        for phrase in HeaderPhraseMatcher.englishPortrait {
            let line = [(text: phrase.words.joined(separator: " "), confidence: 0.9)]
            #expect(logic.headerPhraseMatcher(.english).read(lines: line)
                    == HeaderPhraseMatcher(language: .english).read(lines: line))
        }
        let notices = try #require(GameText(.english).tables.first { $0.code == "en" }).notices
        #expect(!notices.isEmpty)
        for text in notices.keys {
            let notice = logic.commandNoticeParser(.english).read([(text, 1)]).notice
            #expect(notice != nil && notice == CommandNoticeParser(language: .english).read([(text, 1)]).notice,
                    "\(text)")
        }

        let gearOnly = makeRecognitionLogic(choice: choice, table: nil, sequenceTable: sequences,
                                            sessionID: CaptureSessionID(rawValue: 8), language: .japanese,
                                            automaticLanguage: false)
        #expect(gearOnly.name == choice.rawValue)
        #expect(gearOnly.inputValidator == nil && gearOnly.predictor == nil)
        #expect(gearOnly.languageMemory.current == .japanese && !gearOnly.languageMemory.isAutomatic)
    }

    @Test("A panel settle cut, the gear language settle and the header window cuts are off on a fresh install and in Settings' Old and New, and the Swift engine honours them",
          arguments: [RecognitionCut.gearSettle, .resultSettle, .gearLanguageSettle, .headerWindowMask,
                      .headerCoverSkip])
    func panelSettleOffByDefault(_ cut: RecognitionCut) throws {
        let suite = "dynamicglyph-settle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(!AppPreferences.defaultRecognitionCuts.contains(cut))
        #expect(!preferences.recognitionCuts.contains(cut))
        for selection in RecognitionEngineSelection.choices {
            selection.apply(to: preferences)
            #expect(!preferences.recognitionCuts.contains(cut), "\(selection)")
        }
        preferences.recognitionCuts = AppPreferences.defaultRecognitionCuts.union([cut])
        #expect(RecognitionEngineSelection(preferences) == .custom)
        #expect(RecognitionCut.swiftEngineCuts.contains(cut))
    }

    @Test("The plane gate is on on a fresh install and in Settings' New, off in Old; the five cuts without it are custom")
    func planeGateOnByDefault() throws {
        let suite = "dynamicglyph-gate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(AppPreferences.defaultRecognitionCuts.contains(.planeGate))
        #expect(preferences.recognitionCuts.contains(.planeGate))
        RecognitionEngineSelection.old.apply(to: preferences)
        #expect(!preferences.recognitionCuts.contains(.planeGate))
        RecognitionEngineSelection.new.apply(to: preferences)
        #expect(preferences.recognitionCuts.contains(.planeGate))
        // New as the build before it was a default stored it: a stored list
        // wins, so the session runs without the gate and Settings shows Custom.
        preferences.recognitionCuts = [.directPlanes, .lazyImage, .huntBand, .huntHalf, .headerStillSkip]
        #expect(RecognitionEngineSelection(preferences) == .custom)
        #expect(!preferences.recognitionCuts.contains(.planeGate))
        // A session that falls back to the Swift engine keeps it.
        #expect(RecognitionCut.swiftEngineCuts.contains(.planeGate))
    }

    @Test("The gear lean read is on on a fresh install and in Settings' New, off in Old; the six cuts without it are custom")
    func gearLeanReadOnByDefault() throws {
        let suite = "dynamicglyph-lean-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(AppPreferences.defaultRecognitionCuts.contains(.gearLeanRead))
        #expect(preferences.recognitionCuts.contains(.gearLeanRead))
        RecognitionEngineSelection.old.apply(to: preferences)
        #expect(!preferences.recognitionCuts.contains(.gearLeanRead))
        RecognitionEngineSelection.new.apply(to: preferences)
        #expect(preferences.recognitionCuts.contains(.gearLeanRead))
        // The gear settle stays off and out of New.
        #expect(!preferences.recognitionCuts.contains(.gearSettle))
        // New as the build before it was a default stored it: a stored list
        // wins, so the session runs without it and Settings shows Custom.
        preferences.recognitionCuts = [.directPlanes, .lazyImage, .huntBand, .huntHalf, .planeGate, .headerStillSkip]
        #expect(RecognitionEngineSelection(preferences) == .custom)
        #expect(!preferences.recognitionCuts.contains(.gearLeanRead))
        // A session that falls back to the Swift engine keeps it.
        #expect(RecognitionCut.swiftEngineCuts.contains(.gearLeanRead))
    }

    @Test("The cuts are listed in their fixed order, or as none")
    func summary() {
        #expect(Set<RecognitionCut>().summary == "none")
        #expect(Set<RecognitionCut>([.huntHalf, .lazyImage, .directPlanes]).summary == "directPlanes lazyImage huntHalf")
        #expect(RecognitionCut.allCases.sorted() == RecognitionCut.allCases)
    }

    @Test("The factory makes the Swift arm for the Swift choice, with or without a shape list")
    func swiftArm() {
        let withTable = makeRecognitionEngine(choice: .swift, table: SetupDemo.builtInTable, cuts: [])
        #expect(withTable.engine.name == "swift" && withTable.label == "swift" && withTable.fallback == nil)
        #expect(withTable.engine is SwiftFrameRecognitionEngine)
        #expect(withTable.engine.sessionValidatedAt == nil && withTable.engine.sessionCalibration == nil)
        let gearOnly = makeRecognitionEngine(choice: .swift, table: nil, cuts: [.lazyImage])
        #expect(gearOnly.engine.name == "swift" && gearOnly.cuts == [.lazyImage])
    }

    @Test("The C++ choice makes the C++ engine with its own cuts, with or without a shape list, starting with no fit")
    func cppArm() throws {
        // The default runs it, so it never stands in for the Swift arm: the
        // Power section's engine line is the one it names.
        let setup = makeRecognitionEngine(choice: .cpp, table: SetupDemo.builtInTable,
                                          cuts: AppPreferences.defaultRecognitionCuts)
        let engine = setup.engine
        #expect(engine.name == "cpp" && setup.label == "cpp" && setup.fallback == nil)
        #expect(setup.cuts == AppPreferences.defaultRecognitionCuts)
        let cxx = try #require(engine as? CxxFrameRecognitionEngine)
        #expect(cxx.cuts == [.directPlanes, .huntBand, .huntHalf], "lazyImage is the output's, not the engine's")
        #expect(engine.sessionValidatedAt == nil && engine.sessionCalibration == nil)
        engine.resetSession()
        #expect(engine.sessionValidatedAt == nil)
        let gearOnly = makeRecognitionEngine(choice: .cpp, table: nil, cuts: AppPreferences.defaultRecognitionCuts)
        #expect(gearOnly.engine.name == "cpp" && gearOnly.engine is CxxFrameRecognitionEngine)
        #expect(gearOnly.fallback == nil)
    }

    /// The demo list with Glyphs added until it holds `count`, each a single
    /// stroke from node 0 to node 1, which no demo Glyph is.
    static func demoTable(glyphs count: Int) -> GlyphTable {
        var entries = demoEntries()
        let stroke = GlyphPath(nodes: [0, 1].compactMap(NodeIndex.init(rawValue:)))
        for index in 0..<(count - entries.count) {
            entries[GlyphID("extra\(index)")] = stroke
        }
        return GlyphTable(entries: entries)
    }

    /// The demo list with one Glyph more, "long", whose walk crosses `edges`
    /// distinct edges. With 11 nodes, a prime count, stepping by 1, then by
    /// 2, and so on, each round visits every node and joins pairs no other
    /// step joins.
    static func demoTable(edges: Int) -> GlyphTable {
        let steps = (1...(NodeIndex.count - 1) / 2).flatMap { step in
            (1...NodeIndex.count).map { round in round * step % NodeIndex.count }
        }
        let path = GlyphPath(nodes: ([0] + steps.prefix(edges)).compactMap(NodeIndex.init(rawValue:)))
        var entries = demoEntries()
        entries[GlyphID("long")] = path
        return GlyphTable(entries: entries)
    }

    private static func demoEntries() -> [GlyphID: GlyphPath] {
        let demo = SetupDemo.builtInTable
        return Dictionary(uniqueKeysWithValues: demo.glyphs.compactMap { id in demo.path(for: id).map { (id, $0) } })
    }

    @Test("A list at the C++ core's limits runs the C++ engine; one over either runs Swift, says why and doesn't stop",
          arguments: [(true, false), (true, true), (false, false), (false, true)])
    func shapeListLimits(countsGlyphs: Bool, over: Bool) throws {
        let table = countsGlyphs ? Self.demoTable(glyphs: 512 + (over ? 1 : 0))
                                 : Self.demoTable(edges: 24 + (over ? 1 : 0))
        if countsGlyphs {
            #expect(table.count == (over ? 513 : 512))
        } else {
            #expect(table.path(for: GlyphID("long"))?.undirectedEdges.count == (over ? 25 : 24))
        }
        let cuts = AppPreferences.defaultRecognitionCuts
        let setup = makeRecognitionEngine(choice: .cpp, table: table, cuts: cuts)
        #expect(setup.choice == .cpp)
        guard over else {
            #expect(setup.engine is CxxFrameRecognitionEngine && setup.fallback == nil && setup.cuts == cuts)
            #expect(setup.label == "cpp")
            return
        }
        let reason = countsGlyphs ? "513 Glyphs, the C++ engine takes at most 512"
                                  : "long has 25 edges, the C++ engine takes at most 24"
        #expect(setup.engine is SwiftFrameRecognitionEngine && setup.engine.name == "swift")
        #expect(setup.fallback == reason)
        // The Swift engine honours only the output's cuts.
        #expect(setup.cuts == [.lazyImage, .planeGate, .headerStillSkip, .gearLeanRead])
        #expect(setup.label == "swift (chose cpp: \(reason))")
        #expect(setup.logLine(logic: "swift", logicChoice: .swift)
                == "recognition engine swift (chose cpp, which can't take this Glyph list: \(reason))"
                + " · logic swift (chose swift) · cuts lazyImage planeGate headerStillSkip gearLeanRead")
        // The Power section's header says the same, within its width.
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: setup.label,
                    logic: "swift", cuts: setup.cuts)
        let lines = PowerReport.lines(meter.snapshot())
        #expect(lines.allSatisfy { $0.count <= 42 }, "\(lines.filter { $0.count > 42 })")
        let start = try #require(lines.firstIndex { $0.hasPrefix("engine swift (chose cpp:") })
        let header = lines[start...].prefix { $0 == lines[start] || $0.hasPrefix(" ") }
            .joined(separator: " ").split(separator: " ").joined(separator: " ")
        #expect(header == "engine swift (chose cpp: \(reason)) · logic swift · cuts lazyImage planeGate"
                + " headerStillSkip gearLeanRead",
                "\(header)")
        // The Swift engine makes nothing of a frame before a hack, as it would on the shipped arm.
        #expect(setup.engine.sessionValidatedAt == nil && setup.engine.sessionCalibration == nil)
    }

    @Test("A choice of Swift is never reported as a fallback, whatever the list")
    func swiftChoiceOverLimits() {
        let setup = makeRecognitionEngine(choice: .swift, table: Self.demoTable(glyphs: 513),
                                          cuts: [.lazyImage, .planeGate])
        #expect(setup.fallback == nil && setup.label == "swift" && setup.cuts == [.lazyImage, .planeGate])
        #expect(setup.logLine(logic: "cpp", logicChoice: .cpp)
                == "recognition engine swift (chose swift) · logic cpp (chose cpp) · cuts lazyImage planeGate")
    }

    @Test("The Power section names the engine and its cuts after the game language, within the width")
    func powerReport() throws {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.directPlanes, .lazyImage, .huntBand, .huntHalf])
        let lines = PowerReport.lines(meter.snapshot())
        let language = try #require(lines.firstIndex { $0.hasPrefix("header OCR") })
        let engine = try #require(lines.firstIndex { $0.hasPrefix("engine cpp · cuts") })
        #expect(language < engine)
        #expect(lines.allSatisfy { $0.count <= 42 }, "\(lines.filter { $0.count > 42 })")
        // Every cut on wraps onto an indented second line; read across them.
        let words = lines[engine...].prefix(2).joined(separator: " ").split(separator: " ").joined(separator: " ")
        #expect(words == "engine cpp · cuts directPlanes lazyImage huntBand huntHalf", "\(words)")
        #expect(PowerReport.engineLines("swift", cuts: []) == ["engine swift · cuts none"])
        // With the session's logic arm, between the engine and the cuts.
        #expect(PowerReport.engineLines("cpp", logic: "cpp", cuts: [.lazyImage])
                == ["engine cpp · logic cpp · cuts lazyImage"])
        let both = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        both.reset(languages: CxxGameLanguageMemory(language: .japanese, isAutomatic: false), engine: "swift",
                   logic: "cpp", cuts: [])
        let bothLines = PowerReport.lines(both.snapshot())
        #expect(bothLines.contains("engine swift · logic cpp · cuts none"), "\(bothLines)")
        #expect(bothLines.contains { $0.hasPrefix("header OCR accurate") }, "the C++ memory's language is shown")
        // Without a session's engine the line is absent, as before.
        let bare = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        bare.reset()
        #expect(!PowerReport.lines(bare.snapshot()).contains { $0.hasPrefix("engine ") })
    }
}
