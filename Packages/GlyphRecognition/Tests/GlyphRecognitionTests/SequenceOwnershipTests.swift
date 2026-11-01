import Testing
@testable import GlyphRecognition

/// Two ways a displayed sequence can stop belonging to the hack in front of
/// the player. Both were real: the tracker inherited the previous hack's Glyphs
/// when a presentation was missed, and a header reading several frames old kept
/// it collecting presentation evidence after the player had started drawing.
@Suite("Sequence ownership", .enabled(if: ReferenceData.shapesAvailable))
struct SequenceOwnershipTests {
    private func table() throws -> GlyphTable { try ReferenceData.glyphTable() }

    private func edges(_ table: GlyphTable, _ name: String) -> ShapeEvidence {
        guard let path = table.path(for: GlyphID(name)) else { return .unavailable }
        return ShapeEvidence(kind: .uniqueVisibleShape, glyph: GlyphID(name),
                             edges: GlyphGeometry.normalizedEdges(path.undirectedEdges),
                             extensions: [])
    }

    private func reading(_ count: Int, _ highlight: Int?, bar: Bool = false) -> SlotStripReading {
        SlotStripReading(slotCount: count, highlightedIndex: highlight,
                         markerCentersX: (0..<count).map { (Double($0) + 0.5) / Double(count) },
                         hasInputTimerBar: bar)
    }

    /// CLAIM D2: after a completed hack, if the next hack's presentation is
    /// never observed, the previous hack's Glyphs must not survive into the new
    /// hack's input phase.
    @Test("A new hack whose presentation was missed does not inherit the old sequence")
    func missedPresentationDoesNotInherit() throws {
        let table = try table()
        let session = CaptureSessionID(rawValue: 1)
        var tracker = PresentationTracker(sessionID: session)
        var time = 100.0
        func step(_ phase: GamePhase?, slots: SlotStripReading?, glyph: String? = nil) {
            time += 0.05
            tracker.accept(FrameEvidence(
                sessionID: session, time: time,
                header: phase.map { HeaderReading(phase: $0, matchedText: $0.rawValue,
                                                  confidence: 0.9, sourceTime: time) },
                slots: slots, shape: glyph.map { edges(table, $0) } ?? ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
                hasValidCalibration: true))
        }

        // Hack 1, fully observed.
        step(.command, slots: nil)
        for _ in 0..<6 { step(.presenting, slots: reading(2, 0), glyph: "change") }
        for _ in 0..<6 { step(.presenting, slots: reading(2, 1), glyph: "perspective") }
        for _ in 0..<3 { step(.input, slots: reading(2, 0, bar: true)) }
        for _ in 0..<3 { step(.completed, slots: nil) }
        let firstHack = tracker.slots.compactMap(\.glyph).map(\.name)
        #expect(firstHack == ["change", "perspective"])

        // Hack 2 begins. Its presentation is never legible -- header unreadable
        // throughout -- and the next thing we recognise is player input.
        for _ in 0..<3 { step(.command, slots: nil) }
        for _ in 0..<3 { step(.input, slots: reading(4, 0, bar: true)) }

        // The old sequence must not be presented as this hack's.
        let inherited = tracker.slots.compactMap(\.glyph).map(\.name)
        #expect(inherited.isEmpty, "inherited \(inherited) from the previous hack")
    }

    /// CLAIM D3: the countdown bar is current-frame evidence; a header reading
    /// up to 350 ms old must not keep the tracker in the presentation phase.
    @Test("The countdown bar beats a stale presentation header")
    func timerBarBeatsStaleHeader() throws {
        let table = try table()
        let session = CaptureSessionID(rawValue: 1)
        var tracker = PresentationTracker(sessionID: session)
        var time = 100.0
        func step(_ phase: GamePhase?, headerAge: Double = 0, slots: SlotStripReading?, glyph: String? = nil) {
            time += 0.05
            tracker.accept(FrameEvidence(
                sessionID: session, time: time,
                header: phase.map { HeaderReading(phase: $0, matchedText: $0.rawValue,
                                                  confidence: 0.9, sourceTime: time - headerAge) },
                slots: slots, shape: glyph.map { edges(table, $0) } ?? ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
                hasValidCalibration: true))
        }
        step(.command, slots: nil)
        for _ in 0..<6 { step(.presenting, slots: reading(2, 0), glyph: "change") }
        // Input has begun: the bar is on this frame. The header analysis is
        // 300 ms behind and still says "Incoming glyph sequence".
        for _ in 0..<6 {
            step(.presenting, headerAge: 0.3, slots: reading(2, 0, bar: true), glyph: "future")
        }
        #expect(tracker.state == .input, "state is \(tracker.state); player strokes are still being collected")
    }
}
