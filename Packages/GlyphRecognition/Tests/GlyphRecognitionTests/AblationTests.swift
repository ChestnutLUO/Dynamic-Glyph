import Foundation
import Testing
import GlyphRecognitionImages
@testable import GlyphRecognition
@testable import GlyphReplay

@Suite("Replay ablations")
struct AblationTests {
    @Test("Ablation lists parse by name, and an unknown name is refused")
    func parsing() throws {
        #expect(try Ablation.parse("") == [])
        #expect(try Ablation.parse("header,ink-check,header") == [.header, .inkCheck])
        #expect(throws: ReplayError.self) { try Ablation.parse("header,bogus") }
    }

    @Test("Hiding the timer also clears the bar the strip reader saw, and nothing else")
    func timerReachesTheStrip() {
        let reading = SlotStripReading(slotCount: 4, highlightedIndex: 2, markerCentersX: [0.2, 0.4, 0.6, 0.8],
                                       hasInputTimerBar: true, isPartlyCovered: true)
        #expect(Ablation.reading(reading, under: [.header]) == reading)
        let hidden = Ablation.reading(reading, under: [.timer])
        #expect(!hidden.hasInputTimerBar)
        #expect(hidden.slotCount == 4 && hidden.highlightedIndex == 2 && hidden.isPartlyCovered)
        #expect(hidden.markerCentersX == reading.markerCentersX)
        let evidence = FrameEvidence(sessionID: CaptureSessionID(rawValue: 1), time: 0, header: nil,
                                     slots: hidden, shape: .unavailable, hasValidCalibration: true,
                                     hasInputTimerBar: false)
        #expect(!evidence.hasInputTimerBar)
    }

    @Test("Tracker ablations change only their own policy values")
    func policies() {
        #expect(Ablation.policy(for: []) == PresentationTracker.Policy())
        #expect(Ablation.policy(for: [.header, .strip, .inkCheck]) == PresentationTracker.Policy())
        let stability = Ablation.policy(for: [.stability])
        #expect(stability.minimumStableSamples == 1)
        #expect(stability.minimumStableInterval == 0)
        #expect(stability.slotCountVotesRequired == PresentationTracker.Policy().slotCountVotesRequired)
        #expect(Ablation.policy(for: [.slotVotes]).slotCountVotesRequired == 1)
        #expect(!Ablation.policy(for: [.indicatorPhase]).entersPresentationFromIndicators)
        #expect(!Ablation.policy(for: [.lastSlotRelease]).closesLastSlotOnRelease)
    }
}

@Suite("Replay shape ablations", .enabled(if: ReferenceData.shapesAvailable))
struct ShapeAblationTests {
    private func recording(_ milliseconds: Int) throws -> LuminanceImage {
        try ImageDecoder.load(ReferenceData.fixturesDirectory
            .appendingPathComponent("Recording/sample-\(milliseconds).png"))
    }

    private func observations() throws -> (see: GlyphFrameObservation, trail: GlyphFrameObservation) {
        let fit = try #require(NodeArrayDetector().detect(in: recording(25150)))
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        return (recognizer.observe(try recording(25500), calibration: fit),
                recognizer.observe(try recording(23600), calibration: fit))
    }

    @Test("With no shape ablation the evidence is exactly the live pipeline's")
    func identity() throws {
        let (see, trail) = try observations()
        for ablations: Set<Ablation> in [[], [.header, .strip, .stability]] {
            let ablator = ShapeAblator(ablations: ablations)
            #expect(ablator.evidence(for: see) == ShapeEvidence(see))
            #expect(ablator.evidence(for: trail) == ShapeEvidence(trail))
        }
    }

    @Test("Without the ink check a cluttered geometric match is accepted, and clean shapes are unchanged")
    func inkCheck() throws {
        let (see, trail) = try observations()
        let ablator = ShapeAblator(ablations: [.inkCheck])
        #expect(trail.state == .unexplainedInk)
        try #require(trail.exactMatches.count == 1)
        let accepted = ablator.evidence(for: trail)
        #expect(accepted.kind == .uniqueVisibleShape)
        #expect(accepted.glyph == trail.exactMatches.first)
        #expect(accepted.edges == trail.edges)
        #expect(ablator.evidence(for: see) == ShapeEvidence(see))
    }
}
