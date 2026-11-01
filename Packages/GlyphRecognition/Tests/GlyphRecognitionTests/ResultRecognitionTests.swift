import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Conclusion evidence")
struct ResultRecognitionTests {
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
        var tracker = HackResultTracker(context: context)
        for i in 0..<6 { tracker.accept(frame(Double(i) * 0.1, stage: 2, hacking: 90)) }
        #expect(tracker.result.finalHackingBonus == nil)
        for i in 0..<5 { tracker.accept(frame(1 + Double(i) * 0.1)) }
        #expect(tracker.result.finalHackingBonus == 120)
        #expect(tracker.result.finalSpeedBonus == 55)
        #expect(tracker.result.state == .complete)
        tracker.observeFrame(at: 1.5, inputVisible: false, exitVisible: false, panelCandidate: false)
        tracker.observeFrame(at: 1.8, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(tracker.result.closeReason == "panelLeft")
        #expect(tracker.result.finalHackingBonus == 120)
    }

    @Test("Input time runs from the first to the last input frame before the result, only once it appears")
    func inputTime() throws {
        var tracker = HackResultTracker(context: context)
        for i in 0...30 {
            tracker.observeFrame(at: 1 + Double(i) * 0.1, inputVisible: true, exitVisible: false, panelCandidate: false)
        }
        #expect(tracker.result.inputSeconds == nil, "No result yet: the hack may be abandoned")
        tracker.accept(frame(4.3))
        tracker.observeFrame(at: 4.4, inputVisible: true, exitVisible: false, panelCandidate: true)
        let seconds = try #require(tracker.result.inputSeconds)
        #expect(abs(seconds - 3) < 1e-9, "Frames after the result don't extend it")
        let summary = HackResultSummary(result: tracker.result, comparison: [])
        #expect(summary.inputSeconds == tracker.result.inputSeconds)
        let old = #"{"captureSessionID":1,"hackID":1,"state":"complete","isClosed":true,"slots":[]}"#
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: Data(old.utf8)).inputSeconds == nil)
    }

    @Test("One- and two-frame value lag cannot confirm the previous bonus", arguments: [1, 2])
    func delayedValue(frames: Int) {
        var tracker = HackResultTracker(context: context)
        for i in 0..<9 {
            tracker.accept(frame(Double(i) * 0.05, hacking: i < frames ? 90 : 120))
            #expect(tracker.result.finalHackingBonus != 90)
        }
        #expect(tracker.result.finalHackingBonus == 120)
    }

    @Test("A rejected last slot need not light up or increase either bonus")
    func wrongLast() {
        var tracker = HackResultTracker(context: context)
        for i in 0..<5 {
            tracker.accept(frame(Double(i) * 0.1, hacking: 90, speed: 0,
                                 appearances: [.gold, .gold, .gold, .unreadable]))
        }
        #expect(tracker.result.finalHackingBonus == 90)
        #expect(tracker.result.finalSpeedBonus == 0)
        #expect(tracker.result.outcomes.last == .unknown)
        #expect(tracker.result.state == .partial)
    }

    @Test("A lit last contour stands in for an unread name; an earlier name contradicts it")
    func contourRevealsFinalStage() {
        let lit: [ResultSlotAppearance] = [.gold, .gold, .gold, .gold]
        var tracker = HackResultTracker(context: context)
        tracker.accept(frame(0.0, stage: nil, appearances: lit))
        tracker.accept(frame(0.15, stage: nil, appearances: lit))
        #expect(tracker.result.finalHackingBonus == 120 && tracker.result.finalStageTime == 0.0)
        var magenta = HackResultTracker(context: context)
        magenta.accept(frame(0.0, stage: nil, hacking: 90, appearances: [.gold, .gold, .gold, .magenta]))
        magenta.accept(frame(0.15, stage: nil, hacking: 90, appearances: [.gold, .gold, .gold, .magenta]))
        #expect(magenta.result.finalHackingBonus == 90)
        var contradicted = HackResultTracker(context: context)
        contradicted.accept(frame(0.0, stage: 2, appearances: lit))
        contradicted.accept(frame(0.15, stage: 2, appearances: lit))
        #expect(contradicted.result.finalHackingBonus == nil)
        // Repeated names cannot place the stage, but the contour still can.
        let repeated = ResultReadContext(sessionID: context.sessionID, hackID: 1, glyphs: ["mind", "open", "mind"])
        var repeatedTracker = HackResultTracker(context: repeated)
        for time in [0.0, 0.15] {
            repeatedTracker.accept(ResultFrameEvidence(context: repeated, sourceTime: time, panelPresent: true,
                stageIndex: nil, hackingBonus: 90, speedBonus: 20, appearances: [.gold, .gold, .gold]))
        }
        #expect(repeatedTracker.result.finalHackingBonus == 90)
    }

    @Test("Chinese result OCR's fullwidth percent sign confirms the final speed bonus",
          arguments: [("54％", 54), ("90％", 90)])
    func fullwidthPercent(_ sample: (String, Int)) {
        let context = ResultReadContext(sessionID: .init(rawValue: 1), hackID: 12,
                                        glyphs: ["gain", "future", "escape"])
        func line(_ text: String, _ y: Double) -> ResultTextLine {
            .init(text: text, confidence: 0.5, x: 0.35, y: y, width: 0.3, height: 0.02)
        }
        let lines = [line("ESCAPE", 0.20), line("入侵奖励：", 0.32), line("86%", 0.40),
                     line("速度奖励：", 0.48), line(sample.0, 0.56)]
        let parser = ResultTextParser(language: .simplifiedChinese)
        var tracker = HackResultTracker(context: context)
        for time in [458.427, 458.527] {
            tracker.accept(parser.read(lines: lines, context: context, at: time,
                                        appearances: [.gold, .gold, .gold]))
        }
        #expect(tracker.result.finalSpeedBonus == sample.1)
    }

    @Test("Covered stage keeps stable percentages provisional")
    func coveredStage() {
        var tracker = HackResultTracker(context: context)
        let covered = Array(repeating: ResultSlotAppearance.unreadable, count: 4)
        for i in 0..<10 { tracker.accept(frame(Double(i) * 0.1, stage: nil, appearances: covered)) }
        tracker.finish(at: 1, reason: "panelLeft")
        #expect(tracker.result.state == .partial)
        #expect(tracker.result.observedHackingBonus == 120)
        #expect(tracker.result.finalHackingBonus == nil)
    }

    @Test("Duplicate, late, and foreign readings do not vote")
    func identities() {
        var tracker = HackResultTracker(context: context)
        tracker.accept(frame(1))
        for _ in 0..<5 { tracker.accept(frame(1)) }
        tracker.accept(frame(0.9))
        tracker.accept(frame(1.1, context: ResultReadContext(sessionID: context.sessionID, hackID: 2, glyphs: context.glyphs)))
        #expect(tracker.result.outcomes.allSatisfy { $0 == .unknown })
        #expect(tracker.result.finalStageTime == nil)
        tracker.finish(at: 1.2, reason: "newHack")
        tracker.accept(frame(1.3))
        #expect(tracker.result.lastPanelTime == 1)
    }

    @Test("Frame gaps, single colours, and contradictory colours stay unknown")
    func colourUncertainty() {
        var tracker = HackResultTracker(context: context)
        tracker.accept(frame(0)); tracker.accept(frame(0.4))
        #expect(tracker.result.outcomes.first == .unknown)
        tracker.accept(frame(0.5))
        #expect(tracker.result.outcomes.first == .accepted)
        for i in 6..<12 { tracker.accept(frame(Double(i) * 0.1, appearances: [.magenta])) }
        #expect(tracker.result.outcomes.first == .unknown)
    }

    @Test("Early Done and stop before a panel preserve unknown fields")
    func noConclusion() {
        var tracker = HackResultTracker(context: context)
        tracker.observeFrame(at: 0, inputVisible: true, exitVisible: false, panelCandidate: false)
        tracker.observeFrame(at: 1, inputVisible: false, exitVisible: true, panelCandidate: false)
        tracker.observeFrame(at: 5.9, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(tracker.result.state == .awaiting)
        tracker.observeFrame(at: 6.1, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(tracker.result.state == .notObserved)
        #expect(tracker.result.closeReason == "resultTimeout")
        #expect(tracker.result.finalSpeedBonus == nil)
        var stopped = HackResultTracker(context: context)
        stopped.finish(at: 0.1, reason: "captureStopped")
        #expect(stopped.result.state == .notObserved)
    }

    @Test("Hidden input evidence without an observed exit never times out a hack")
    func hiddenInputKeepsHackOpen() {
        var tracker = HackResultTracker(context: context)
        tracker.observeFrame(at: 0, inputVisible: true, exitVisible: false, panelCandidate: false)
        for i in 1...200 {
            tracker.observeFrame(at: Double(i) * 0.05, inputVisible: false, exitVisible: false, panelCandidate: false)
        }
        #expect(tracker.result.state == .awaiting)
        for i in 0..<3 { tracker.accept(frame(10.1 + Double(i) * 0.1)) }
        #expect(tracker.result.finalHackingBonus == 120)
        // Renewed input evidence restarts the wait from the next exit.
        var resumed = HackResultTracker(context: context)
        resumed.observeFrame(at: 0, inputVisible: false, exitVisible: true, panelCandidate: false)
        resumed.observeFrame(at: 4, inputVisible: true, exitVisible: false, panelCandidate: false)
        resumed.observeFrame(at: 5.5, inputVisible: false, exitVisible: true, panelCandidate: false)
        resumed.observeFrame(at: 10, inputVisible: false, exitVisible: false, panelCandidate: false)
        #expect(resumed.result.state == .awaiting)
    }

    /// A session whose presentation tracker has reached input for a two-slot hack.
    func inputSession() -> (ResultObservationSession, PresentationTracker, Double) {
        let session = CaptureSessionID(rawValue: 1)
        let table = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!,
                                         GlyphID("beta"): GlyphPath(encoded: "456")!])
        var presentation = PresentationTracker(sessionID: session)
        var results = ResultObservationSession()
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
                _ = results.observe(evidence, presentation: presentation, panelCandidate: false)
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
        let setup = inputSession()
        var results = setup.0
        let presentation = setup.1
        var time = setup.2
        let context = try #require(results.context)
        #expect(context.glyphs == ["alpha", "beta"])
        results.accept(ResultFrameEvidence(context: context, sourceTime: time + 0.05, panelPresent: true))
        for i in 1...10 {
            _ = results.observe(blank(time + 0.05 + Double(i) * 0.05), presentation: presentation,
                                panelCandidate: false, imageAnalyzed: false)
        }
        #expect(results.tracker?.result.closedAt == nil)
        time += 0.6
        for i in 1...8 {
            _ = results.observe(blank(time + Double(i) * 0.05), presentation: presentation, panelCandidate: false)
        }
        #expect(results.tracker?.result.closeReason == "panelLeft")
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
            let setup = inputSession()
            var results = setup.0
            let presentation = setup.1
            var time = setup.2
            let hackID = presentation.hackID
            results.accept([InputCheckEvent(kind: .started, time: time, hackID: hackID, slotIndex: 0, attemptID: 1,
                                            reason: nil, result: nil, edgeEvidence: [])])
            for timer in [true, true, false, false, true, true] {
                time += 0.05
                _ = results.observe(strip(time, index: dropStrip && !timer ? nil : 0, timer: timer),
                                    presentation: presentation, panelCandidate: false)
            }
            return results.comparison?.supersededAttemptIDs ?? []
        }
        #expect(run(dropStrip: false).isEmpty)
        #expect(run(dropStrip: true) == [1])
    }

    @Test("An empty strip starts the wait; a covered strip does not")
    func exitEvidence() {
        let setup = inputSession()
        var covered = setup.0
        let presentation = setup.1, start = setup.2
        for i in 1...140 {
            _ = covered.observe(blank(start + Double(i) * 0.05, rejection: .coveredByOverlay),
                                presentation: presentation, panelCandidate: false)
        }
        #expect(covered.tracker?.result.closedAt == nil)
        var exited = setup.0
        for i in 1...110 {
            _ = exited.observe(blank(start + Double(i) * 0.05, rejection: .noMarkers),
                               presentation: presentation, panelCandidate: false)
        }
        #expect(exited.tracker?.result.closeReason == "resultTimeout")
        #expect(exited.tracker?.result.state == .notObserved)
    }

    @Test("A fully covered strip and timer do not retire the hack before its real conclusion")
    func coveredPixelsKeepResultWindow() throws {
        let setup = inputSession()
        var results = setup.0
        var presentation = setup.1
        let context = try #require(results.context)
        let reader = SlotStripReader()
        let band = FrameTopBand(image: try ColorImage(width: 603, height: 323,
            pixels: Array(repeating: 180, count: 603 * 323 * 3)), frameHeight: 1311)
        let rejection: SlotStripRejection
        switch reader.read(band) {
        case .failure(let reason): rejection = reason
        case .success: Issue.record("An opaque banner must not produce slot evidence"); return
        }
        #expect(rejection == .coveredByOverlay)
        #expect(!reader.hasTimerBar(band))
        for i in 1...140 {
            let time = setup.2 + Double(i) * 0.05
            let evidence = FrameEvidence(sessionID: context.sessionID, time: time, header: nil,
                slots: nil, slotRejection: rejection, shape: .unavailable, hasValidCalibration: false,
                hasInputTimerBar: reader.hasTimerBar(band))
            presentation.accept(evidence)
            _ = results.observe(evidence, presentation: presentation, panelCandidate: false)
        }
        #expect(results.context == context)
        for i in 0..<3 {
            results.accept(ResultFrameEvidence(context: context, sourceTime: setup.2 + 7.1 + Double(i) * 0.1,
                panelPresent: true, stageIndex: 1, hackingBonus: 60, speedBonus: 10, appearances: [.gold, .gold]))
        }
        #expect(results.tracker?.result.state == .complete)
        #expect(results.tracker?.result.finalHackingBonus == 60)
    }

    @Test("A current input header contradicts empty-strip exit evidence; an old one expires")
    func inputHeaderKeepsResultWindow() throws {
        let setup = inputSession()
        var results = setup.0
        var presentation = setup.1
        let context = try #require(results.context)
        let empty = FrameTopBand(image: try ColorImage(width: 603, height: 323,
            pixels: Array(repeating: 0, count: 603 * 323 * 3)), frameHeight: 1311)
        #expect(SlotStripReader().read(empty) == .failure(.noMarkers))
        let lastHeaderTime = setup.2 + 7
        for i in 1...280 {
            let time = setup.2 + Double(i) * 0.05
            let header = HeaderReading(phase: .input, matchedText: "GO!", confidence: 1,
                                       sourceTime: min(time, lastHeaderTime))
            let evidence = FrameEvidence(sessionID: context.sessionID, time: time, header: header,
                slots: nil, slotRejection: .noMarkers, shape: .unavailable, hasValidCalibration: false)
            presentation.accept(evidence)
            _ = results.observe(evidence, presentation: presentation, panelCandidate: false)
            if i <= 140 { #expect(results.context == context) }
        }
        #expect(results.tracker?.result.closeReason == "resultTimeout")
    }

    @Test("Two agreeing final-stage reads 0.2 s apart finalize within a 0.4-s stage")
    func sparseFinalReads() {
        var tracker = HackResultTracker(context: context)
        tracker.accept(frame(0.0, stage: 2, hacking: 90))
        tracker.accept(frame(0.2, stage: 2, hacking: 90))
        tracker.accept(frame(0.4))
        #expect(tracker.result.finalHackingBonus == nil)
        tracker.accept(frame(0.6))
        #expect(tracker.result.finalHackingBonus == 120 && tracker.result.finalSpeedBonus == 55)
        #expect(tracker.result.finalStageTime == 0.4)
        // A differing later read reopens the field instead of keeping either value.
        tracker.accept(frame(0.8, hacking: 130))
        #expect(tracker.result.finalHackingBonus == nil)
    }

    func line(_ text: String, y: Double) -> ResultTextLine {
        ResultTextLine(text: text, confidence: 0.9, x: 0.2, y: y, width: 0.5, height: 0.02)
    }

    @Test("Both labels and field positions are required; zero and over 100 are valid")
    func parser() {
        let labels = [line("HACKING BONUS:", y: 0.33), line("SPEED BONUS:", y: 0.49)]
        let lines = labels + [line("XM", y: 0.20), line("120%", y: 0.4), line("0%", y: 0.56)]
        let parsed = ResultTextParser().read(lines: lines, context: context, at: 1)
        #expect(parsed.panelPresent && parsed.stageIndex == 3)
        #expect(parsed.hackingBonus == 120 && parsed.speedBonus == 0)
        let missing = ResultTextParser().read(lines: Array(lines.dropFirst()), context: context, at: 1)
        #expect(!missing.panelPresent && missing.hackingBonus == nil)
        let conflict = ResultTextParser().read(lines: lines + [line("90%", y: 0.4)], context: context, at: 1)
        #expect(conflict.hackingBonus == nil)
        let repeated = ResultReadContext(sessionID: context.sessionID, hackID: 1, glyphs: ["xm", "xm"])
        #expect(ResultTextParser().read(lines: lines, context: repeated, at: 1).stageIndex == nil)
        let absent = ResultTextParser().read(lines: labels, context: context, at: 1)
        #expect(absent.hackingBonus == nil && absent.speedBonus == nil)
    }

    @Test("One global request; rejected geometry gets one probe, header cadence is unchanged")
    func scheduler() throws {
        var schedule = GameTextSchedule()
        let firstValue = schedule.take(at: 0, panelCandidate: false, resultEligible: true)
        let first = try #require(firstValue)
        #expect(first.mode == .header)
        #expect(schedule.take(at: 0.2, panelCandidate: true, resultEligible: true) == nil)
        schedule.finish(first)
        let probeValue = schedule.take(at: 0.2, panelCandidate: true, resultEligible: true)
        let probe = try #require(probeValue)
        #expect(probe.mode == .result)
        schedule.finish(probe, panelPresent: false)
        let headerValue = schedule.take(at: 0.31, panelCandidate: true, resultEligible: true)
        let header = try #require(headerValue)
        #expect(header.mode == .header)
        schedule.finish(first) // stale completion cannot release the newer request
        #expect(schedule.inFlight == header)
        schedule.finish(header)
        #expect(schedule.take(at: 0.409, panelCandidate: false, resultEligible: true) == nil)
        let againValue = schedule.take(at: 0.5, panelCandidate: true, resultEligible: true)
        let again = try #require(againValue)
        #expect(again.mode == .result)
    }

    @Test("A confirmed panel keeps the lane through failed reads, then yields to the header")
    func confirmedPanelMisses() throws {
        var schedule = GameTextSchedule()
        var time = 0.0
        func next(_ present: Bool) throws -> GameTextSchedule.Mode {
            let taken = schedule.take(at: time, panelCandidate: true, resultEligible: true)
            let request = try #require(taken)
            schedule.finish(request, panelPresent: present)
            time += 0.11
            return request.mode
        }
        #expect(try next(true) == .result)
        #expect(try next(false) == .result)
        #expect(try next(false) == .result)
        #expect(try next(true) == .result)
        for _ in 0..<3 { #expect(try next(false) == .result) }
        #expect(try next(false) == .header)
        #expect(try next(false) == .header)
    }

    @Test("Header-only schedule matches the previous 100-ms submission rule")
    func headerCadence() {
        var schedule = GameTextSchedule()
        var previous = -Double.infinity
        for i in 0..<200 {
            let time = Double(i) * 0.0499
            let expected = time < previous || time - previous >= 0.1
            let request = schedule.take(at: time, panelCandidate: false, resultEligible: false)
            #expect((request != nil) == expected)
            if let request { previous = time; schedule.finish(request) }
        }
    }

    @Test("Evidence budget starts with numbers and reserves final decisions")
    func evidenceBudget() {
        var schedule = ResultEvidenceSchedule()
        #expect(schedule.select(frame(0, stage: nil, hacking: nil, speed: nil), decision: false) == .detection)
        #expect(schedule.select(frame(1, stage: nil, hacking: nil, speed: nil), decision: false) == nil)
        #expect(schedule.select(frame(2), decision: false) == .animation)
        #expect(schedule.select(frame(4.4), decision: false) == .animation)
        #expect(schedule.select(frame(4.6), decision: false) == .budgetExhausted)
        #expect(schedule.select(frame(4.7), decision: false) == nil)
        #expect(schedule.select(frame(5), decision: true) == .decision)
    }
}
