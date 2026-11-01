import Testing
@testable import GlyphRecognition

@Suite("Floating gear status")
struct GearDropDisplayTests {
    func group(hackID: Int? = 1, partial: Bool = false) -> GearDropSummary {
        let entry = GearDropEntry(column: 0, row: 0, item: "Hypercube", levelState: .notApplicable, level: nil, quantity: 2)
        return GearDropSummary(groupID: 1, startedAt: 2, closedAt: 4, closeReason: "panelLeft", hackID: hackID,
            association: hackID == nil ? .uncertainContinuity : .ordered,
            panels: [.init(stage: .portal, entries: [entry], partial: partial),
                     .init(stage: .bonus, entries: [entry], partial: false)])
    }

    func snapshot(_ gear: GearDropDisplay?, state: TrackingState = .completed,
                  liveness: CaptureLiveness = .live) -> GlyphDisplaySnapshot {
        GlyphDisplaySnapshot(captureSessionID: .init(rawValue: 1), hackID: 2, revision: 1,
            liveness: liveness, state: state, phaseSource: .headerText, acceptance: .trackingSequence,
            sourceFrameTime: 10, evidenceArrivalUptime: 10, expectedSlotCount: nil, slots: [],
            currentSlotIndex: nil, inputSlotIndex: nil, slotCountConflict: false, isFrozen: false,
            provisionalGlyph: nil, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "", gear: gear, gearRevision: gear == nil ? 0 : 3)
    }

    @Test("Queued hacks wait, read, retain a completion through coalescing, and resume waiting")
    func lifecycle() {
        var queue = GearDropObservationSession()
        var display = GearDropDisplayTracker()
        display.update(waiting: [], reading: false, associationUncertain: false, at: 0)
        #expect(display.display == nil && display.revision == 0)
        queue.enqueue(hackID: 1, at: 0); queue.enqueue(hackID: 2, at: 1)
        display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 1)
        #expect(display.display?.state == .waiting && display.display?.waitingCount == 2)
        #expect(display.display?.hackID == 1)
        let revision = display.revision
        display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 1.1)
        #expect(display.revision == revision)
        display.update(waiting: queue.waiting, reading: true, associationUncertain: false, at: 2)
        #expect(display.display?.state == .reading)
        display.finished(queue.close(group()))
        for time in [4.0, 4.05, 4.4, 5, 7.9] {
            display.update(waiting: queue.waiting, reading: true, associationUncertain: false, at: time)
            #expect(display.display?.state == .read && display.display?.itemCount == 4)
        }
        display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 8)
        #expect(display.display?.state == .waiting && display.display?.hackID == 2)
        display.ended(hackID: 2, at: 9)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 9)
        #expect(display.display?.state == .notRead)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 13)
        #expect(display.display == nil)
    }

    @Test("Partial and unattached groups never become a complete reading")
    func uncertainty() {
        var display = GearDropDisplayTracker()
        display.finished(group(partial: true))
        display.update(waiting: [], reading: false, associationUncertain: false, at: 4)
        #expect(display.display?.state == .partial)
        display.finished(group(hackID: nil))
        display.ended(hackID: 1, at: 4)
        display.update(waiting: [], reading: false, associationUncertain: true, at: 4)
        #expect(display.display?.state == .unattached && display.display?.hackID == nil)
    }

    @Test("Active Glyph guidance, stopped capture, stale evidence and disabled gear keep precedence")
    func priorityAndFreshness() {
        let gear = GearDropDisplay(state: .waiting, hackID: 1, waitingCount: 2)
        for state: TrackingState in [.command, .presenting, .input] {
            #expect(snapshot(gear, state: state).visibleGear(atUptime: 10) == nil)
        }
        for liveness: CaptureLiveness in [.starting, .interrupted, .stopped] {
            #expect(snapshot(gear, liveness: liveness).visibleGear(atUptime: 10) == nil)
        }
        #expect(snapshot(nil).visibleGear(atUptime: 10) == nil)
        let showing = snapshot(gear)
        #expect(showing.visibleGear(atUptime: 10) == gear)
        #expect(showing.visibleGear(atUptime: 12) == nil)
        #expect(showing.revision != snapshot(nil).revision)
        #expect(showing.statusLine(atUptime: 10).contains("Earlier hack"))
        #expect(gear.compactValue == "2")
    }

    @Test("Gear-only capture watches between drops and counts what it read")
    func standalone() {
        var display = GearDropDisplayTracker(standalone: true)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 0)
        #expect(display.display == GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
        #expect(display.display?.message(currentHackID: 0) == "Watching for gear")
        let entry = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: 3)
        let portalOnly = GearDropSummary(groupID: 1, startedAt: 2, closedAt: 4, closeReason: "panelLeft", hackID: nil,
            association: .noWaitingHack, panels: [.init(stage: .portal, entries: [entry], partial: false)])
        display.finished(portalOnly)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 4)
        #expect(display.display?.state == .read && display.display?.itemCount == 3, "No Bonus panel is expected")
        display.update(waiting: [], reading: false, associationUncertain: false, at: 8.5)
        #expect(display.display == GearDropDisplay(state: .watching, hackID: nil, itemCount: 3))
        #expect(display.display?.message(currentHackID: 0).contains("3 items") == true)
        #expect(display.display?.tone == .idle)
        let partial = GearDropSummary(groupID: 2, startedAt: 8, closedAt: 9, closeReason: "panelLeft", hackID: nil,
            association: .noWaitingHack, panels: [.init(stage: .portal, entries: [entry], partial: true)])
        display.finished(partial)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 9)
        #expect(display.display?.state == .partial)
        display.update(waiting: [], reading: false, associationUncertain: false, at: 13.5)
        #expect(display.display?.itemCount == 6, "Partly read items still count")
    }
}
