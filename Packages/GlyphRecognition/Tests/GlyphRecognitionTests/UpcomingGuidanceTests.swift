import Testing
@testable import GlyphRecognition

/// "Draw this now" is the strongest claim any surface in this app makes, and
/// the compact Dynamic Island has no room to qualify it. These check the cases
/// where it must not be made at all.
@Suite("Upcoming guidance")
struct UpcomingGuidanceTests {
    private func snapshot(state: TrackingState = .input,
                          slots: [SlotObservation],
                          expected: Int? = nil,
                          inputSlotIndex: Int? = 0,
                          inputSlotObservedTime: Double? = 100,
                          sourceFrameTime: Double = 100,
                          indicatorsObstructed: Bool = false,
                          slotCountConflict: Bool = false,
                          liveness: CaptureLiveness = .live,
                          acceptance: AcceptanceMode = .trackingSequence,
                          outlook: SequenceOutlook = .unavailable) -> GlyphDisplaySnapshot {
        GlyphDisplaySnapshot(
            captureSessionID: CaptureSessionID(rawValue: 1), hackID: 1, revision: 1,
            liveness: liveness, state: state, phaseSource: .headerText, acceptance: acceptance,
            sourceFrameTime: sourceFrameTime, evidenceArrivalUptime: 10,
            expectedSlotCount: expected ?? slots.count, slots: slots, currentSlotIndex: nil,
            inputSlotIndex: inputSlotIndex, inputSlotObservedTime: inputSlotObservedTime,
            indicatorsObstructed: indicatorsObstructed, slotCountConflict: slotCountConflict,
            isFrozen: true, provisionalGlyph: nil, provisionalExtensionCount: 0,
            outlook: outlook, calibrationSummary: "11 rings")
    }

    private func confirmed(_ names: String...) -> [SlotObservation] {
        names.enumerated().map {
            SlotObservation(index: $0.offset, status: .confirmed, glyph: GlyphID($0.element))
        }
    }

    @Test("The Glyph to draw now and the one after it come from the highlighted indicator")
    func window() throws {
        let model = snapshot(slots: confirmed("change", "perspective", "begin", "new"),
                             inputSlotIndex: 1)
        let guidance = try #require(model.upcomingGuidance())
        #expect(guidance.firstSlotIndex == 1)
        #expect(guidance.styles.compactMap(\.glyph).map(\.name) == ["perspective", "begin"])
        #expect(guidance.styles.allSatisfy { !$0.isDashed })
    }

    @Test("There is no next Glyph when the indicator cannot be read")
    func indicatorUnread() {
        let slots = confirmed("change", "perspective")
        #expect(snapshot(slots: slots, inputSlotIndex: nil).upcomingGuidance() == nil)
    }

    @Test("Guidance exists only while the player is drawing")
    func onlyDuringInput() {
        let slots = confirmed("change", "perspective")
        for state: TrackingState in [.presenting, .command, .completed, .interrupted, .inactive] {
            #expect(snapshot(state: state, slots: slots).upcomingGuidance() == nil,
                    Comment(rawValue: state.rawValue))
        }
    }

    @Test("An indicator read too long ago is not guidance")
    func staleIndicator() {
        let slots = confirmed("change", "perspective")
        #expect(snapshot(slots: slots, inputSlotObservedTime: 99.5, sourceFrameTime: 100)
            .upcomingGuidance() != nil)
        #expect(snapshot(slots: slots, inputSlotObservedTime: 99.0, sourceFrameTime: 100)
            .upcomingGuidance() == nil)
    }

    @Test("Covered indicators withdraw the instruction rather than dimming it")
    func obstructed() {
        let slots = confirmed("change", "perspective")
        #expect(snapshot(slots: slots, indicatorsObstructed: true).upcomingGuidance() == nil)
    }

    @Test("A provisional display does not tell the player what to draw")
    func provisional() {
        let slots = confirmed("change", "perspective")
        #expect(snapshot(slots: slots, acceptance: .provisionalOnly(reason: "capture not started"))
            .upcomingGuidance() == nil)
    }

    @Test("A slot count that changed mid-hack, a stopped capture and an impossible index all refuse")
    func otherRefusals() {
        let slots = confirmed("change", "perspective")
        #expect(snapshot(slots: slots, slotCountConflict: true).upcomingGuidance() == nil)
        #expect(snapshot(slots: slots, liveness: .stopped).upcomingGuidance() == nil)
        #expect(snapshot(slots: slots, inputSlotIndex: 7).upcomingGuidance() == nil)
    }

    @Test("The last slot has nothing after it")
    func lastSlot() {
        let model = snapshot(slots: confirmed("change", "perspective"), inputSlotIndex: 1)
        #expect(model.upcomingGuidance()?.styles.count == 1)
    }

    @Test("A predicted continuation is offered, and drawn as a prediction", .enabled(if: ReferenceData.sequencesAvailable))
    func predicted() throws {
        let predictor = SequencePredictor(table: try ReferenceData.sequenceTable())
        let observed = [GlyphID("change"), GlyphID("perspective")]
        let model = snapshot(
            slots: confirmed("change", "perspective") + [SlotObservation(index: 2), SlotObservation(index: 3)],
            expected: 4, inputSlotIndex: 2,
            outlook: predictor.outlook(observed: observed, expectedLength: 4))
        let guidance = try #require(model.upcomingGuidance())
        #expect(guidance.styles.compactMap(\.glyph).map(\.name) == ["begin", "new"])
        #expect(guidance.styles.allSatisfy { $0.isDashed }, "predictions must not look observed")
    }

    @Test("A window with nothing nameable is refused, but a lost slot beside a known one is kept")
    func nothingSayable() throws {
        let blank = snapshot(slots: [SlotObservation(index: 0), SlotObservation(index: 1)],
                             inputSlotIndex: 0)
        #expect(blank.upcomingGuidance() == nil)

        let partial = snapshot(slots: [SlotObservation(index: 0, status: .missing),
                                       SlotObservation(index: 1, status: .confirmed,
                                                       glyph: GlyphID("new"))],
                               inputSlotIndex: 0)
        let guidance = try #require(partial.upcomingGuidance())
        #expect(guidance.styles.count == 2)
        #expect(guidance.styles.first == .missing)
    }

    @Test("Guidance is a window into the same styles every other surface draws")
    func agreesWithTiles() throws {
        let model = snapshot(slots: confirmed("change", "perspective", "begin"), inputSlotIndex: 1)
        let guidance = try #require(model.upcomingGuidance())
        #expect(guidance.styles == Array(model.tileStyles[1..<3]))
    }
}
