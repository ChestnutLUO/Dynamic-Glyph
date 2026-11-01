import Testing
@testable import GlyphRecognition

@Suite("Result to validator attempt association")
struct ValidatorResultComparisonTests {
    let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                    glyphs: ["truth", "idea", "discover", "xm"])
    func event(_ kind: InputCheckEvent.Kind, slot: Int, id: Int, verdict: InputCheckVerdict = .matched,
               start: Double? = nil, lift: Double? = nil) -> InputCheckEvent {
        let result = InputCheckResult(sessionID: context.sessionID, hackID: 1, slotIndex: slot, attemptID: id,
            expectedGlyph: GlyphID(context.glyphs[slot]!), verdict: verdict, reason: nil,
            sourceTime: Double(id), startTime: start, liftTime: lift, samples: [])
        return InputCheckEvent(kind: kind, time: Double(id), hackID: 1, slotIndex: slot, attemptID: id,
                               reason: nil, result: kind == .started ? nil : result, edgeEvidence: [])
    }
    func frame(_ time: Double, _ index: Int?) -> FrameEvidence {
        FrameEvidence(sessionID: context.sessionID, time: time, header: nil,
            slots: index.map { SlotStripReading(slotCount: 4, highlightedIndex: $0,
                                               markerCentersX: [], hasInputTimerBar: true) },
            shape: .unavailable, hasValidCalibration: true, hasInputTimerBar: true)
    }
    func result() -> HackResult {
        HackResult(context: context, outcomes: [.accepted, .accepted, .accepted, .accepted],
                   outcomeTimes: [1, 1, 1, 1])
    }

    @Test("Final TRUTH and IDEA use attempts 3 and 4, never superseded attempts 1 and 2")
    func redo() {
        var ledger = ValidatorResultComparison(context: context)
        ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1, verdict: .differs),
                       event(.started, slot: 1, id: 2), event(.finished, slot: 1, id: 2)])
        ledger.observe(frame(0, 2), inputVisible: true); ledger.observe(frame(0.05, 2), inputVisible: true)
        ledger.observe(frame(0.10, 1), inputVisible: true); ledger.observe(frame(0.15, 1), inputVisible: true)
        ledger.observe(frame(0.20, 0), inputVisible: true); ledger.observe(frame(0.25, 0), inputVisible: true)
        #expect(ledger.compare(result())[0].status == .unknownAssociation)
        ledger.accept([event(.started, slot: 0, id: 3), event(.finished, slot: 0, id: 3, verdict: .unavailable),
                       event(.started, slot: 1, id: 4), event(.finished, slot: 1, id: 4)])
        let entries = ledger.compare(result())
        #expect(entries[0].attemptID == 3 && entries[0].status == .coverageGap)
        #expect(entries[1].attemptID == 4 && entries[1].status == .agreement)
        #expect(ledger.supersededAttemptIDs == [1, 2])
        ledger.accept([event(.finished, slot: 0, id: 1, verdict: .differs)])
        #expect(ledger.compare(result())[0].attemptID == 3)
    }

    @Test("Missing strip, a gap, and multi-slot jumps invalidate uncertain associations")
    func uncertainBoundaries() {
        for next in [frame(0.1, nil), frame(0.3, 0), frame(0.1, 2)] {
            var ledger = ValidatorResultComparison(context: context)
            ledger.observe(frame(0, 0), inputVisible: true); ledger.observe(frame(0.05, 0), inputVisible: true)
            ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1)])
            ledger.observe(next, inputVisible: true)
            ledger.observe(frame(next.time + 0.05, next.slots?.highlightedIndex), inputVisible: true)
            #expect(ledger.compare(result())[0].status == .unknownAssociation)
        }
    }

    @Test("A real disagreement is separate from missing game or validator evidence")
    func disagreement() {
        var ledger = ValidatorResultComparison(context: context)
        ledger.accept([event(.started, slot: 0, id: 1), event(.finished, slot: 0, id: 1, verdict: .differs)])
        #expect(ledger.compare(result())[0].status == .disagreement)
        var unknown = result(); unknown.outcomes[0] = .unknown
        #expect(ledger.compare(unknown)[0].status == .unknownGameOutcome)
    }

    @Test("Drawing time runs from first ink to the proven lift; unproven or implausible ends are left out")
    func drawingTime() {
        // The started event carries first ink; the check's start is the clear frame before it.
        for (start, lift, expected) in [(0.9, 1.8, 0.8 as Double?), (nil, 1.8, nil), (0.9, nil, nil),
                                        (0.9, 1.0, nil), (0.9, 40.0, nil)] {
            var ledger = ValidatorResultComparison(context: context)
            let started = InputCheckEvent(kind: .started, time: 1.0, hackID: 1, slotIndex: 0, attemptID: 1,
                                          reason: start == nil ? .missedStart : nil, result: nil, edgeEvidence: [])
            ledger.accept([started, event(.finished, slot: 0, id: 1, start: start, lift: lift)])
            let seconds = ledger.compare(result())[0].drawSeconds
            #expect(seconds.map { abs($0 - (expected ?? -1)) < 1e-9 } ?? (expected == nil))
            let slot = HackResultSummary(result: result(), comparison: ledger.compare(result())).slots[0]
            #expect(slot.drawSeconds == seconds)
        }
        // A superseded attempt's time never stands in for the judged one.
        var ledger = ValidatorResultComparison(context: context)
        ledger.accept([InputCheckEvent(kind: .started, time: 1.0, hackID: 1, slotIndex: 0, attemptID: 1,
                                       reason: nil, result: nil, edgeEvidence: []),
                       event(.finished, slot: 0, id: 1, start: 0.9, lift: 1.8),
                       InputCheckEvent(kind: .started, time: 3.0, hackID: 1, slotIndex: 0, attemptID: 2,
                                       reason: .missedStart, result: nil, edgeEvidence: []),
                       event(.finished, slot: 0, id: 2, start: nil, lift: 3.5)])
        #expect(ledger.compare(result())[0].attemptID == 2 && ledger.compare(result())[0].drawSeconds == nil)
    }
}
