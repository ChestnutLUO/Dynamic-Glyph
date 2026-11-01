import Foundation
import Testing
@testable import GlyphRecognition

/// The single OCR lane over a whole drop, as the app runs it when
/// constrained, with injected reads (no Vision): analysis on a 20-fps
/// recording's frames, every 0.099 s outside a hack (build 103: every 0.049 s
/// while the last analysed frame showed a panel); each analysed frame first
/// takes a finished read, then asks the schedule for the next (the new-panel
/// check first, in build 103), then lets the tracker see the geometry, as
/// `LiveGlyphOutput` does. A read holds the lane for its cost and is taken on
/// the first analysed frame after it finishes; a stopped read frees the lane
/// `cancelLatency` after the frame that stopped it (or when it would have
/// finished) and delivers nothing. Headers every second, 0.1 s each, as the
/// 2026-10-28 harness. Panels slide in as that session's did: top 0.3155,
/// 0.3097, 0.3026, 0.2883 on their first four frames, then 0.2847.
///
/// Build 102 is the same lane without the new-panel check and with 0.099-s
/// analysis throughout.
struct GearLaneSimulation {
    enum Shows: String, Sendable { case portal, untitled, bonus }
    struct Frame: Sendable {
        let time: Double
        let bounds: GearDropPanelBounds?
        let shows: Shows?
    }
    struct Outcome {
        var groups: [GearDropSummary] = []
        var reads: [(time: Double, shows: Shows)] = []
        var cancels: [(source: Double, at: Double)] = []
        var analysedFrames = 0
        var headerReads = 0
        /// Requests running at once, at most.
        var mostInFlight = 0
    }

    static let slide = [0.3155, 0.3097, 0.3026, 0.2883]
    static let settledTop = 0.2847

    /// `seconds` of a panel `height` tall, from `start`, at 20 fps.
    static func panel(_ shows: Shows, from start: Double, seconds: Double, height: Double) -> [Frame] {
        (0..<Int((seconds * 20).rounded())).map { index in
            let top = index < slide.count ? slide[index] : settledTop
            return Frame(time: start + Double(index) / 20, bounds: GearDropPanelBounds(top: top, bottom: top + height),
                         shows: shows)
        }
    }

    static func nothing(from start: Double, seconds: Double) -> [Frame] {
        (0..<Int((seconds * 20).rounded())).map { Frame(time: start + Double($0) / 20, bounds: nil, shows: nil) }
    }

    static let portalRows = [entry(0, 0, "Resonator", level: 6, 1), entry(1, 0, "Turret", level: 6, 1)]
    static let bonusRows = [entry(0, 0, "Power Cube", level: 8, 1), entry(1, 0, "Resonator", level: 8, 2),
                            entry(0, 1, "XMP Burster", level: 8, 1)]

    static func entry(_ column: Int, _ row: Int, _ item: String, level: Int, _ quantity: Int) -> GearDropEntry {
        GearDropEntry(column: column, row: row, item: item, levelState: .known, level: level, quantity: quantity)
    }

    /// `phase` skips that many first frames; `headerAt` is a header read in
    /// flight from that time when the window opens. `rows` replaces the rows
    /// a portal or Bonus read finds (`portalRows`, `bonusRows`).
    static func run(_ frames: [Frame], lane103: Bool, cancelLatency: Double = 0, phase: Int = 0,
                    headerAt: Double? = nil, constrained: Bool = true,
                    rows: ((Shows) -> [GearDropEntry])? = nil,
                    cost: (Shows) -> Double) -> Outcome {
        var schedule = GameTextSchedule(), tracker = GearDropTracker()
        var outcome = Outcome()
        struct Pending {
            let request: GameTextSchedule.Request
            let shows: Shows?
            let evidence: GearDropFrameEvidence?
            let done: Double
            var cancelledAt: Double?
        }
        var pending: Pending?
        var lastLook = -Double.infinity, lastSample = -Double.infinity, lastShowedPanel = false
        if let headerAt, let request = schedule.take(at: headerAt, panelCandidate: false, resultEligible: false,
                                                     minimumInterval: 0.2, readsHeader: true, headerInterval: 1) {
            pending = Pending(request: request, shows: nil, evidence: nil, done: headerAt + 0.1)
            outcome.headerReads += 1
        }
        for frame in frames.dropFirst(phase) {
            let time = frame.time
            guard time - lastLook >= 0.049 - 1e-9 else { continue }
            lastLook = time
            let interval = !constrained || (lane103 && lastShowedPanel) ? 0.049 : 0.099
            guard time - lastSample >= interval - 1e-9 else { continue }
            lastSample = time
            outcome.analysedFrames += 1
            if let read = pending {
                let done = read.cancelledAt.map { min(read.done, $0 + cancelLatency) } ?? read.done
                if time + 1e-9 >= done {
                    if let at = read.cancelledAt {
                        outcome.cancels.append((read.request.sourceTime, at))
                        schedule.finish(read.request)
                    } else {
                        let panel = read.shows == .portal || read.shows == .bonus
                        schedule.finish(read.request, panelPresent: panel, untitledPanel: read.shows == .untitled)
                        if let evidence = read.evidence, let closed = tracker.accept(evidence) {
                            outcome.groups.append(closed)
                        }
                    }
                    pending = nil
                }
            }
            lastShowedPanel = frame.bounds != nil
            if lane103, let stop = schedule.observeGearPanel(frame.bounds, at: time,
                    previousPanelUnconfirmed: tracker.isObserving && !tracker.currentPanelSettled),
               pending?.request == stop {
                pending?.cancelledAt = time
            }
            let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                        minimumInterval: constrained ? 0.2 : 0.1, gearCandidate: frame.bounds != nil,
                                        readsHeader: true, headerInterval: constrained ? 1 : 0.5,
                                        gearInterval: constrained ? 0.4 : 0.2,
                                        gearPanelPace: constrained && !tracker.currentPanelSettled
                                            ? .init(minimumInterval: 0.1, gearInterval: 0.2) : nil)
            if let request {
                outcome.mostInFlight = max(outcome.mostInFlight, pending == nil ? 1 : 2)
                if request.mode == .gear, let shows = frame.shows {
                    let evidence: GearDropFrameEvidence
                    switch shows {
                    case .portal:
                        evidence = GearDropFrameEvidence(sourceTime: time, stage: .portal, bounds: frame.bounds,
                                                         entries: rows?(.portal) ?? portalRows)
                    case .bonus:
                        evidence = GearDropFrameEvidence(sourceTime: time, stage: .bonus, bounds: frame.bounds,
                                                         entries: rows?(.bonus) ?? bonusRows, effects: ["ITO EN (-)"])
                    case .untitled:
                        evidence = GearDropFrameEvidence(sourceTime: time, stage: .unknown, bounds: frame.bounds)
                    }
                    pending = Pending(request: request, shows: shows, evidence: evidence, done: time + cost(shows))
                    outcome.reads.append((time, shows))
                } else {
                    pending = Pending(request: request, shows: nil, evidence: nil, done: time + 0.1)
                    outcome.headerReads += 1
                }
            }
            if let closed = tracker.observe(at: time, panelCandidate: frame.bounds != nil,
                                            pendingReadSourceTime: pending?.evidence?.sourceTime) {
                outcome.groups.append(closed)
            }
        }
        // The rest of the stream, with nothing on screen.
        var time = (frames.last?.time ?? 0) + 0.05
        while time < (frames.last?.time ?? 0) + 3 {
            if let read = pending {
                let done = read.cancelledAt.map { min(read.done, $0 + cancelLatency) } ?? read.done
                if time + 1e-9 >= done {
                    if read.cancelledAt == nil, let evidence = read.evidence, let closed = tracker.accept(evidence) {
                        outcome.groups.append(closed)
                    }
                    if let at = read.cancelledAt { outcome.cancels.append((read.request.sourceTime, at)) }
                    pending = nil
                }
            }
            if let closed = tracker.observe(at: time, panelCandidate: false,
                                            pendingReadSourceTime: pending?.evidence?.sourceTime) {
                outcome.groups.append(closed)
            }
            time += 0.05
        }
        if let closed = tracker.finish(at: time, reason: "test") { outcome.groups.append(closed) }
        return outcome
    }

    /// Item quantities kept for `shows`'s panel, if every row was kept.
    static func kept(_ outcome: Outcome, _ stage: GearDropStage) -> Bool {
        let truth = stage == .bonus ? bonusRows : portalRows
        return outcome.groups.flatMap(\.panels).contains { panel in
            panel.stage == stage && !panel.partial
                && panel.entries.map { $0.withMultiplied(nil) }.sorted { $0.position < $1.position }
                    == truth.sorted { $0.position < $1.position }
        }
    }

    /// Stored rows not shown on their panel.
    static func wrongItems(_ outcome: Outcome) -> Int {
        outcome.groups.flatMap(\.panels).reduce(0) { count, panel in
            let truth = panel.stage == .bonus ? bonusRows : panel.stage == .portal ? portalRows : []
            return count + panel.entries.filter { entry in !truth.contains { $0 == entry.withMultiplied(nil) } }.count
        }
    }
}

/// Decision (a) of 2026-10-29 (Ato 1939), build 103: a short Bonus panel that
/// replaces its portal panel in place keeps its rows whatever a read of the
/// portal panel costs. Read costs: 0.35 s, plus X for each title pass beyond
/// the first (the portal panel of 2026-10-28 hack 1 and hack 3's untitled
/// panel: one title-zone fallback per read; Bonus reads none), X from 0.05
/// to 0.35 s; flat 0.025 s (the replay's default), 0.35 s and 0.55 s; and
/// the conservative model, X for every title pass (two a read). Each case runs
/// at both 10-Hz phases and with a header read in flight at four offsets.
@Suite("Build 103: a new panel's first read, over a whole drop")
struct GearNewPanelLaneTests {
    typealias Sim = GearLaneSimulation

    /// 2026-10-28 hack 1 without the recording's gap: its portal panel 1.8 s,
    /// one frame without a panel, then its Bonus panel 1.9 s, taller, in the
    /// same place.
    static let hack1 = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 1.8, height: 0.1309)
        + Sim.nothing(from: 2.1, seconds: 0.05) + Sim.panel(.bonus, from: 2.15, seconds: 1.9, height: 0.1667)
        + Sim.nothing(from: 4.05, seconds: 0.5)
    /// 2026-10-28 hack 3: a portal panel whose title is never read, 0.65 s,
    /// then at once its 0.45-s Bonus panel, shorter, in the same place.
    static let hack3 = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.untitled, from: 0.3, seconds: 0.65, height: 0.1667)
        + Sim.panel(.bonus, from: 0.95, seconds: 0.45, height: 0.1309) + Sim.nothing(from: 1.4, seconds: 0.3)
    /// 2026-10-28 hack 2: a titled portal panel 1.45 s (its Latin title needs
    /// no title pass), one frame without a panel, then a 0.55-s Bonus panel of
    /// the very same size in the same place: only its slide tells it apart.
    static let hack2 = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 1.45, height: 0.1309)
        + Sim.nothing(from: 1.75, seconds: 0.05) + Sim.panel(.bonus, from: 1.8, seconds: 0.55, height: 0.1309)
        + Sim.nothing(from: 2.35, seconds: 0.3)

    static let sweep = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35]
    /// 10-Hz phase and a header read in flight when the window opens.
    static let starts: [(phase: Int, headerAt: Double?)] = [0, 1].flatMap { phase in
        [nil, 0.3, 0.25, 0.2, 0.15].map { (phase, $0) }
    }

    enum Model: CustomStringConvertible {
        case extra(Double), perTitlePass(Double), flat(Double)
        var description: String {
            switch self {
            case .extra(let x): return String(format: "0.35 + %.2f extra", x)
            case .perTitlePass(let x): return String(format: "0.35 + 2 x %.2f", x)
            case .flat(let c): return String(format: "flat %.3f", c)
            }
        }
        /// `titled`: the portal panel's title needs no title pass (hack 2).
        func cost(_ shows: Sim.Shows, titled: Bool) -> Double {
            let titlePasses = shows == .bonus || titled && shows == .portal ? 0 : 2
            switch self {
            case .extra(let x): return 0.35 + (titlePasses > 0 ? x : 0)
            case .perTitlePass(let x): return 0.35 + Double(titlePasses) * x
            case .flat(let c): return c
            }
        }
    }

    static let required: [Model] = sweep.map(Model.extra) + [.flat(0.025), .flat(0.35)]

    func outcomes(_ frames: [Sim.Frame], _ model: Model, titled: Bool = false, lane103: Bool = true,
                  cancelLatency: Double) -> [Sim.Outcome] {
        Self.starts.map { start in
            Sim.run(frames, lane103: lane103, cancelLatency: cancelLatency, phase: start.phase,
                    headerAt: start.headerAt) { model.cost($0, titled: titled) }
        }
    }

    @Test("Hack 1 without a gap: the Bonus panel and the portal panel keep their rows at every cost",
          arguments: [0.0, 0.05])
    func hack1Kept(cancelLatency: Double) {
        for model in Self.required + Self.sweep.map(Model.perTitlePass) {
            for (index, outcome) in outcomes(Self.hack1, model, cancelLatency: cancelLatency).enumerated() {
                #expect(Sim.kept(outcome, .bonus), "\(model), start \(index): Bonus reads \(outcome.reads)")
                #expect(Sim.kept(outcome, .portal), "\(model), start \(index): reads \(outcome.reads)")
                #expect(outcome.groups.count == 1 && Sim.wrongItems(outcome) == 0)
                #expect(outcome.mostInFlight == 1)
            }
        }
    }

    @Test("Hack 3: a 0.45-s Bonus panel after an untitled portal panel keeps its rows at every cost to 0.35 s",
          arguments: [0.0, 0.05])
    func hack3Kept(cancelLatency: Double) {
        for model in Self.required + Self.sweep.map(Model.perTitlePass) {
            for (index, outcome) in outcomes(Self.hack3, model, cancelLatency: cancelLatency).enumerated() {
                #expect(Sim.kept(outcome, .bonus),
                        "\(model), start \(index): reads \(outcome.reads), stopped \(outcome.cancels)")
                #expect(outcome.groups.count == 1 && Sim.wrongItems(outcome) == 0)
                #expect(outcome.mostInFlight == 1)
            }
        }
    }

    @Test("Hack 2: a 0.55-s Bonus panel of the portal panel's very size keeps its rows; so does the portal panel",
          arguments: [0.0, 0.05])
    func hack2Kept(cancelLatency: Double) {
        for model in [Model.flat(0.025), .flat(0.35)] {
            for (index, outcome) in outcomes(Self.hack2, model, titled: true, cancelLatency: cancelLatency).enumerated() {
                #expect(Sim.kept(outcome, .bonus), "\(model), start \(index): reads \(outcome.reads)")
                #expect(Sim.kept(outcome, .portal), "\(model), start \(index): reads \(outcome.reads)")
                #expect(outcome.groups.count == 1 && Sim.wrongItems(outcome) == 0)
            }
        }
    }

    @Test("At 0.55 s a read, and at every other cost, nothing is lost against build 102", arguments: [0.0, 0.05])
    func noLossAgainst102(cancelLatency: Double) {
        let cases: [([Sim.Frame], Bool)] = [(Self.hack1, false), (Self.hack3, false), (Self.hack2, true)]
        let models = [Model.flat(0.55)] + Self.required + Self.sweep.map(Model.perTitlePass)
        for (frames, titled) in cases {
            for model in models {
                let new = outcomes(frames, model, titled: titled, cancelLatency: cancelLatency)
                let old = outcomes(frames, model, titled: titled, lane103: false, cancelLatency: 0)
                for (index, (after, before)) in zip(new, old).enumerated() {
                    for stage in [GearDropStage.portal, .bonus] where Sim.kept(before, stage) {
                        #expect(Sim.kept(after, stage), "\(model), start \(index), \(stage): 102 kept it")
                    }
                    #expect(Sim.wrongItems(after) == 0)
                    #expect(after.groups.count <= max(1, before.groups.count))
                }
            }
        }
    }

    @Test("Prints the keep table, build 102 against 103 (no assertion beyond the runs)")
    func table() {
        var lines: [String] = []
        let models = Self.sweep.map(Model.extra) + [.flat(0.025), .flat(0.35), .flat(0.55)]
            + Self.sweep.map(Model.perTitlePass)
        for (name, frames, titled) in [("hack1", Self.hack1, false), ("hack3", Self.hack3, false),
                                       ("hack2", Self.hack2, true)] {
            for (lane103, latency) in [(false, 0.0), (true, 0.0), (true, 0.05), (true, 0.10)] {
                let cells = models.map { model -> String in
                    let runs = outcomes(frames, model, titled: titled, lane103: lane103, cancelLatency: latency)
                    return "\(runs.filter { Sim.kept($0, .bonus) }.count)"
                }
                lines.append("\(name) \(lane103 ? String(format: "103 cancel %.2f", latency) : "102") Bonus kept /10: "
                             + cells.joined(separator: " "))
            }
            let analysed = [false, true].map { lane103 in
                Sim.run(frames, lane103: lane103, cancelLatency: 0.05) { Model.flat(0.35).cost($0, titled: titled) }
                    .analysedFrames
            }
            lines.append("\(name) analysed frames 102 \(analysed[0]) 103 \(analysed[1])")
        }
        print("GEAR103-LANE-TABLE\n" + lines.joined(separator: "\n"))
    }
}
