import Foundation
import GlyphRecognition
import Testing

@Suite("Island progress ring")
struct IslandProgressTests {
    private typealias Slot = GlyphActivityContentState.Slot

    private func slot(_ provenance: Slot.Provenance, _ name: String? = nil) -> Slot {
        // Any drawable walk will do; the ring never inspects the shape itself.
        Slot(provenance: provenance, name: name, shape: name == nil ? nil : "03")
    }

    private func state(_ slots: [Slot], phase: TrackingState = .presenting, upcoming: [Slot] = [],
                       inputSlot: Int? = nil, covered: Bool = false,
                       provisional: Bool = false) -> GlyphActivityContentState {
        GlyphActivityContentState(slots: slots, phase: phase.rawValue, statusLine: "", predictionState: "ambiguous",
                                  candidateCount: 2, expectedSlotCount: slots.isEmpty ? nil : slots.count,
                                  upcoming: upcoming, inputSlotNumber: inputSlot,
                                  indicatorsObstructed: covered, hackID: 1, revision: 1,
                                  isProvisional: provisional)
    }

    @Test("The animation choice reaches the extension and counts as a change worth sending")
    func animationChoice() throws {
        var animated = state([slot(.observed, "help")])
        animated.animatesUpdates = true
        let still = state([slot(.observed, "help")])
        #expect(!still.animatesUpdates, "off unless the player turns it on")
        #expect(animated.semanticKey != still.semanticKey)
        let decoded = try JSONDecoder().decode(GlyphActivityContentState.self,
                                               from: JSONEncoder().encode(animated))
        #expect(decoded.animatesUpdates)
    }

    @Test("Before the game shows a slot count there is no ring, only the waiting icon")
    func waiting() {
        let idle = IslandProgress(state([], phase: .inactive))
        #expect(idle.marks.isEmpty)
        #expect(idle.current == nil)
        #expect(idle.centre == .waiting(provisional: false))
        #expect(IslandProgress(state([], provisional: true)).centre == .waiting(provisional: true))
    }

    @Test("During the presentation the ring fills slot by slot around the Glyph on screen")
    func collecting() {
        let seeing = IslandProgress(state([slot(.observed, "see"), slot(.observing, "truth"),
                                           slot(.pending), slot(.pending)]))
        #expect(seeing.marks == [.held, .seeing, .ahead, .ahead])
        #expect(seeing.current == 1)
        #expect(seeing.centre == .slot(1))

        // Between two Glyphs the array is clear: the one just collected stays.
        let between = IslandProgress(state([slot(.observed, "see"), slot(.observed, "truth"),
                                            slot(.pending), slot(.pending)]))
        #expect(between.current == nil)
        #expect(between.centre == .slot(1))
    }

    @Test("A slot that closed without a legible Glyph shows as lost, and a guess is not held")
    func lostSlots() {
        let progress = IslandProgress(state([slot(.missing), slot(.observed, "see"),
                                             slot(.uncertain, "truth"), slot(.predicted, "future")]))
        #expect(progress.marks == [.lost, .held, .lost, .predicted])
    }

    @Test("During input the ring marks the slot being drawn and the centre is the Glyph to draw")
    func drawing() {
        let slots = [slot(.observed, "see"), slot(.observed, "truth"), slot(.observed, "see"), slot(.observed, "begin")]
        let progress = IslandProgress(state(slots, phase: .input, upcoming: [slots[2], slots[3]], inputSlot: 3))
        #expect(progress.current == 2)
        #expect(progress.centre == .next)
        // A slot number the row does not have emphasises nothing.
        #expect(IslandProgress(state(slots, phase: .input, upcoming: [slots[0]], inputSlot: 9)).current == nil)
    }

    @Test("Without guidance during input the centre never shows a collected Glyph as if it were next")
    func noGuidanceDuringInput() {
        let slots = [slot(.observed, "see"), slot(.observed, "truth")]
        #expect(IslandProgress(state(slots, phase: .input)).centre == .waiting(provisional: false))
        #expect(IslandProgress(state(slots, phase: .interrupted)).centre == .waiting(provisional: false))
    }

    @Test("Covered indicators are said in the centre, but never displace the Glyph to draw")
    func covered() {
        let slots = [slot(.observed, "see"), slot(.pending)]
        let hidden = IslandProgress(state(slots, covered: true))
        #expect(hidden.centre == .covered)
        #expect(hidden.marks == [.held, .ahead])
        #expect(IslandProgress(state(slots, phase: .input, upcoming: [slots[0]], inputSlot: 1,
                                     covered: true)).centre == .next)
    }

    @Test("A collected slot with nothing to draw leaves the waiting icon, not an empty centre")
    func undrawable() {
        let progress = IslandProgress(state([Slot(provenance: .observed, name: "see", shape: nil), slot(.pending)]))
        #expect(progress.centre == .waiting(provisional: false))
    }

    @Test("Covering the indicators, or a new status colour, is a change worth an Island update")
    func coveredChangesTheKey() {
        let slots = [slot(.observed, "see"), slot(.pending)]
        #expect(state(slots).semanticKey != state(slots, covered: true).semanticKey)
        var drawing = state(slots)
        drawing.statusTone = StatusTone.drawing.rawValue
        #expect(state(slots).semanticKey != drawing.semanticKey)
    }
}
