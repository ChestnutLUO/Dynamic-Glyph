import CoreGraphics
import Foundation
import Testing
import Vision
import GlyphRecognitionCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// The C++ results area (`glyph_logic_results.h`) held to its Swift oracles:
/// every scenario of the oracle tests through both arms with the same inputs,
/// compared output for output, then seeded random walks compared after every
/// step.
///
/// Serialized: the Vision part runs synchronous text requests, which never
/// return when many run at once on the parallel test runner.
@Suite("C++ logic: results", .serialized, .timeLimit(.minutes(10)))
struct CxxResultsTests {
    // MARK: - Comparing outputs

    static func rowsEqual(_ swift: [String: Any], _ cxx: [String: Any]) -> Bool {
        NSDictionary(dictionary: swift).isEqual(to: cxx)
    }

    static func expectSame(_ swift: HackResult?, _ cxx: HackResult?, _ note: String = "",
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(swift == cxx, "\(note)", sourceLocation: sourceLocation)
        guard let swift, let cxx else { return }
        #expect(swift.inputSeconds == cxx.inputSeconds, "\(note)", sourceLocation: sourceLocation)
        #expect(rowsEqual(swift.diagnosticRow, cxx.diagnosticRow), "\(note)", sourceLocation: sourceLocation)
    }

    static func expectSame(_ swift: ResultFrameEvidence, _ cxx: ResultFrameEvidence, _ note: String = "",
                           sourceLocation: SourceLocation = #_sourceLocation) {
        // A NaN in an input line is never equal to itself; the lines are the
        // input handed back, so their description stands in for equality.
        let hasNaN = swift.lines.contains { [$0.confidence, $0.x, $0.y, $0.width, $0.height].contains(where: \.isNaN) }
        if hasNaN {
            #expect(String(reflecting: swift) == String(reflecting: cxx), "\(note)", sourceLocation: sourceLocation)
            return
        }
        #expect(swift == cxx, "\(note)", sourceLocation: sourceLocation)
        #expect(rowsEqual(swift.diagnosticRow, cxx.diagnosticRow), "\(note)", sourceLocation: sourceLocation)
    }

    static func entriesEqual(_ swift: [ValidatorResultComparison.Entry],
                             _ cxx: [ValidatorResultComparison.Entry]) -> Bool {
        swift.count == cxx.count && zip(swift, cxx).allSatisfy { left, right in
            left.slotIndex == right.slotIndex && left.attemptID == right.attemptID
                && left.validatorVerdict == right.validatorVerdict && left.gameOutcome == right.gameOutcome
                && left.status == right.status && left.drawSeconds == right.drawSeconds
                && rowsEqual(left.diagnosticRow, right.diagnosticRow)
        }
    }

    static func expectSame(_ swift: [ValidatorResultComparison.Entry], _ cxx: [ValidatorResultComparison.Entry],
                           _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(entriesEqual(swift, cxx), "\(note)", sourceLocation: sourceLocation)
    }

    /// The summary, its presentation decisions and the command summary's
    /// `effective` values, both arms.
    static func expectSameSummary(_ result: HackResult, _ entries: [ValidatorResultComparison.Entry],
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let swift = HackResultSummary(result: result, comparison: entries)
        let cxx = CxxHackResultSummary.make(result: result, comparison: entries)
        #expect(swift == cxx, sourceLocation: sourceLocation)
        #expect(swift.hasProvisionalBonus
                    == CxxHackResultSummary.hasProvisionalBonus(result: result, comparison: entries),
                sourceLocation: sourceLocation)
        let expected: [CxxHackResultSummary.Headline: String] = [
            .awaiting: "Waiting for the result screen…", .complete: "Result read", .partial: "Result partly read",
            .noResultScreen: "No result screen seen", .stoppedBeforeResult: "Stopped before the result screen",
        ]
        #expect(expected[CxxHackResultSummary.headline(result: result, comparison: entries)] == swift.headline,
                sourceLocation: sourceLocation)
        let disagreements = CxxHackResultSummary.disagreements(result: result, comparison: entries)
        #expect(disagreements.count == swift.disagreementLines.count, sourceLocation: sourceLocation)
        for (line, index) in zip(swift.disagreementLines, disagreements) {
            #expect(line.hasPrefix("Glyph \(index + 1):"), sourceLocation: sourceLocation)
        }
        if let commands = result.context.commands {
            #expect(CxxHackResultSummary.effective(commands.presentation) == commands.presentation.effective,
                    sourceLocation: sourceLocation)
            #expect(CxxHackResultSummary.effective(commands.gear) == commands.gear.effective,
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Paired arms

    /// A `HackResultTracker` and the C++ tracker driven together, compared
    /// after every call.
    final class TrackerPair {
        var swift: HackResultTracker
        let cxx: CxxHackResultTracker
        private(set) var comparisons = 0

        init(context: ResultReadContext, policy: HackResultTracker.Policy = .init()) {
            swift = HackResultTracker(context: context, policy: policy)
            cxx = CxxHackResultTracker(context: context, policy: policy)
            check()
        }

        var result: HackResult { swift.result }

        func accept(_ evidence: ResultFrameEvidence, sourceLocation: SourceLocation = #_sourceLocation) {
            let changed = swift.accept(evidence)
            #expect(changed == cxx.accept(evidence), sourceLocation: sourceLocation)
            check(sourceLocation: sourceLocation)
        }

        func observeFrame(at time: Double, inputVisible: Bool, exitVisible: Bool, panelCandidate: Bool,
                          sourceLocation: SourceLocation = #_sourceLocation) {
            swift.observeFrame(at: time, inputVisible: inputVisible, exitVisible: exitVisible,
                               panelCandidate: panelCandidate)
            cxx.observeFrame(at: time, inputVisible: inputVisible, exitVisible: exitVisible,
                             panelCandidate: panelCandidate)
            check(sourceLocation: sourceLocation)
        }

        func finish(at time: Double, reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
            swift.finish(at: time, reason: reason)
            cxx.finish(at: time, reason: reason)
            check(sourceLocation: sourceLocation)
        }

        func check(sourceLocation: SourceLocation = #_sourceLocation) {
            comparisons += 1
            CxxResultsTests.expectSame(swift.result, cxx.result, sourceLocation: sourceLocation)
            #expect(swift.revision == cxx.revision, sourceLocation: sourceLocation)
            CxxResultsTests.expectSameSummary(swift.result, [], sourceLocation: sourceLocation)
        }
    }

    /// A `ValidatorResultComparison` and the C++ comparison, compared after
    /// every call on `results`.
    final class ComparisonPair {
        var swift: ValidatorResultComparison
        let cxx: CxxValidatorResultComparison
        let results: () -> [HackResult]

        init(context: ResultReadContext, results: @escaping () -> [HackResult]) {
            swift = ValidatorResultComparison(context: context)
            cxx = CxxValidatorResultComparison(context: context)
            self.results = results
        }

        func observe(_ evidence: FrameEvidence, inputVisible: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            swift.observe(evidence, inputVisible: inputVisible)
            cxx.observe(evidence, inputVisible: inputVisible)
            check(sourceLocation: sourceLocation)
        }

        func accept(_ events: [InputCheckEvent], sourceLocation: SourceLocation = #_sourceLocation) {
            swift.accept(events)
            cxx.accept(events)
            check(sourceLocation: sourceLocation)
        }

        func compare(_ result: HackResult, sourceLocation: SourceLocation = #_sourceLocation)
            -> [ValidatorResultComparison.Entry] {
            let entries = swift.compare(result)
            CxxResultsTests.expectSame(entries, cxx.compare(result), sourceLocation: sourceLocation)
            CxxResultsTests.expectSameSummary(result, entries, sourceLocation: sourceLocation)
            return entries
        }

        func check(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(swift.supersededAttemptIDs == cxx.supersededAttemptIDs, sourceLocation: sourceLocation)
            for result in results() { _ = compare(result, sourceLocation: sourceLocation) }
        }
    }

    /// A `ResultObservationSession` and the C++ session, compared after
    /// every call: context, the tracker's result and revision, the
    /// comparison's superseded IDs and its entries for the current result.
    final class SessionPair {
        var swift: ResultObservationSession
        let cxx: CxxResultObservationSession
        private(set) var comparisons = 0

        init(glyphs: [GlyphID]) {
            swift = ResultObservationSession()
            cxx = CxxResultObservationSession(glyphs: glyphs)
        }

        private init(swift: ResultObservationSession, cxx: CxxResultObservationSession) {
            self.swift = swift
            self.cxx = cxx
        }

        func copy() -> SessionPair { SessionPair(swift: swift, cxx: cxx.copy()) }

        var context: ResultReadContext? { swift.context }
        var result: HackResult? { swift.tracker?.result }

        @discardableResult
        func observe(_ evidence: FrameEvidence, presentation: PresentationTracker, panelCandidate: Bool,
                     imageAnalyzed: Bool = true, commands: HackCommandSummary? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation) -> HackResult? {
            // As the app does: the comparison before the call judges the
            // result the call retires.
            let swiftBefore = swift.comparison
            let cxxBefore = cxx.comparison
            let retired = swift.observe(evidence, presentation: presentation, panelCandidate: panelCandidate,
                                        imageAnalyzed: imageAnalyzed, commands: commands)
            let cxxRetired = cxx.observe(evidence, presentation: presentation, panelCandidate: panelCandidate,
                                         imageAnalyzed: imageAnalyzed, commands: commands)
            CxxResultsTests.expectSame(retired, cxxRetired, "retired", sourceLocation: sourceLocation)
            if let retired {
                #expect((swiftBefore == nil) == (cxxBefore == nil), sourceLocation: sourceLocation)
                if let swiftBefore, let cxxBefore {
                    #expect(swiftBefore.supersededAttemptIDs == cxxBefore.supersededAttemptIDs,
                            sourceLocation: sourceLocation)
                    let entries = swiftBefore.compare(retired)
                    CxxResultsTests.expectSame(entries, cxxBefore.compare(retired), "retired entries",
                                               sourceLocation: sourceLocation)
                    CxxResultsTests.expectSameSummary(retired, entries, sourceLocation: sourceLocation)
                }
            }
            check(sourceLocation: sourceLocation)
            return retired
        }

        func accept(_ evidence: ResultFrameEvidence, sourceLocation: SourceLocation = #_sourceLocation) {
            swift.accept(evidence)
            cxx.accept(evidence)
            check(sourceLocation: sourceLocation)
        }

        func accept(_ events: [InputCheckEvent], sourceLocation: SourceLocation = #_sourceLocation) {
            swift.accept(events)
            cxx.accept(events)
            check(sourceLocation: sourceLocation)
        }

        func finish(at time: Double, reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
            swift.finish(at: time, reason: reason)
            cxx.finish(at: time, reason: reason)
            check(sourceLocation: sourceLocation)
        }

        func check(sourceLocation: SourceLocation = #_sourceLocation) {
            comparisons += 1
            #expect(swift.context == cxx.context, sourceLocation: sourceLocation)
            let swiftTracker = swift.tracker, cxxTracker = cxx.tracker
            #expect((swiftTracker == nil) == (cxxTracker == nil), sourceLocation: sourceLocation)
            if let swiftTracker, let cxxTracker {
                CxxResultsTests.expectSame(swiftTracker.result, cxxTracker.result, "tracker",
                                           sourceLocation: sourceLocation)
                #expect(swiftTracker.revision == cxxTracker.revision, sourceLocation: sourceLocation)
            }
            let swiftComparison = swift.comparison, cxxComparison = cxx.comparison
            #expect((swiftComparison == nil) == (cxxComparison == nil), sourceLocation: sourceLocation)
            if let swiftComparison, let cxxComparison {
                #expect(swiftComparison.supersededAttemptIDs == cxxComparison.supersededAttemptIDs,
                        sourceLocation: sourceLocation)
                if let result = swiftTracker?.result {
                    let entries = swiftComparison.compare(result)
                    CxxResultsTests.expectSame(entries, cxxComparison.compare(result), "entries",
                                               sourceLocation: sourceLocation)
                    CxxResultsTests.expectSameSummary(result, entries, sourceLocation: sourceLocation)
                }
            }
        }
    }

    final class SchedulePair {
        var swift = ResultEvidenceSchedule()
        let cxx = CxxResultEvidenceSchedule()

        @discardableResult
        func select(_ evidence: ResultFrameEvidence, decision: Bool,
                    sourceLocation: SourceLocation = #_sourceLocation) -> ResultEvidenceSchedule.Selection? {
            let selection = swift.select(evidence, decision: decision)
            #expect(selection == cxx.select(evidence, decision: decision), sourceLocation: sourceLocation)
            return selection
        }
    }

    final class WatchPair {
        var swift = CommandScreenWatch()
        let cxx = CxxCommandScreenWatch()

        @discardableResult
        func observe(at time: Double, calibrated: Bool, commandPhase: Bool, complete: Bool,
                     sourceLocation: SourceLocation = #_sourceLocation) -> CommandScreenWatch.Action {
            let action = swift.observe(at: time, calibrated: calibrated, commandPhase: commandPhase, complete: complete)
            #expect(action == cxx.observe(at: time, calibrated: calibrated, commandPhase: commandPhase,
                                          complete: complete), sourceLocation: sourceLocation)
            #expect(swift.watching == cxx.watching, sourceLocation: sourceLocation)
            return action
        }

        func stop() { swift.stop(); cxx.stop(); #expect(swift.watching == cxx.watching) }
        func reset() { swift.reset(); cxx.reset(); #expect(swift.watching == cxx.watching) }
        var watching: Bool { swift.watching }
    }

    /// Both arms of `CommandPhaseContext`, compared on every `isCurrent`.
    final class ContextPair {
        var swift = CommandPhaseContext()
        var cxx = CxxCommandPhaseContext()
        private(set) var checks = 0, current = 0

        init(leave: Double? = nil) {
            if let leave { swift.leave = leave; cxx.leave = leave }
            #expect(swift.leave == cxx.leave)
        }
        func header(_ reading: HeaderReading) { swift.header(reading); cxx.header(reading) }
        func header(_ phase: GamePhase, at time: Double) { swift.header(phase, at: time); cxx.header(phase, at: time) }
        func notice(at time: Double) { swift.notice(at: time); cxx.notice(at: time) }
        func noticeRead(at time: Double?) { swift.noticeRead(at: time); cxx.noticeRead(at: time) }
        func reset() { swift.reset(); cxx.reset() }
        @discardableResult
        func isCurrent(at time: Double, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
            let expected = swift.isCurrent(at: time)
            #expect(expected == cxx.isCurrent(at: time), "isCurrent at \(time)", sourceLocation: sourceLocation)
            checks += 1
            if expected { current += 1 }
            return expected
        }
    }

    /// Every language's parser, both arms, on the same lines.
    static func expectParsersAgree(_ lines: [ResultTextLine], context: ResultReadContext, at time: Double = 1,
                                   appearances: [ResultSlotAppearance] = [], parsers: [CxxResultTextParser],
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        for cxx in parsers {
            let swift = ResultTextParser(language: cxx.language)
            CxxResultsTests.expectSame(swift.read(lines: lines, context: context, at: time, appearances: appearances),
                                       cxx.read(lines: lines, context: context, at: time, appearances: appearances),
                                       "\(cxx.language)", sourceLocation: sourceLocation)
        }
    }

    static func allParsers() -> [CxxResultTextParser] { GameLanguage.allCases.map { CxxResultTextParser(language: $0) } }

    // MARK: - ResultRecognitionTests, through both arms

    let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                    glyphs: ["truth", "idea", "discover", "xm"])

    func frame(_ time: Double, stage: Int? = 3, hacking: Int? = 120, speed: Int? = 55,
               appearances: [ResultSlotAppearance] = [.gold, .gold, .gold, .gold],
               context: ResultReadContext? = nil, present: Bool = true) -> ResultFrameEvidence {
        ResultFrameEvidence(context: context ?? self.context, sourceTime: time, panelPresent: present,
            stageIndex: stage, hackingBonus: hacking, speedBonus: speed, appearances: appearances)
    }

    @Test("Final values survive departure; intermediate stable bonuses never finalize")
    func finalStage() {
        let tracker = TrackerPair(context: context)
        for i in 0..<6 { tracker.accept(frame(Double(i) * 0.1, stage: 2, hacking: 90)) }
        #expect(tracker.result.finalHackingBonus == nil)
        for i in 0..<5 { tracker.accept(frame(1 + Double(i) * 0.1)) }
        #expect(tracker.result.finalHackingBonus == 120 && tracker.result.state == .complete)
        tracker.observeFrame(at: 1.5, inputVisible: false, exitVisible: false, panelCandidate: false)
        tracker.observeFrame(at: 1.8, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(tracker.result.closeReason == "panelLeft")
    }

    @Test("Input time runs from the first to the last input frame before the result")
    func inputTime() {
        let tracker = TrackerPair(context: context)
        for i in 0...30 {
            tracker.observeFrame(at: 1 + Double(i) * 0.1, inputVisible: true, exitVisible: false, panelCandidate: false)
        }
        #expect(tracker.result.inputSeconds == nil)
        tracker.accept(frame(4.3))
        tracker.observeFrame(at: 4.4, inputVisible: true, exitVisible: false, panelCandidate: true)
        #expect(tracker.result.inputSeconds.map { abs($0 - 3) < 1e-9 } == true)
    }

    @Test("One- and two-frame value lag cannot confirm the previous bonus", arguments: [1, 2])
    func delayedValue(frames: Int) {
        let tracker = TrackerPair(context: context)
        for i in 0..<9 { tracker.accept(frame(Double(i) * 0.05, hacking: i < frames ? 90 : 120)) }
        #expect(tracker.result.finalHackingBonus == 120)
    }

    @Test("A rejected last slot need not light up or increase either bonus")
    func wrongLast() {
        let tracker = TrackerPair(context: context)
        for i in 0..<5 {
            tracker.accept(frame(Double(i) * 0.1, hacking: 90, speed: 0, appearances: [.gold, .gold, .gold, .unreadable]))
        }
        #expect(tracker.result.state == .partial && tracker.result.finalSpeedBonus == 0)
    }

    @Test("A lit last contour stands in for an unread name; an earlier name contradicts it")
    func contourRevealsFinalStage() {
        let lit: [ResultSlotAppearance] = [.gold, .gold, .gold, .gold]
        let tracker = TrackerPair(context: context)
        tracker.accept(frame(0.0, stage: nil, appearances: lit))
        tracker.accept(frame(0.15, stage: nil, appearances: lit))
        #expect(tracker.result.finalHackingBonus == 120 && tracker.result.finalStageTime == 0.0)
        let magenta = TrackerPair(context: context)
        magenta.accept(frame(0.0, stage: nil, hacking: 90, appearances: [.gold, .gold, .gold, .magenta]))
        magenta.accept(frame(0.15, stage: nil, hacking: 90, appearances: [.gold, .gold, .gold, .magenta]))
        #expect(magenta.result.finalHackingBonus == 90)
        let contradicted = TrackerPair(context: context)
        contradicted.accept(frame(0.0, stage: 2, appearances: lit))
        contradicted.accept(frame(0.15, stage: 2, appearances: lit))
        #expect(contradicted.result.finalHackingBonus == nil)
        let repeated = ResultReadContext(sessionID: context.sessionID, hackID: 1, glyphs: ["mind", "open", "mind"])
        let repeatedTracker = TrackerPair(context: repeated)
        for time in [0.0, 0.15] {
            repeatedTracker.accept(ResultFrameEvidence(context: repeated, sourceTime: time, panelPresent: true,
                stageIndex: nil, hackingBonus: 90, speedBonus: 20, appearances: [.gold, .gold, .gold]))
        }
        #expect(repeatedTracker.result.finalHackingBonus == 90)
    }

    @Test("Chinese result OCR's fullwidth percent sign confirms the final speed bonus",
          arguments: [("54％", 54), ("90％", 90)])
    func fullwidthPercent(_ sample: (String, Int)) {
        let context = ResultReadContext(sessionID: .init(rawValue: 1), hackID: 12, glyphs: ["gain", "future", "escape"])
        func line(_ text: String, _ y: Double) -> ResultTextLine {
            .init(text: text, confidence: 0.5, x: 0.35, y: y, width: 0.3, height: 0.02)
        }
        let lines = [line("ESCAPE", 0.20), line("入侵奖励：", 0.32), line("86%", 0.40),
                     line("速度奖励：", 0.48), line(sample.0, 0.56)]
        let parser = ResultTextParser(language: .simplifiedChinese)
        let cxxParser = CxxResultTextParser(language: .simplifiedChinese)
        let tracker = TrackerPair(context: context)
        for time in [458.427, 458.527] {
            let evidence = parser.read(lines: lines, context: context, at: time, appearances: [.gold, .gold, .gold])
            Self.expectSame(evidence, cxxParser.read(lines: lines, context: context, at: time,
                                                     appearances: [.gold, .gold, .gold]))
            tracker.accept(evidence)
        }
        #expect(tracker.result.finalSpeedBonus == sample.1)
        Self.expectParsersAgree(lines, context: context, appearances: [.gold, .gold, .gold], parsers: Self.allParsers())
    }

    @Test("Covered stage keeps stable percentages provisional")
    func coveredStage() {
        let tracker = TrackerPair(context: context)
        let covered = Array(repeating: ResultSlotAppearance.unreadable, count: 4)
        for i in 0..<10 { tracker.accept(frame(Double(i) * 0.1, stage: nil, appearances: covered)) }
        tracker.finish(at: 1, reason: "panelLeft")
        #expect(tracker.result.state == .partial && tracker.result.finalHackingBonus == nil)
    }

    @Test("Duplicate, late, and foreign readings do not vote")
    func identities() {
        let tracker = TrackerPair(context: context)
        tracker.accept(frame(1))
        for _ in 0..<5 { tracker.accept(frame(1)) }
        tracker.accept(frame(0.9))
        tracker.accept(frame(1.1, context: ResultReadContext(sessionID: context.sessionID, hackID: 2, glyphs: context.glyphs)))
        tracker.finish(at: 1.2, reason: "newHack")
        tracker.accept(frame(1.3))
        #expect(tracker.result.lastPanelTime == 1)
    }

    @Test("Frame gaps, single colours, and contradictory colours stay unknown")
    func colourUncertainty() {
        let tracker = TrackerPair(context: context)
        tracker.accept(frame(0)); tracker.accept(frame(0.4))
        tracker.accept(frame(0.5))
        #expect(tracker.result.outcomes.first == .accepted)
        for i in 6..<12 { tracker.accept(frame(Double(i) * 0.1, appearances: [.magenta])) }
        #expect(tracker.result.outcomes.first == .unknown)
    }

    @Test("Early Done and stop before a panel preserve unknown fields")
    func noConclusion() {
        let tracker = TrackerPair(context: context)
        tracker.observeFrame(at: 0, inputVisible: true, exitVisible: false, panelCandidate: false)
        tracker.observeFrame(at: 1, inputVisible: false, exitVisible: true, panelCandidate: false)
        tracker.observeFrame(at: 5.9, inputVisible: false, exitVisible: false, panelCandidate: false)
        tracker.observeFrame(at: 6.1, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(tracker.result.closeReason == "resultTimeout")
        let stopped = TrackerPair(context: context)
        stopped.finish(at: 0.1, reason: "captureStopped")
        #expect(stopped.result.state == .notObserved)
    }

    @Test("Hidden input evidence without an observed exit never times out a hack")
    func hiddenInputKeepsHackOpen() {
        let tracker = TrackerPair(context: context)
        tracker.observeFrame(at: 0, inputVisible: true, exitVisible: false, panelCandidate: false)
        for i in 1...200 {
            tracker.observeFrame(at: Double(i) * 0.05, inputVisible: false, exitVisible: false, panelCandidate: false)
        }
        for i in 0..<3 { tracker.accept(frame(10.1 + Double(i) * 0.1)) }
        #expect(tracker.result.finalHackingBonus == 120)
        let resumed = TrackerPair(context: context)
        resumed.observeFrame(at: 0, inputVisible: false, exitVisible: true, panelCandidate: false)
        resumed.observeFrame(at: 4, inputVisible: true, exitVisible: false, panelCandidate: false)
        resumed.observeFrame(at: 5.5, inputVisible: false, exitVisible: true, panelCandidate: false)
        resumed.observeFrame(at: 10, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(resumed.result.state == .awaiting)
    }

    @Test("Two agreeing final-stage reads 0.2 s apart finalize within a 0.4-s stage")
    func sparseFinalReads() {
        let tracker = TrackerPair(context: context)
        tracker.accept(frame(0.0, stage: 2, hacking: 90))
        tracker.accept(frame(0.2, stage: 2, hacking: 90))
        tracker.accept(frame(0.4))
        tracker.accept(frame(0.6))
        #expect(tracker.result.finalStageTime == 0.4)
        tracker.accept(frame(0.8, hacking: 130))
        #expect(tracker.result.finalHackingBonus == nil)
    }

    @Test("A policy other than the default is honoured")
    func customPolicy() {
        var policy = HackResultTracker.Policy()
        policy.minimumSpan = 0.3; policy.maximumReadingGap = 0.5; policy.panelExitSpan = 0.4; policy.resultWait = 1
        let tracker = TrackerPair(context: context, policy: policy)
        for i in 0..<8 { tracker.accept(frame(Double(i) * 0.12)) }
        for i in 0..<10 {
            tracker.observeFrame(at: 1 + Double(i) * 0.1, inputVisible: false, exitVisible: i > 3, panelCandidate: false)
        }
        #expect(tracker.result.closedAt != nil)
    }

    // The session scenarios, on a presentation tracker at input for two slots.

    static let sessionTable = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!,
                                                   GlyphID("beta"): GlyphPath(encoded: "456")!])

    func inputSession() -> (SessionPair, PresentationTracker, Double) {
        let session = CaptureSessionID(rawValue: 1)
        let table = Self.sessionTable
        var presentation = PresentationTracker(sessionID: session)
        let results = SessionPair(glyphs: table.glyphs)
        var time = 0.0
        for (phase, index, name) in [(GamePhase.presenting, 0, "alpha"), (.presenting, 1, "beta"), (.input, 0, "beta")] {
            for _ in 0..<4 {
                time += 0.05
                let edges = GlyphFrameRecognizer(table: table).expectedEdges(for: GlyphID(name))!
                let evidence = FrameEvidence(sessionID: session, time: time,
                    header: HeaderReading(phase: phase, matchedText: "", confidence: 1, sourceTime: time),
                    slots: SlotStripReading(slotCount: 2, highlightedIndex: index, markerCentersX: [],
                                            hasInputTimerBar: phase == .input),
                    shape: ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name), edges: edges, extensions: []),
                    hasValidCalibration: true)
                presentation.accept(evidence)
                results.observe(evidence, presentation: presentation, panelCandidate: false)
            }
        }
        return (results, presentation, time)
    }

    func blank(_ time: Double, rejection: SlotStripRejection? = nil) -> FrameEvidence {
        FrameEvidence(sessionID: CaptureSessionID(rawValue: 1), time: time, header: nil, slots: nil,
                      slotRejection: rejection, shape: .unavailable, hasValidCalibration: false)
    }

    @Test("Idle frames never count as the panel leaving; analyzed empty frames do")
    func idleFramesKeepPanel() throws {
        let (results, presentation, start) = inputSession()
        var time = start
        let context = try #require(results.context)
        #expect(context.glyphs == ["alpha", "beta"])
        results.accept(ResultFrameEvidence(context: context, sourceTime: time + 0.05, panelPresent: true))
        for i in 1...10 {
            results.observe(blank(time + 0.05 + Double(i) * 0.05), presentation: presentation, panelCandidate: false,
                            imageAnalyzed: false)
        }
        #expect(results.result?.closedAt == nil)
        time += 0.6
        for i in 1...8 { results.observe(blank(time + Double(i) * 0.05), presentation: presentation, panelCandidate: false) }
        #expect(results.result?.closeReason == "panelLeft")
    }

    @Test("A timer-bar dropout over a readable strip keeps attempt links; losing both does not")
    func timerDropoutKeepsLinks() {
        func strip(_ time: Double, index: Int?, timer: Bool) -> FrameEvidence {
            FrameEvidence(sessionID: CaptureSessionID(rawValue: 1), time: time, header: nil,
                slots: index.map { SlotStripReading(slotCount: 2, highlightedIndex: $0, markerCentersX: [],
                                                    hasInputTimerBar: timer) },
                shape: .unavailable, hasValidCalibration: true, hasInputTimerBar: timer)
        }
        func run(dropStrip: Bool) -> Set<Int> {
            let (results, presentation, start) = inputSession()
            var time = start
            results.accept([InputCheckEvent(kind: .started, time: time, hackID: presentation.hackID, slotIndex: 0,
                                            attemptID: 1, reason: nil, result: nil, edgeEvidence: [])])
            for timer in [true, true, false, false, true, true] {
                time += 0.05
                results.observe(strip(time, index: dropStrip && !timer ? nil : 0, timer: timer),
                                presentation: presentation, panelCandidate: false)
            }
            return results.swift.comparison?.supersededAttemptIDs ?? []
        }
        #expect(run(dropStrip: false).isEmpty)
        #expect(run(dropStrip: true) == [1])
    }

    @Test("An empty strip starts the wait; a covered strip does not")
    func exitEvidence() {
        let (setup, presentation, start) = inputSession()
        let covered = setup.copy()
        for i in 1...140 {
            covered.observe(blank(start + Double(i) * 0.05, rejection: .coveredByOverlay), presentation: presentation,
                            panelCandidate: false)
        }
        #expect(covered.result?.closedAt == nil)
        let exited = setup.copy()
        for i in 1...110 {
            exited.observe(blank(start + Double(i) * 0.05, rejection: .noMarkers), presentation: presentation,
                           panelCandidate: false)
        }
        #expect(exited.result?.closeReason == "resultTimeout")
        // The copies left the original untouched, in both arms.
        setup.check()
        #expect(setup.result?.closedAt == nil)
    }

    @Test("A fully covered strip and timer do not retire the hack before its real conclusion")
    func coveredPixelsKeepResultWindow() throws {
        let (results, initial, start) = inputSession()
        var presentation = initial
        let context = try #require(results.context)
        let reader = SlotStripReader()
        let band = FrameTopBand(image: try ColorImage(width: 603, height: 323,
            pixels: Array(repeating: 180, count: 603 * 323 * 3)), frameHeight: 1311)
        guard case .failure(let rejection) = reader.read(band) else {
            Issue.record("An opaque banner must not produce slot evidence"); return
        }
        for i in 1...140 {
            let time = start + Double(i) * 0.05
            let evidence = FrameEvidence(sessionID: context.sessionID, time: time, header: nil, slots: nil,
                slotRejection: rejection, shape: .unavailable, hasValidCalibration: false,
                hasInputTimerBar: reader.hasTimerBar(band))
            presentation.accept(evidence)
            results.observe(evidence, presentation: presentation, panelCandidate: false)
        }
        for i in 0..<3 {
            results.accept(ResultFrameEvidence(context: context, sourceTime: start + 7.1 + Double(i) * 0.1,
                panelPresent: true, stageIndex: 1, hackingBonus: 60, speedBonus: 10, appearances: [.gold, .gold]))
        }
        #expect(results.result?.state == .complete)
    }

    @Test("A current input header contradicts empty-strip exit evidence; an old one expires")
    func inputHeaderKeepsResultWindow() throws {
        let (results, initial, start) = inputSession()
        var presentation = initial
        let context = try #require(results.context)
        let lastHeaderTime = start + 7
        for i in 1...280 {
            let time = start + Double(i) * 0.05
            let header = HeaderReading(phase: .input, matchedText: "GO!", confidence: 1, sourceTime: min(time, lastHeaderTime))
            let evidence = FrameEvidence(sessionID: context.sessionID, time: time, header: header, slots: nil,
                                         slotRejection: .noMarkers, shape: .unavailable, hasValidCalibration: false)
            presentation.accept(evidence)
            results.observe(evidence, presentation: presentation, panelCandidate: false)
        }
        #expect(results.result?.closeReason == "resultTimeout")
    }

    @Test("A new hack retires the old result; the comparison taken before judges it")
    func newHackRetires() throws {
        let (results, presentation, start) = inputSession()
        let context = try #require(results.context)
        results.accept([InputCheckEvent(kind: .started, time: start, hackID: presentation.hackID, slotIndex: 0,
                                        attemptID: 7, reason: nil, result: nil, edgeEvidence: [])])
        for i in 0..<3 {
            results.accept(ResultFrameEvidence(context: context, sourceTime: start + 0.1 + Double(i) * 0.1,
                panelPresent: true, stageIndex: 1, hackingBonus: 60, speedBonus: 10, appearances: [.gold, .magenta]))
        }
        // A second hack, through a fresh presentation tracker's next hack.
        var next = presentation
        var time = start + 1
        let table = Self.sessionTable
        var retired: HackResult?
        for (phase, index, name) in [(GamePhase.completed, 0, "alpha"), (.command, 0, "alpha"), (.presenting, 0, "beta"),
                                     (.presenting, 1, "alpha"), (.input, 0, "alpha")] {
            for _ in 0..<5 {
                time += 0.05
                let edges = GlyphFrameRecognizer(table: table).expectedEdges(for: GlyphID(name))!
                let evidence = FrameEvidence(sessionID: context.sessionID, time: time,
                    header: HeaderReading(phase: phase, matchedText: "", confidence: 1, sourceTime: time),
                    slots: phase == .command ? nil : SlotStripReading(slotCount: 2, highlightedIndex: index,
                                                                      markerCentersX: [], hasInputTimerBar: phase == .input),
                    shape: ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name), edges: edges, extensions: []),
                    hasValidCalibration: true)
                next.accept(evidence)
                if let value = results.observe(evidence, presentation: next, panelCandidate: false,
                                               commands: HackCommandSummary.unobserved) {
                    retired = value
                }
            }
        }
        #expect(next.hackID != presentation.hackID)
        // The panel had already left, so the old result closed before the
        // new hack retired it.
        #expect(retired?.closeReason == "panelLeft" && retired?.state == .complete)
        results.finish(at: time, reason: "endOfStream")
    }

    @Test("Parser: both labels and field positions are required; zero and over 100 are valid")
    func parser() {
        func line(_ text: String, y: Double) -> ResultTextLine {
            ResultTextLine(text: text, confidence: 0.9, x: 0.2, y: y, width: 0.5, height: 0.02)
        }
        let parsers = Self.allParsers()
        let labels = [line("HACKING BONUS:", y: 0.33), line("SPEED BONUS:", y: 0.49)]
        let lines = labels + [line("XM", y: 0.20), line("120%", y: 0.4), line("0%", y: 0.56)]
        let repeated = ResultReadContext(sessionID: context.sessionID, hackID: 1, glyphs: ["xm", "xm"])
        for (set, context) in [(lines, context), (Array(lines.dropFirst()), context),
                               (lines + [line("90%", y: 0.4)], context), (lines, repeated), (labels, context)] {
            Self.expectParsersAgree(set, context: context, appearances: [.gold, .magenta, .unreadable, .gold],
                                    parsers: parsers)
        }
        let parsed = CxxResultTextParser().read(lines: lines, context: context, at: 1)
        #expect(parsed.panelPresent && parsed.stageIndex == 3 && parsed.hackingBonus == 120 && parsed.speedBonus == 0)
    }

    @Test("Evidence budget starts with numbers and reserves final decisions")
    func evidenceBudget() {
        let schedule = SchedulePair()
        #expect(schedule.select(frame(0, stage: nil, hacking: nil, speed: nil), decision: false) == .detection)
        #expect(schedule.select(frame(1, stage: nil, hacking: nil, speed: nil), decision: false) == nil)
        #expect(schedule.select(frame(2), decision: false) == .animation)
        #expect(schedule.select(frame(4.4), decision: false) == .animation)
        #expect(schedule.select(frame(4.6), decision: false) == .budgetExhausted)
        #expect(schedule.select(frame(4.7), decision: false) == nil)
        #expect(schedule.select(frame(5), decision: true) == .decision)
        // A new context starts a new budget; an absent panel is never kept.
        let other = ResultReadContext(sessionID: context.sessionID, hackID: 2, glyphs: context.glyphs)
        #expect(schedule.select(frame(5.1, context: other, present: false), decision: true) == nil)
        #expect(schedule.select(frame(5.2, context: other), decision: false) == .detection)
        schedule.swift = ResultEvidenceSchedule(); schedule.cxx.reset()
        #expect(schedule.select(frame(5.3, context: other), decision: false) == .detection)
    }

    // MARK: - HackResultSummaryTests

    let summaryContext = ResultReadContext(sessionID: CaptureSessionID(rawValue: 3), hackID: 2,
                                           glyphs: ["help", "resistance", nil, "victory"])

    func summaryResult(finalHacking: Int? = 120, observedHacking: Int? = 120, finalSpeed: Int? = 49,
                       observedSpeed: Int? = 49, outcomes: [GameSlotOutcome] = [.accepted, .rejected, .unknown, .accepted],
                       state: HackResult.State = .partial, closedAt: Double? = 5, reason: String = "panelLeft") -> HackResult {
        var result = HackResult(context: summaryContext, outcomes: outcomes, outcomeTimes: outcomes.map { _ in nil })
        result.state = state
        result.finalHackingBonus = finalHacking; result.observedHackingBonus = observedHacking
        result.finalSpeedBonus = finalSpeed; result.observedSpeedBonus = observedSpeed
        result.closedAt = closedAt; result.closeReason = closedAt == nil ? nil : reason
        return result
    }

    func entry(_ slot: Int, _ verdict: InputCheckVerdict?, _ outcome: GameSlotOutcome,
               _ status: ValidatorResultComparison.Status, drawSeconds: Double? = nil) -> ValidatorResultComparison.Entry {
        ValidatorResultComparison.Entry(slotIndex: slot, attemptID: slot + 1, validatorVerdict: verdict,
                                        gameOutcome: outcome, status: status, drawSeconds: drawSeconds)
    }

    @Test("Summaries: bonuses, slots, disagreements, headlines, labels and round trips agree")
    func summaries() throws {
        Self.expectSameSummary(summaryResult(), [])
        Self.expectSameSummary(summaryResult(finalHacking: nil, observedHacking: 90), [])
        Self.expectSameSummary(summaryResult(finalSpeed: nil, observedSpeed: nil), [])
        Self.expectSameSummary(summaryResult(), [entry(0, .matched, .accepted, .agreement),
                                                 entry(1, .matched, .rejected, .disagreement)])
        Self.expectSameSummary(summaryResult(outcomes: [.accepted, .rejected, .accepted, .unknown]), [
            entry(0, .differs, .accepted, .disagreement), entry(1, .matched, .rejected, .disagreement),
            entry(2, .unavailable, .accepted, .coverageGap), entry(3, nil, .unknown, .unknownGameOutcome),
        ])
        // A repeated slot keeps its first entry; an entry beyond the slots is ignored.
        Self.expectSameSummary(summaryResult(), [entry(1, .differs, .rejected, .agreement, drawSeconds: 1.25),
                                                 entry(1, .matched, .rejected, .disagreement), entry(9, .matched, .accepted, .agreement)])
        // More outcomes than Glyphs: the extra slot has no Glyph.
        Self.expectSameSummary(summaryResult(outcomes: [.accepted, .accepted, .accepted, .accepted, .rejected]), [])
        for (state, reason) in [(HackResult.State.awaiting, nil as String?), (.complete, "panelLeft"),
                                (.partial, "panelLeft"), (.notObserved, "resultTimeout"), (.notObserved, "captureStopped")] {
            Self.expectSameSummary(summaryResult(state: state, closedAt: reason == nil ? nil : 5, reason: reason ?? ""), [])
        }
        var timed = summaryResult()
        timed.firstPanelTime = 4; timed.inputStartedAt = 1; timed.inputEndedAt = 3.75
        Self.expectSameSummary(timed, [])
        timed.inputEndedAt = 200
        Self.expectSameSummary(timed, [])
        let summary = CxxHackResultSummary.make(result: summaryResult(finalHacking: nil, observedHacking: 90),
                                                comparison: [entry(1, .differs, .rejected, .agreement)])
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: JSONEncoder().encode(summary)) == summary)
        #expect(summary.runKey == "3/2" && summary.accessibilityLabel(slot: 2) == "Glyph 3, ?: the game's verdict couldn't be read")
    }

    // MARK: - ValidatorResultComparisonTests

    func event(_ kind: InputCheckEvent.Kind, slot: Int, id: Int, verdict: InputCheckVerdict = .matched,
               start: Double? = nil, lift: Double? = nil) -> InputCheckEvent {
        let result = InputCheckResult(sessionID: context.sessionID, hackID: 1, slotIndex: slot, attemptID: id,
            expectedGlyph: GlyphID(context.glyphs[slot]!), verdict: verdict, reason: nil,
            sourceTime: Double(id), startTime: start, liftTime: lift, samples: [])
        return InputCheckEvent(kind: kind, time: Double(id), hackID: 1, slotIndex: slot, attemptID: id,
                               reason: nil, result: kind == .started ? nil : result, edgeEvidence: [])
    }

    func strip(_ time: Double, _ index: Int?) -> FrameEvidence {
        FrameEvidence(sessionID: context.sessionID, time: time, header: nil,
            slots: index.map { SlotStripReading(slotCount: 4, highlightedIndex: $0, markerCentersX: [], hasInputTimerBar: true) },
            shape: .unavailable, hasValidCalibration: true, hasInputTimerBar: true)
    }

    func allAccepted() -> HackResult {
        HackResult(context: context, outcomes: [.accepted, .accepted, .accepted, .accepted], outcomeTimes: [1, 1, 1, 1])
    }

    func comparisonResults() -> [HackResult] {
        var unknown = allAccepted(); unknown.outcomes[0] = .unknown
        var rejected = allAccepted(); rejected.outcomes[1] = .rejected
        let foreign = HackResult(context: ResultReadContext(sessionID: context.sessionID, hackID: 9, glyphs: context.glyphs),
                                 outcomes: [.accepted], outcomeTimes: [nil])
        return [allAccepted(), unknown, rejected, foreign]
    }

    @Test("Final TRUTH and IDEA use attempts 3 and 4, never superseded attempts 1 and 2")
    func redo() {
        let ledger = ComparisonPair(context: context, results: comparisonResults)
        ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1, verdict: .differs),
                       event(.started, slot: 1, id: 2), event(.finished, slot: 1, id: 2)])
        for (time, index) in [(0.0, 2), (0.05, 2), (0.10, 1), (0.15, 1), (0.20, 0), (0.25, 0)] {
            ledger.observe(strip(time, index), inputVisible: true)
        }
        ledger.accept([event(.started, slot: 0, id: 3), event(.finished, slot: 0, id: 3, verdict: .unavailable),
                       event(.started, slot: 1, id: 4), event(.finished, slot: 1, id: 4)])
        #expect(ledger.swift.supersededAttemptIDs == [1, 2])
        ledger.accept([event(.finished, slot: 0, id: 1, verdict: .differs)])
        #expect(ledger.compare(allAccepted())[0].attemptID == 3)
    }

    @Test("Missing strip, a gap, and multi-slot jumps invalidate uncertain associations")
    func uncertainBoundaries() {
        for next in [strip(0.1, nil), strip(0.3, 0), strip(0.1, 2)] {
            let ledger = ComparisonPair(context: context, results: comparisonResults)
            ledger.observe(strip(0, 0), inputVisible: true); ledger.observe(strip(0.05, 0), inputVisible: true)
            ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1)])
            ledger.observe(next, inputVisible: true)
            ledger.observe(strip(next.time + 0.05, next.slots?.highlightedIndex), inputVisible: true)
            #expect(ledger.compare(allAccepted())[0].status == .unknownAssociation)
            // Hidden input, an older frame and another session change nothing.
            ledger.observe(strip(next.time + 0.1, 1), inputVisible: false)
            ledger.observe(strip(next.time, 1), inputVisible: true)
            ledger.observe(FrameEvidence(sessionID: CaptureSessionID(rawValue: 2), time: 9, header: nil, slots: nil,
                                         shape: .unavailable, hasValidCalibration: true), inputVisible: true)
        }
    }

    @Test("A real disagreement is separate from missing game or validator evidence")
    func disagreement() {
        let ledger = ComparisonPair(context: context, results: comparisonResults)
        ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1, verdict: .differs)])
        #expect(ledger.compare(allAccepted())[0].status == .disagreement)
    }

    @Test("Drawing time runs from first ink to the proven lift; unproven or implausible ends are left out")
    func drawingTime() {
        for (start, lift) in [(0.9, 1.8), (nil, 1.8), (0.9, nil), (0.9, 1.0), (0.9, 40.0)] as [(Double?, Double?)] {
            let ledger = ComparisonPair(context: context, results: comparisonResults)
            let started = InputCheckEvent(kind: .started, time: 1.0, hackID: 1, slotIndex: 0, attemptID: 1,
                                          reason: start == nil ? .missedStart : nil, result: nil, edgeEvidence: [])
            ledger.accept([started, event(.finished, slot: 0, id: 1, start: start, lift: lift)])
        }
        let ledger = ComparisonPair(context: context, results: comparisonResults)
        ledger.accept([InputCheckEvent(kind: .started, time: 1.0, hackID: 1, slotIndex: 0, attemptID: 1,
                                       reason: nil, result: nil, edgeEvidence: []),
                       event(.finished, slot: 0, id: 1, start: 0.9, lift: 1.8),
                       InputCheckEvent(kind: .started, time: 3.0, hackID: 1, slotIndex: 0, attemptID: 2,
                                       reason: .missedStart, result: nil, edgeEvidence: []),
                       event(.finished, slot: 0, id: 2, start: nil, lift: 3.5)])
        #expect(ledger.compare(allAccepted())[0].attemptID == 2 && ledger.compare(allAccepted())[0].drawSeconds == nil)
    }

    // MARK: - CommandRecognitionTests: the watch and the summary value

    @Test("Watch reset cannot re-arm when the new clock reaches the old numeric time")
    func watchReset() {
        let watch = WatchPair()
        watch.observe(at: 100, calibrated: true, commandPhase: true, complete: true)
        watch.reset()
        for time in [1.0, 99, 100, 100.25] {
            #expect(watch.observe(at: time, calibrated: false, commandPhase: true, complete: true) == .none)
        }
        watch.observe(at: 100.3, calibrated: true, commandPhase: true, complete: true)
        #expect(watch.watching)
    }

    @Test("The screen watch keeps watching through flickers and cancels on leaving")
    func screenWatch() {
        let watch = WatchPair()
        #expect(watch.observe(at: 0, calibrated: true, commandPhase: true, complete: true) == .none)
        #expect(watch.observe(at: 0.3, calibrated: false, commandPhase: true, complete: true) == .none)
        #expect(watch.observe(at: 0.4, calibrated: true, commandPhase: true, complete: true) == .none)
        #expect(watch.observe(at: 1.0, calibrated: false, commandPhase: true, complete: true) == .interrupt)
        #expect(watch.observe(at: 2.0, calibrated: false, commandPhase: true, complete: true) == .none)
        #expect(watch.observe(at: 3.1, calibrated: false, commandPhase: true, complete: true) == .cancel)
        watch.observe(at: 4, calibrated: true, commandPhase: true, complete: true)
        #expect(watch.observe(at: 4.1, calibrated: true, commandPhase: false, complete: true) == .none)
        watch.observe(at: 4.2, calibrated: true, commandPhase: true, complete: true)
        watch.stop()
        #expect(!watch.watching)
        #expect(watch.observe(at: 5, calibrated: false, commandPhase: true, complete: false) == .none)
        // Other flicker and leave values.
        var swift = CommandScreenWatch(); swift.flicker = 0.2; swift.leave = 1
        let cxx = CxxCommandScreenWatch(flicker: 0.2, leave: 1)
        for (time, calibrated) in [(0.0, true), (0.25, false), (0.3, false), (1.2, false), (1.4, false), (1.5, true)] {
            #expect(swift.observe(at: time, calibrated: calibrated, commandPhase: true, complete: true)
                        == cxx.observe(at: time, calibrated: calibrated, commandPhase: true, complete: true))
            #expect(swift.watching == cxx.watching)
        }
    }

    /// Command summaries as the command scenarios make them, and every enum
    /// case, carried through the C++ context, result and summary.
    static func commandSummaries() -> [HackCommandSummary] {
        var summaries: [HackCommandSummary] = [HackCommandSummary(), .unobserved]
        var session = CommandObservationSession()
        for (index, notice) in [CommandNoticeReading.Notice.requestKey, .complex, .noKey, .invalid, .keysOnly, .simple].enumerated() {
            let id = session.beginNotice(at: Double(index))
            session.accept(.init(notice: notice, confidence: 1, language: "en"), id: id, at: Double(index))
        }
        session.bind(hackID: 1)
        let first = session.beginNotice(at: 10)
        session.accept(.init(notice: .noKey, confidence: 1), id: first, at: 10)
        _ = session.beginNotice(at: 11)
        session.bind(hackID: 2)
        session.setMode(.drone)
        session.bind(hackID: 3)
        let read = CommandNoticeReading(notice: .simple, confidence: 0.85, language: "zh-Hans")
        let id = session.beginNotice(at: 20)
        session.accept(read, id: id, at: 20); session.accept(read, id: id, at: 20.017)
        session.setMode(.portal)
        session.bind(hackID: 4)
        summaries += (1...5).map { session.summary(hackID: $0) }
        for command in HackCommand.allCases {
            var summary = HackCommandSummary()
            var selection = HackCommandSummary.Selection()
            selection.status = .confirmed; selection.lastObserved = command; selection.samples = 3
            selection.language = command == .noKey ? "ja" : nil
            if command.isPresentation { summary.presentation = selection } else { summary.gear = selection }
            summary.gear.status = command.isPresentation ? .notApplicable : .confirmed
            summary.mode = .drone
            summaries.append(summary)
        }
        return summaries
    }

    @Test("Command summaries cross the ABI unchanged, and their effective commands agree")
    func commandSummaryValues() {
        for (index, commands) in Self.commandSummaries().enumerated() {
            let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 5), hackID: index,
                                            glyphs: ["xm", nil], commands: commands)
            let tracker = TrackerPair(context: context)
            #expect(tracker.cxx.result.context.commands == commands)
            tracker.accept(ResultFrameEvidence(context: context, sourceTime: 1, panelPresent: true, hackingBonus: 10))
            tracker.finish(at: 2, reason: "captureStopped")
            Self.expectParsersAgree([], context: context, parsers: [CxxResultTextParser()])
            #expect(CxxHackResultSummary.make(result: tracker.result, comparison: []).commands == commands)
            #expect(CxxHackResultSummary.effective(commands.presentation) == commands.presentation.effective)
            #expect(CxxHackResultSummary.effective(commands.gear) == commands.gear.effective)
            // A context differing only in its commands is another hack's.
            var other = commands; other.mode = commands.mode == .drone ? .portal : .drone
            let foreign = ResultReadContext(sessionID: context.sessionID, hackID: index, glyphs: context.glyphs,
                                            commands: other)
            tracker.accept(ResultFrameEvidence(context: foreign, sourceTime: 3, panelPresent: true))
        }
    }

    // MARK: - The parser on the oracle tests' line sets, every language

    @Test("Result page labels in every language, both arms")
    func labelLanguages() {
        let parsers = Self.allParsers()
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["xm"])
        func page(_ hacking: String, _ speed: String, confidence: Double = 1) -> [ResultTextLine] {
            [ResultTextLine(text: hacking, confidence: confidence, x: 0.3, y: 0.33, width: 0.4, height: 0.02),
             ResultTextLine(text: "120%", confidence: confidence, x: 0.4, y: 0.40, width: 0.2, height: 0.03),
             ResultTextLine(text: speed, confidence: confidence, x: 0.3, y: 0.49, width: 0.4, height: 0.02),
             ResultTextLine(text: "70%", confidence: confidence, x: 0.4, y: 0.56, width: 0.2, height: 0.03)]
        }
        var pages = [page("HACK BONUS:", "SPEED BONUS:"), page("HACKING BONUS:", "SPEED BONUS:"),
                     page("入侵奖励：", "速度奖励："), page("入侵獎勵：", "速度獎勵："), page("해킹 보너스:", "속도 보너스:"),
                     page("HACKING BONUS:", "SPEED BONUS:", confidence: 0.4), page("入侵奖励：", "速度奖励：", confidence: 0.3),
                     page("Hacking-Bonus", "speed   bonus")]
        pages.append(page("HACKING BONUS:", "SPEED BONUS:") + page("HACK BONUS:", "SPEED BONUS:"))
        pages.append(page("HACK BONUS:", "SPEED BONUS:") + page("入侵奖励：", "速度奖励："))
        for lines in pages {
            Self.expectParsersAgree(lines, context: context, appearances: [.gold], parsers: parsers)
        }
    }

    @Test("Look-alike value lines, percent forms and band edges, both arms")
    func valueLines() {
        let parsers = Self.allParsers()
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["pure"])
        func line(_ text: String, y: Double, x: Double = 0.35, width: Double = 0.3, height: Double = 0.05,
                  confidence: Double = 1) -> ResultTextLine {
            ResultTextLine(text: text, confidence: confidence, x: x, y: y, width: width, height: height)
        }
        let labels = [line("HACKING BONUS:", y: 0.31), line("SPEED BONUS:", y: 0.47)]
        let values = ["З8%", "9б%", "...", "38%", "38 %", "3 8%", "38％", "%", "0038%", "999%", "1000%",
                      "99999999999999999999%", "-5%", "+5%", "38", "38%%", "３８%", "38\u{00A0}%", "\t96%\n", "٣٨%"]
        for value in values {
            for y in [0.38, 0.54, 0.70, 0.3499, 0.3501, 0.42, 0.5799, 0.5801] {
                Self.expectParsersAgree(labels + [line(value, y: y)], context: context, parsers: parsers)
            }
        }
        // Stage names at the band's edges, left and right margins, low confidence.
        for (y, x, width) in [(0.155, 0.35, 0.3), (0.215, 0.35, 0.3), (0.19, 0.05, 0.3), (0.19, 0.06, 0.89),
                              (0.19, 0.06, 0.9)] {
            Self.expectParsersAgree(labels + [line("PURE", y: y, x: x, width: width), line("38%", y: 0.38)],
                                    context: context, appearances: [.gold], parsers: parsers)
        }
        Self.expectParsersAgree(labels + [line("pure", y: 0.19, confidence: 0.4)], context: context, parsers: parsers)
        Self.expectParsersAgree([line("HACKING BONUS:", y: 0.31, confidence: .nan), line("SPEED BONUS:", y: .nan)],
                                context: context, parsers: parsers)
    }

    // MARK: - The parser on Vision's lines from the Results fixtures

    /// `ResultScreenReader`'s OCR, as it runs it, for the lines alone.
    static func visionLines(_ image: CGImage, language: GameLanguage, scale: Double) throws -> [ResultTextLine]? {
        let rect = CGRect(x: 0.06 * Double(image.width), y: 0.18 * Double(image.height),
                          width: 0.88 * Double(image.width), height: 0.44 * Double(image.height)).integral
        guard var crop = image.cropping(to: rect) else { return nil }
        if scale != 1 {
            let width = Int(Double(crop.width) * scale), height = Int(Double(crop.height) * scale)
            guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            canvas.interpolationQuality = .high
            canvas.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let enlarged = canvas.makeImage() else { return nil }
            crop = enlarged
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = language.recognitionLanguages
        try VNImageRequestHandler(cgImage: crop).perform([request])
        return (request.results ?? []).compactMap { observation -> ResultTextLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ResultTextLine(text: best.string, confidence: Double(best.confidence),
                x: (rect.minX + box.minX * rect.width) / Double(image.width),
                y: (rect.minY + (1 - box.maxY) * rect.height) / Double(image.height),
                width: box.width * rect.width / Double(image.width),
                height: box.height * rect.height / Double(image.height))
        }
    }

    @Test("Vision's lines from the result fixtures read alike in both arms, every language")
    func visionFixtures() throws {
        let fixtures: [(String, [String?])] = [
            ("Results/five-final", ["old", "nature", "less", "strong", "now"]),
            ("Results/four-final", ["truth", "idea", "discover", "xm"]),
            ("Results/one-final", ["pure"]), ("Results/three-final", ["capture", "shapers", "portal"]),
            ("Results/labels", ["old", "nature", "less", "strong", "now"]),
            ("Phases/field-00381", ["xm"]), ("Phases/field-00443", ["xm"]), ("Phases/field-00492", ["xm"]),
            ("Phases/field-00666", ["xm"]),
        ]
        let parsers = Self.allParsers()
        var lineSets = 0, nonEmpty = 0
        for (name, glyphs) in fixtures {
            let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("\(name).png"))
            let image = try #require(ImageDecoder.cgImage(from: data))
            let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: glyphs)
            let appearances = try ResultScreenReader().appearances(in: image, count: glyphs.count)
            let scales = name.hasPrefix("Results") ? [1.0, 1.5] : [1.0]
            for language in GameLanguage.allCases {
                for scale in scales where scale == 1 || language == .english {
                    // Vision is unavailable on some runners; its lines are the
                    // input here, not what is tested.
                    guard let lines = try? Self.visionLines(image, language: language, scale: scale) else { continue }
                    lineSets += 1
                    if !lines.isEmpty { nonEmpty += 1 }
                    Self.expectParsersAgree(lines, context: context, at: 2, appearances: appearances, parsers: parsers)
                }
            }
        }
        print("results Vision line sets: \(lineSets), with text: \(nonEmpty)")
        if lineSets > 0 { #expect(nonEmpty > 0, "Vision read nothing on any fixture") }
    }

    // MARK: - CommandPhaseContextTests, through both arms

    static func nothing(at time: Double) -> HeaderReading {
        HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
    }
    static func conflicting(at time: Double) -> HeaderReading {
        HeaderReading(phase: .unknown, matchedText: "conflicting phrases", confidence: 0, sourceTime: time)
    }

    @Test("Command phase context: readable text is decided alike, Unicode whitespace included")
    func contextReadable() {
        let texts = ["", " ", " \n", "\t\r\n", "\u{00A0}", "\u{3000}", "\u{2028}", "\u{200B}", "\u{FEFF}",
                     " \u{0301}", "\u{0301}", "e\u{0301}", "conflicting phrases", "x", " x ", "\u{1680}", "\u{0085}",
                     "\r\n", "\u{202F}\u{205F}", "\u{FFFD}", "コマンド", "\u{180E}"]
        for phase in GamePhase.allCases {
            for text in texts {
                let reading = HeaderReading(phase: phase, matchedText: text, confidence: 0)
                #expect(CommandPhaseContext.isReadable(reading) == CxxCommandPhaseContext.isReadable(reading),
                        "\(phase) \(text.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
    }

    @Test("Command phase context: every oracle scenario gives the same answers")
    func contextScenarios() {
        // missingReadingsAreNotContrary
        do {
            let context = ContextPair()
            context.isCurrent(at: 0)
            context.header(.command, at: 1)
            for time in [1, 2.9, 1 + context.swift.leave, 1 + context.swift.leave + 0.05] { context.isCurrent(at: time) }
        }
        // contraryReadingEndsIt
        for phase in [GamePhase.unknown, .presenting, .input, .completed] {
            let context = ContextPair()
            context.header(.command, at: 1); context.header(phase, at: 1.3); context.isCurrent(at: 1.35)
            context.header(.command, at: 1.6); context.isCurrent(at: 1.65)
        }
        // noticeEvidence
        do {
            let context = ContextPair()
            context.header(.unknown, at: 2); context.notice(at: 2)
            context.isCurrent(at: 2); context.isCurrent(at: 3.5)
            context.header(.unknown, at: 3.6); context.isCurrent(at: 3.6)
        }
        // ordering
        do {
            let context = ContextPair()
            context.header(.command, at: 5); context.header(.command, at: 3)
            context.isCurrent(at: 6.9); context.isCurrent(at: 4)
            context.header(.command, at: .nan); context.notice(at: .infinity); context.isCurrent(at: 6)
            context.reset(); context.isCurrent(at: 6)
        }
        // noticeThenBlankReads, with and without the notice read
        for readsNotice in [true, false] {
            let context = ContextPair()
            var last: HeaderReading?
            for index in 186...241 {
                let time = Double(index) / 20
                if index == 186 {
                    last = HeaderReading(phase: .command, matchedText: "COMMAND CHANNEL", confidence: 1, sourceTime: time)
                }
                if index >= 192, index.isMultiple(of: 2) { last = Self.nothing(at: time) }
                if let last { context.header(last) }
                context.noticeRead(at: !readsNotice || index < 193 ? nil : index == 193 ? 9.5 : 9.55)
                if (190...200).contains(index) { context.notice(at: time) }
                context.isCurrent(at: time)
            }
            context.isCurrent(at: 12); context.isCurrent(at: 12.05)
        }
        // beforeNoticeRead
        do {
            let context = ContextPair()
            context.header(.command, at: 1); context.notice(at: 1.05); context.header(Self.nothing(at: 1.1))
            context.isCurrent(at: 1.1); context.noticeRead(at: nil); context.isCurrent(at: 1.15)
            context.noticeRead(at: 1.05)
            for time in [1.15, 3, 3.1] { context.isCurrent(at: time) }
        }
        // readableTextEndsIt
        for phase in [GamePhase.presenting, .input, .completed, .unknown] {
            let context = ContextPair()
            context.header(.command, at: 1); context.noticeRead(at: 1.2); context.header(Self.nothing(at: 1.3))
            context.isCurrent(at: 1.35)
            context.header(phase == .unknown ? Self.conflicting(at: 1.4)
                           : HeaderReading(phase: phase, matchedText: phase.rawValue, confidence: 1, sourceTime: 1.4))
            context.isCurrent(at: 1.4)
            context.header(Self.nothing(at: 1.5)); context.noticeRead(at: 1.2); context.isCurrent(at: 1.55)
            context.notice(at: 1.6); context.isCurrent(at: 1.6)
        }
        // readIsEvidence
        do {
            let context = ContextPair()
            context.header(Self.nothing(at: 0.5)); context.isCurrent(at: 0.5)
            context.noticeRead(at: 4)
            for step in 1...30 { context.header(Self.nothing(at: 4 + Double(step) / 20)) }
            for time in [4, 5.5, 6, 6.05] { context.isCurrent(at: time) }
            context.noticeRead(at: 3); context.isCurrent(at: 6.05); context.isCurrent(at: 3.5)
        }
        // windowEnds
        do {
            let context = ContextPair()
            context.header(.command, at: 1); context.noticeRead(at: 1.1); context.header(Self.nothing(at: 1.3))
            context.isCurrent(at: 1.3); context.noticeRead(at: nil); context.isCurrent(at: 1.35)
            context.noticeRead(at: 1.1); context.reset(); context.isCurrent(at: 1.35)
            context.notice(at: 2); context.header(Self.nothing(at: 2.1)); context.isCurrent(at: 2.1)
        }
    }

    @Test("Command phase context: seeded random walks of 5,000 calls give the same answers after every call",
          arguments: [UInt64(1), 2, 3])
    func contextRandomWalk(_ seed: UInt64) {
        var random = SeededGenerator(state: seed)
        func below(_ bound: Int) -> Int { Int(random.next() % UInt64(bound)) }
        func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
        let context = ContextPair(leave: pick([2.0, 0.5, 0, 3.25]))
        var clock = 0.0
        let texts = ["", " ", "COMMAND CHANNEL", "conflicting phrases", "\u{3000}", " \u{0301}"]
        for _ in 0..<5_000 {
            switch below(100) {
            case 0..<75: clock += Double(below(8)) * 0.05
            case 75..<85: clock -= Double(below(40)) * 0.05
            case 85..<95: break
            default: clock += Double(below(60)) * 0.1
            }
            var time = clock
            if below(100) == 0 { time = pick([.nan, .infinity, -.infinity]) }
            let source = time - Double(below(5)) * 0.05
            switch below(100) {
            case 0..<35: context.header(HeaderReading(phase: pick(GamePhase.allCases), matchedText: pick(texts),
                                                      confidence: 1, sourceTime: source))
            case 35..<50: context.header(pick(GamePhase.allCases), at: source)
            case 50..<65: context.notice(at: time)
            case 65..<80: context.noticeRead(at: pick([nil, source, source - 1, .nan]))
            case 80..<82: context.reset()
            default: break
            }
            context.isCurrent(at: time)
            context.isCurrent(at: time + Double(below(50)) * 0.05)
        }
        #expect(context.current > 500 && context.checks - context.current > 500,
                "\(context.current) of \(context.checks) current")
    }

    // MARK: - Seeded random walks

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let walkTable = GlyphTable(entries: [
        GlyphID("alpha"): GlyphPath(encoded: "038")!, GlyphID("beta"): GlyphPath(encoded: "456")!,
        GlyphID("gamma"): GlyphPath(encoded: "0123")!, GlyphID("delta"): GlyphPath(encoded: "789")!,
        GlyphID("epsilon"): GlyphPath(encoded: "5a")!,
    ])

    /// One randomized capture: hacks presented, drawn and concluded, with
    /// noise, idle frames, overlays, clock steps, stray OCR and validator
    /// events, through both sessions, schedules, watches and parsers.
    struct WalkStats {
        var comparisons = 0
        var stepsWithContext = 0
        var retired = 0
        var finalBonuses = 0
        var knownOutcomes = 0
        var linkedEntries = 0
        var superseded = 0
        var scheduled = 0
        var watchActions = 0
        var presentParses = 0
    }

    func walk(seed: UInt64, steps: Int) throws -> WalkStats {
        var stats = WalkStats()
        var random = SeededGenerator(state: seed)
        let table = Self.walkTable
        let glyphs = table.glyphs
        let recognizer = GlyphFrameRecognizer(table: table)
        let sessionID = CaptureSessionID(rawValue: 7)
        var presentation = PresentationTracker(sessionID: sessionID)
        let session = SessionPair(glyphs: glyphs)
        let schedule = SchedulePair()
        let watch = WatchPair()
        let parsers = Self.allParsers()
        var comparisons = 0
        var time = 10.0
        var watchTime = 0.0
        var attemptID = 0

        // The scripted screen: a phase, a slot count and the sequence.
        enum Stage { case command, presenting, input, result, exit }
        var stage = Stage.command
        var count = 2
        var sequence: [GlyphID] = []
        var slot = 0
        var framesLeft = 4

        func newHack() {
            count = Int.random(in: 1...4, using: &random)
            sequence = (0..<count).map { _ in glyphs.randomElement(using: &random)! }
            stage = .command; slot = 0; framesLeft = Int.random(in: 2...5, using: &random)
        }
        newHack()

        func randomCommands() -> HackCommandSummary? {
            guard Bool.random(using: &random) else { return nil }
            var summary = HackCommandSummary()
            func selection() -> HackCommandSummary.Selection {
                var value = HackCommandSummary.Selection()
                value.status = [.noCommandObserved, .confirmed, .unresolved, .notApplicable].randomElement(using: &random)!
                value.lastObserved = Bool.random(using: &random) ? HackCommand.allCases.randomElement(using: &random) : nil
                value.samples = Int.random(in: 0...3, using: &random)
                value.language = [nil, "en", "ja", "zh-Hans"].randomElement(using: &random)!
                return value
            }
            summary.presentation = selection(); summary.gear = selection()
            summary.mode = [.unknown, .portal, .drone].randomElement(using: &random)!
            return summary
        }

        func randomAppearances(_ n: Int) -> [ResultSlotAppearance] {
            let length = max(0, n + Int.random(in: -1...1, using: &random))
            let pool: [ResultSlotAppearance] = Bool.random(using: &random) ? [.gold] : [.gold, .magenta, .unreadable]
            return (0..<length).map { _ in pool.randomElement(using: &random)! }
        }

        func randomLines(_ context: ResultReadContext) -> [ResultTextLine] {
            let words = ["HACKING BONUS:", "HACK BONUS:", "SPEED BONUS:", "入侵奖励：", "速度奖励：", "入侵獎勵：",
                         "해킹 보너스", "120%", "55％", "0%", "3 8%", "З8%", "...", "1000%", "XM", "Discover"]
                + context.glyphs.compactMap { $0 }.map { $0.uppercased() }
            let ys = [0.20, 0.33, 0.40, 0.49, 0.56, 0.30, 0.37, 0.18, 0.24, 0.62, 0.445]
            func line(_ text: String, _ y: Double, x: Double = 0.2, width: Double = 0.5) -> ResultTextLine {
                ResultTextLine(text: text, confidence: [0.2, 0.3, 0.5, 0.9, 1, 1].randomElement(using: &random)!,
                               x: x, y: y - 0.01, width: width, height: 0.02)
            }
            var lines: [ResultTextLine] = []
            // Most pages are laid out as the game lays them out, in a random
            // pack's labels, so the parse gets past the labels.
            if Double.random(in: 0..<1, using: &random) < 0.7 {
                let labels = [("HACKING BONUS:", "SPEED BONUS:"), ("HACK BONUS:", "SPEED BONUS:"),
                              ("入侵奖励：", "速度奖励："), ("入侵獎勵：", "速度獎勵："), ("해킹 보너스:", "속도 보너스:")]
                    .randomElement(using: &random)!
                let values = ["120%", "55％", "0%", "3 8%", "З8%", "...", "1000%", "90 %", "", "86%"]
                lines.append(line(labels.0, [0.31, 0.33, 0.36, 0.38].randomElement(using: &random)!))
                lines.append(line(labels.1, [0.47, 0.49, 0.52, 0.54].randomElement(using: &random)!))
                for y in [0.40, 0.41, 0.56, 0.57] where Bool.random(using: &random) {
                    lines.append(line(values.randomElement(using: &random)!, y))
                }
                if Bool.random(using: &random) {
                    let name = context.glyphs.compactMap { $0 }.randomElement(using: &random) ?? "XM"
                    lines.append(line(Bool.random(using: &random) ? name.uppercased() : name, 0.21))
                }
            }
            for _ in 0..<Int.random(in: 0...3, using: &random) {
                lines.append(line(words.randomElement(using: &random)!, ys.randomElement(using: &random)!,
                                  x: [0.05, 0.2, 0.35].randomElement(using: &random)!,
                                  width: [0.3, 0.6, 0.75].randomElement(using: &random)!))
            }
            lines.shuffle(using: &random)
            return lines
        }

        for step in 0..<steps {
            // Mostly forward at 20 Hz, sometimes a gap, rarely the clock steps back.
            let roll = Double.random(in: 0..<1, using: &random)
            time += roll < 0.01 ? -Double.random(in: 0...3, using: &random)
                : roll < 0.08 ? Double.random(in: 0.1...1.5, using: &random) : 0.05

            // The scripted frame for the current stage.
            var header: HeaderReading?
            var slots: SlotStripReading?
            var rejection: SlotStripRejection?
            var shape = ShapeEvidence.unavailable
            var calibrated = false
            var timer = false
            var panelCandidate = false
            switch stage {
            case .command:
                header = HeaderReading(phase: .command, matchedText: "", confidence: 1, sourceTime: time)
                calibrated = true
            case .presenting:
                header = HeaderReading(phase: .presenting, matchedText: "", confidence: 1, sourceTime: time)
                slots = SlotStripReading(slotCount: count, highlightedIndex: slot, markerCentersX: [], hasInputTimerBar: false)
                if let edges = recognizer.expectedEdges(for: sequence[slot]) {
                    shape = ShapeEvidence(kind: .uniqueVisibleShape, glyph: sequence[slot], edges: edges, extensions: [])
                }
                calibrated = true
            case .input:
                header = HeaderReading(phase: .input, matchedText: "GO!", confidence: 1,
                                       sourceTime: time - [0, 0, 0.5, 1].randomElement(using: &random)!)
                timer = Double.random(in: 0..<1, using: &random) < 0.8
                slots = SlotStripReading(slotCount: count, highlightedIndex: slot, markerCentersX: [], hasInputTimerBar: timer)
                calibrated = Bool.random(using: &random)
            case .result:
                rejection = [nil, .noMarkers, .coveredByOverlay].randomElement(using: &random)!
                panelCandidate = Double.random(in: 0..<1, using: &random) < 0.85
            case .exit:
                rejection = .noMarkers
            }
            // Noise on top: unread headers, lost strips, stray highlights.
            if Double.random(in: 0..<1, using: &random) < 0.1 { header = nil }
            if Double.random(in: 0..<1, using: &random) < 0.05 {
                header = HeaderReading(phase: GamePhase.allCases.randomElement(using: &random)!, matchedText: "",
                                       confidence: 1, sourceTime: time - Double.random(in: -0.1...1, using: &random))
            }
            if Double.random(in: 0..<1, using: &random) < 0.08 {
                slots = nil
                rejection = [.noMarkers, .coveredByOverlay, .bandUnavailable, .unevenSpacing].randomElement(using: &random)!
            }
            if Double.random(in: 0..<1, using: &random) < 0.04 {
                slots = SlotStripReading(slotCount: Int.random(in: 1...5, using: &random),
                                         highlightedIndex: Bool.random(using: &random) ? Int.random(in: 0...4, using: &random) : nil,
                                         markerCentersX: [], hasInputTimerBar: Bool.random(using: &random))
            }
            if Double.random(in: 0..<1, using: &random) < 0.05 { panelCandidate.toggle() }
            let evidence = FrameEvidence(sessionID: sessionID, time: time, header: header, slots: slots,
                                         slotRejection: slots == nil ? rejection : nil, shape: shape,
                                         hasValidCalibration: calibrated, hasInputTimerBar: timer)
            let imageAnalyzed = Double.random(in: 0..<1, using: &random) < 0.9
            presentation.accept(evidence)
            let tracker = session.cxx.tracker
            let before = session.swift.tracker
            if session.observe(evidence, presentation: presentation, panelCandidate: panelCandidate,
                               imageAnalyzed: imageAnalyzed, commands: randomCommands()) != nil {
                stats.retired += 1
            }
            if session.context != nil { stats.stepsWithContext += 1 }
            if let result = session.result {
                if result.finalHackingBonus != nil || result.finalSpeedBonus != nil { stats.finalBonuses += 1 }
                if result.outcomes.contains(where: { $0 != .unknown }) { stats.knownOutcomes += 1 }
                if let entries = session.swift.comparison?.compare(result) {
                    stats.linkedEntries += entries.filter { $0.attemptID != nil }.count
                }
            }
            if session.swift.comparison?.supersededAttemptIDs.isEmpty == false { stats.superseded += 1 }
            // A value taken before the call keeps its value after it.
            if let before, let tracker {
                Self.expectSame(before.result, tracker.result, "snapshot")
                #expect(before.revision == tracker.revision)
            }
            comparisons += 1

            // OCR results for the current hack, an older one, or garbage.
            if Double.random(in: 0..<1, using: &random) < 0.5 {
                let base = session.context
                    ?? ResultReadContext(sessionID: sessionID, hackID: presentation.hackID, glyphs: sequence.map(\.name))
                let context = Double.random(in: 0..<1, using: &random) < 0.1
                    ? ResultReadContext(sessionID: base.sessionID, hackID: base.hackID + 1, glyphs: base.glyphs)
                    : base
                let n = context.glyphs.count
                let sourceTime: Double = Double.random(in: 0..<1, using: &random) < 0.02
                    ? [Double.nan, .infinity, -.infinity].randomElement(using: &random)!
                    : time - [0, 0, 0.05, 0.3].randomElement(using: &random)!
                let read = ResultFrameEvidence(
                    context: context, sourceTime: sourceTime,
                    panelPresent: Double.random(in: 0..<1, using: &random) < 0.8,
                    stageIndex: [nil, n - 1, n - 1, Int.random(in: -1...n, using: &random)].randomElement(using: &random)!,
                    hackingBonus: [nil, 90, 120, 120].randomElement(using: &random)!,
                    speedBonus: [nil, 0, 55, 55].randomElement(using: &random)!,
                    appearances: randomAppearances(n),
                    labelLanguage: [nil, .english, .japanese].randomElement(using: &random)!)
                session.accept(read)
                if schedule.select(read, decision: Double.random(in: 0..<1, using: &random) < 0.2) != nil {
                    stats.scheduled += 1
                }
                comparisons += 2
            }
            // Validator events, mostly for the current hack.
            if Double.random(in: 0..<1, using: &random) < 0.3 {
                let n = max(1, session.context?.glyphs.count ?? count)
                let events = (0..<Int.random(in: 1...3, using: &random)).map { _ -> InputCheckEvent in
                    let slotIndex = Int.random(in: -1...n, using: &random)
                    if Double.random(in: 0..<1, using: &random) < 0.4 { attemptID += 1 }
                    let id = max(1, attemptID - Int.random(in: 0...1, using: &random))
                    let kind: InputCheckEvent.Kind = [.started, .started, .finished, .verdict, .unchecked, .lifted]
                        .randomElement(using: &random)!
                    let expected = session.context?.glyphs[safe: slotIndex] ?? nil
                    let glyph = Double.random(in: 0..<1, using: &random) < 0.85 ? (expected ?? "alpha") : "beta"
                    let start: Double? = Bool.random(using: &random) ? time - 1 : nil
                    let lift: Double? = [nil, time - 0.5, time + 40, time - 2].randomElement(using: &random)!
                    let result = kind == .started ? nil : InputCheckResult(
                        sessionID: Double.random(in: 0..<1, using: &random) < 0.95 ? sessionID : CaptureSessionID(rawValue: 8),
                        hackID: presentation.hackID, slotIndex: slotIndex, attemptID: id, expectedGlyph: GlyphID(glyph),
                        verdict: [.matched, .differs, .unavailable].randomElement(using: &random)!, reason: nil,
                        sourceTime: time, startTime: start, liftTime: lift, samples: [])
                    return InputCheckEvent(kind: kind, time: time - 1.2,
                                           hackID: Double.random(in: 0..<1, using: &random) < 0.9
                                               ? presentation.hackID : presentation.hackID + 1,
                                           slotIndex: slotIndex, attemptID: id,
                                           reason: Double.random(in: 0..<1, using: &random) < 0.2 ? .missedStart : nil,
                                           result: result, edgeEvidence: [])
                }
                session.accept(events)
                comparisons += 1
            }
            if Double.random(in: 0..<1, using: &random) < 0.005 {
                session.finish(at: time, reason: ["captureStopped", "endOfStream", ""].randomElement(using: &random)!)
                comparisons += 1
            }
            if Double.random(in: 0..<1, using: &random) < 0.002 {
                session.swift = ResultObservationSession(); session.cxx.reset()
                session.check()
                comparisons += 1
            }

            // The command watch on its own clock, with stops and resets.
            watchTime += [0.05, 0.05, 0.3, 0.7, 2.5, -1].randomElement(using: &random)!
            if watch.observe(at: watchTime, calibrated: Double.random(in: 0..<1, using: &random) < 0.6,
                             commandPhase: Double.random(in: 0..<1, using: &random) < 0.7,
                             complete: Double.random(in: 0..<1, using: &random) < 0.8) != .none {
                stats.watchActions += 1
            }
            if Double.random(in: 0..<1, using: &random) < 0.03 { watch.stop() }
            if Double.random(in: 0..<1, using: &random) < 0.01 { watch.reset() }
            comparisons += 1

            // Random page text through a random language's parsers.
            if Double.random(in: 0..<1, using: &random) < 0.3 {
                let context = session.context
                    ?? ResultReadContext(sessionID: sessionID, hackID: step, glyphs: sequence.map(\.name))
                let parser = parsers.randomElement(using: &random)!
                let lines = randomLines(context)
                Self.expectParsersAgree(lines, context: context, at: time,
                                        appearances: randomAppearances(context.glyphs.count), parsers: [parser])
                if ResultTextParser(language: parser.language).read(lines: lines, context: context, at: time).panelPresent {
                    stats.presentParses += 1
                }
                comparisons += 1
            }

            // Advance the script.
            framesLeft -= 1
            if framesLeft <= 0 {
                framesLeft = Int.random(in: 3...6, using: &random)
                switch stage {
                case .command: stage = .presenting; slot = 0
                case .presenting:
                    if slot + 1 < count { slot += 1 } else { stage = .input; slot = 0 }
                case .input:
                    if slot + 1 < count, Double.random(in: 0..<1, using: &random) < 0.9 { slot += 1 }
                    else { stage = .result; framesLeft = Int.random(in: 4...30, using: &random) }
                case .result: stage = .exit
                case .exit: newHack()
                }
            }
        }
        stats.comparisons = comparisons + session.comparisons
        return stats
    }

    @Test("Seeded random walks: 2,000 steps per seed, compared after every step", arguments: [1, 2, 3] as [UInt64])
    func randomWalk(seed: UInt64) throws {
        let stats = try walk(seed: seed &* 0x5DEE_CE66D, steps: 2_000)
        print("results walk seed \(seed): \(stats)")
        // The walk must reach what it is meant to compare.
        #expect(stats.comparisons > 2_000)
        #expect(stats.stepsWithContext > 200 && stats.retired > 5 && stats.finalBonuses > 20)
        #expect(stats.knownOutcomes > 20 && stats.linkedEntries > 20 && stats.superseded > 20)
        #expect(stats.scheduled > 20 && stats.watchActions > 20 && stats.presentParses > 5)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
