import Foundation
import Testing
@testable import GlyphRecognition

/// Build 103: stopping a read for a new panel never costs a drop its group.
/// In the 2026-10-27 report replay, hack 1's portal panel showed for about
/// 0.3 s and its only read was stopped when the Bonus panel slid in: build
/// 102 recorded that portal panel with no rows (one read can't confirm a
/// row), build 103 doesn't record it, and the hack keeps its one group with
/// its Bonus rows. A read is stopped only while no group is open or its panel
/// is settled (`previousPanelUnconfirmed`), so it is never a read a confirmed
/// row needed. Timelines as `GearNewPanelLaneTests` (injected reads, no Vision).
@Suite("Build 103: a stopped read never costs a drop its group")
struct GearNewPanelGroupTests {
    typealias Sim = GearLaneSimulation

    static let starts: [(phase: Int, headerAt: Double?)] = [0, 1].flatMap { phase in
        [nil, 0.3, 0.25, 0.2, 0.15].map { (phase, $0) }
    }

    /// As 2026-10-27 hack 1: a 0.3-s portal panel, then its Bonus panel in place.
    static let shortPortal = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 0.3, height: 0.1309)
        + Sim.panel(.bonus, from: 0.6, seconds: 0.7, height: 0.1667) + Sim.nothing(from: 1.3, seconds: 0.5)

    @Test("A short portal panel whose only read is stopped: still one group, every panel 102 keeps kept",
          arguments: [false, true], [0.25, 0.35])
    func shortPortalKeepsGroup(constrained: Bool, cost: Double) {
        var stopped = 0
        for (index, start) in Self.starts.enumerated() {
            let old = Sim.run(Self.shortPortal, lane103: false, phase: start.phase, headerAt: start.headerAt,
                              constrained: constrained) { _ in cost }
            let new = Sim.run(Self.shortPortal, lane103: true, cancelLatency: 0.05, phase: start.phase,
                              headerAt: start.headerAt, constrained: constrained) { _ in cost }
            #expect(old.groups.count == 1 && new.groups.count == 1, "start \(index): \(old.groups.count) → \(new.groups.count)")
            for stage in [GearDropStage.portal, .bonus] where Sim.kept(old, stage) {
                #expect(Sim.kept(new, stage), "start \(index), \(stage)")
            }
            #expect(Sim.wrongItems(new) == 0)
            if !new.cancels.isEmpty {
                stopped += 1
                // The read stopped was the portal panel's only one: 102 confirmed no row of it.
                let portal = old.groups.flatMap(\.panels).filter { $0.stage == .portal }
                #expect(portal.allSatisfy { $0.entries.isEmpty && $0.partial }, "start \(index)")
                #expect(Sim.kept(new, .bonus), "start \(index)")
            }
        }
        #expect(stopped > 0, "the stop must actually happen in this timeline")
    }

    @Test("A real drop whose panels show no rows still counts as one group, with or without a Bonus panel",
          arguments: [false, true], [0.025, 0.25, 0.35, 0.55])
    func emptyDropCounts(constrained: Bool, cost: Double) {
        let portalOnly = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 1.0, height: 0.1309)
            + Sim.nothing(from: 1.3, seconds: 0.5)
        let both = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 0.6, height: 0.1309)
            + Sim.panel(.bonus, from: 0.9, seconds: 0.7, height: 0.1309) + Sim.nothing(from: 1.6, seconds: 0.5)
        for frames in [portalOnly, both] {
            for (index, start) in Self.starts.enumerated() {
                let runs = [false, true].map { lane103 in
                    Sim.run(frames, lane103: lane103, cancelLatency: 0.05, phase: start.phase, headerAt: start.headerAt,
                            constrained: constrained, rows: { _ in [] }) { _ in cost }
                }
                #expect(runs[0].groups.count == 1 && runs[1].groups.count == 1,
                        "start \(index): 102 \(runs[0].groups.count), 103 \(runs[1].groups.count) groups")
                #expect(runs[1].groups.flatMap(\.panels).allSatisfy { $0.entries.isEmpty })
            }
        }
    }
}
