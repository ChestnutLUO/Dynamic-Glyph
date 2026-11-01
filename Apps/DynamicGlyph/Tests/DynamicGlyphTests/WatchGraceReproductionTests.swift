import CoreVideo
import Foundation
import GlyphRecognition
import Testing

/// Desired watch/grace policy regressions, intentionally red on shipped build 91.
/// Only header OCR is injected; geometry, fit retention, tracker,
/// command watch, sampling and meter all use the real live-output pipeline.
@Suite("Cached calibration command-watch reproduction", .serialized)
struct WatchGraceReproductionTests {
    @Test("Cached geometry survives eight seconds without renewing command watching beyond fresh evidence",
          arguments: [false, true])
    func cachedCalibrationRenewsWatch(lowPower: Bool) throws {
        let harness = try WatchReproductionHarness(lowPower: lowPower) { _, time in
            WatchReproductionHarness.header(time == 0 ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00456"), firstGlyphBuffer = try Frames.recorded("field-00443")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 0)
        // Complete, monotonic, same-size frames: no clock rollback, callback
        // interruption, dimension reset, idle-frame retention or still ticks.
        for index in 1...783 {
            try harness.play(maps[(index / 3) % maps.count], at: Double(index) / 60)
        }
        // Print the actual baseline before any desired-policy assertion can
        // fail, and without a #require that could hide the measurements.
        let observedWatchOff = harness.probes.first { $0.time > 1 && !$0.reasons.has(.commandWatch) }?.time
        let observedSettle = harness.probes.first { $0.mode?.mode == .resting }?.time
        harness.report("cached-watch lowPower=\(lowPower) observedWatchOff=\(String(describing: observedWatchOff)) observedSettle=\(String(describing: observedSettle)); desired watch ~1.6, independent phase grace ~5, rest <=7.2")

        // Positive safety control: do not 'fix' sleeping by discarding useful
        // fits or starving the next hack. A new screen gets its first eligible
        // 20-Hz look, fits the 100-ms empty array, then reads the first Glyph.
        // The last delivered map frame is 13.05; its final actual slow sample
        // may shift with settling alignment. Switching at 13.10 must occur
        // before the next slow poll and force this first eligible 20-Hz look.
        for index in 786...816 {
            try harness.play(index < 792 ? empty : firstGlyphBuffer, at: Double(index) / 60)
        }
        let rows = try harness.finish()
        let observedLastFit = rows.last { WatchReproductionHarness.time($0) < 13 && $0["calibration"] != nil }
        print("WATCH REPRODUCTION: lowPower=\(lowPower) observedLastCachedFit=\(String(describing: observedLastFit.map(WatchReproductionHarness.time)))")

        let atSix = try #require(harness.probes.first { abs($0.time - 6) < 0.001 })
        // The legitimate five-second interrupted-phase grace is independent
        // of watch freshness. At six seconds it has ended, but its ordinary
        // two-second settling tail still permits active mode (20/10 Hz).
        #expect(atSix.mode?.mode == .active && atSix.mode?.ratePerSecond == (lowPower ? 10 : 20))
        #expect(atSix.mode?.inHack == false && atSix.analysedLastSecond == (lowPower ? 10 : 20),
                "The ordinary settle tail must not retain command-watch/in-hack priority")
        #expect(!atSix.reasons.has(.commandWatch) && !atSix.reasons.has(.interrupted),
                "Neither command watch nor interrupted grace may prolong cached-only coverage")
        #expect(!atSix.reasons.has(.command) && !atSix.reasons.has(.resultContext))
        for reason in WatchReproductionHarness.freshReasons {
            #expect(!atSix.reasons.has(reason), "No current hack/panel cue at source 6 s: \(reason.label)")
        }
        for time in [10.0, 13.0] {
            let probe = try #require(harness.probes.first { abs($0.time - time) < 0.001 })
            #expect(probe.mode?.mode == .resting && probe.mode?.inHack == false)
            #expect(probe.mode?.ratePerSecond == (lowPower ? 2 : 4))
            #expect(probe.analysedLastSecond == (lowPower ? 2 : 4), "Actual slow analyses in the preceding source second")
            #expect(!probe.reasons.has(.commandWatch) && !probe.reasons.has(.interrupted))
        }
        let noWatch = try #require(observedWatchOff)
        let settled = try #require(observedSettle)
        #expect(abs(noWatch - 1.6) <= 0.051, "Watch first absent at source \(noWatch), expected ~1.6")
        let graceReleased = try #require(harness.probes.first {
            $0.time > 1 && !$0.reasons.has(.commandWatch) && !$0.reasons.has(.interrupted) && $0.mode?.inHack == false
        }?.time)
        #expect((4.95...5.05).contains(graceReleased), "Preserve the independent five-second phase grace anchored at source zero")
        #expect((6.95...7.2).contains(settled), "Resting at source \(settled), expected phase grace plus the existing two-second settle")
        #expect(abs(settled - (graceReleased + 2)) <= 0.101)
        #expect(harness.output.textReadMetrics.gearSubmitted == 0)
        #expect(harness.output.textReadMetrics.resultSubmitted == 0)
        #expect(harness.output.textReadMetrics.portalSubmitted == 0)

        let seed = try #require(rows.first)
        #expect(seed["state"] as? String == "noStroke")
        #expect((seed["calibration"] as? [String: Any])?["matchedNodes"] as? Int == 11)
        let command = try #require(rows.first { $0["phase"] as? String == "command" })
        #expect(command["headerSourceTime"] as? Double == 0)
        // A slow sample need not land exactly at 6.0. Inspect the next actual
        // analysis, within one constrained resting interval, rather than force
        // the old 20-Hz alignment to survive the policy change.
        let six = try #require(rows.first { WatchReproductionHarness.time($0) >= 6 })
        #expect(WatchReproductionHarness.time(six) <= 6.55)
        #expect(six["phase"] as? String == "interrupted")
        #expect(six["calibration"] != nil && six["slotCount"] == nil && six["inputTimerVisible"] as? Bool == false)
        let cachedRows = rows.filter { (4.0...8.0).contains(WatchReproductionHarness.time($0)) }
        #expect(!cachedRows.isEmpty)
        #expect(cachedRows.allSatisfy { $0["calibration"] != nil },
                "Watch release must preserve useful cached recognition geometry until its existing eight-second expiry")
        let cachedRestingRows = cachedRows.filter { WatchReproductionHarness.time($0) >= 7.2 }
        #expect(!cachedRestingRows.isEmpty && cachedRestingRows.allSatisfy { $0["analysisMode"] as? String == "resting" },
                "Cached geometry must survive on actual slow analyses after phase grace and settling end")
        let lastFit = try #require(observedLastFit)
        #expect((7.45...8.0).contains(WatchReproductionHarness.time(lastFit)),
                "Last cached-fit sample must be within one slow interval of the unchanged eight-second expiry")
        let mapTail = rows.filter { (8.55...13.0).contains(WatchReproductionHarness.time($0)) }
        #expect(!mapTail.isEmpty && mapTail.allSatisfy {
            $0["calibration"] == nil && $0["slotCount"] == nil && $0["analysisMode"] as? String == "resting"
        })
        let lastMap = try #require(rows.last { WatchReproductionHarness.time($0) < 13.099 })
        #expect((12.9...13.05).contains(WatchReproductionHarness.time(lastMap)),
                "Bounded slow-sample alignment may change when the watch policy changes")
        #expect(13.1 - WatchReproductionHarness.time(lastMap) < AnalysisRateController.Policy().quietInterval,
                "The returning hack must not merely coincide with an already due slow sample")
        let returning = try #require(rows.first { WatchReproductionHarness.time($0) >= 13.099 })
        #expect(abs(WatchReproductionHarness.time(returning) - 13.1) < 0.001,
                "The very first eligible look after the screen switch must wake")
        #expect(returning["calibration"] != nil && returning["state"] as? String == "noStroke")
        let glyph = try #require(rows.first { WatchReproductionHarness.time($0) >= 13.199 })
        #expect(abs(WatchReproductionHarness.time(glyph) - 13.2) < 0.001)
        #expect(glyph["calibration"] != nil && glyph["state"] as? String != "noStroke")
        #expect(rows.filter { WatchReproductionHarness.time($0) >= 13.099 }.allSatisfy {
            $0["analysisMode"] as? String == "active"
        })
        // Fresh-fit cutoff, watch flicker and settling are independent of the
        // eight-second geometry cache; none requires throwing recognition away.
    }

    @Test("Negative control: the identical moving night map without a seeded fit settles at two seconds")
    func noFitDoesNotStartWatch() throws {
        let harness = try WatchReproductionHarness { _, time in
            WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        let maps = try harness.maps(matching: Frames.solid())
        for index in 0...360 {
            try harness.play(maps[(index / 3) % maps.count], at: Double(index) / 60)
        }
        #expect(harness.probes.allSatisfy { !$0.reasons.has(.commandWatch) && !$0.reasons.has(.interrupted) })
        let settled = try #require(harness.probes.first { $0.mode?.mode == .resting })
        #expect(abs(settled.time - 2) < 0.051)
        #expect(harness.probes.last?.analysedLastSecond == 4)
        let rows = try harness.finish()
        #expect(rows.allSatisfy { $0["calibration"] == nil && $0["slotCount"] == nil })
        harness.report("no-fit night-map control settled=\(settled.time)")
    }

    @Test("Safety control: a visible array keeps its recognition data and the first Glyph at full speed",
          arguments: [false, true])
    func visibleArrayDoesNotSleep(lowPower: Bool) throws {
        let harness = try WatchReproductionHarness(lowPower: lowPower) { _, time in
            WatchReproductionHarness.header(.presenting, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        for index in 0...132 {
            try harness.play(index < 120 ? empty : glyph, at: Double(index) / 60)
        }
        let rows = try harness.finish()
        #expect(rows.count == 45, "Every 20-Hz sample is retained through a visible hack")
        #expect(rows.allSatisfy { $0["calibration"] != nil && $0["analysisMode"] as? String == "active" })
        let firstGlyph = try #require(rows.first { WatchReproductionHarness.time($0) >= 2 })
        #expect(WatchReproductionHarness.time(firstGlyph) == 2)
        #expect(firstGlyph["state"] as? String != "noStroke" && firstGlyph["phase"] as? String == "presenting")
        #expect(harness.probes.last?.mode?.ratePerSecond == 20)
        #expect(harness.probes.last?.analysedLastSecond == 20)
        #expect(harness.traces.values.contains { $0.events.contains { $0.kind == .hackStarted } })
        harness.report("visible-array control lowPower=\(lowPower) firstGlyph=2.0")
    }
}

/// Separate from the cached-fit reproduction: a backwards source clock leaves
/// lastPhaseTime in the future. This does not establish any phone-report cause.
@Suite("Source-clock rollback reproduction", .serialized)
struct SourceClockRollbackReproductionTests {
    @Test("A source-clock rewind rejects future phase grace and settles without command watching")
    func futurePhaseTimestampOutlivesRewoundGrace() throws {
        let harness = try WatchReproductionHarness(lowPower: true, meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 100 ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00456")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 100)
        try harness.play(maps[0], at: 100.05)
        for index in 60...420 {
            try harness.play(maps[(index / 3) % maps.count], at: Double(index) / 60)
        }
        let observedSettle = harness.probes.first { $0.time < 10 && $0.mode?.mode == .resting }?.time
        harness.report("rollback 100 -> 1 observedSettle=\(String(describing: observedSettle)); desired ~3.05, no future phase grace")
        let rows = try harness.finish()
        print("WATCH REPRODUCTION: rollback retained phase anchors=\(harness.traces.values.compactMap(\.phaseTime))")
        let atSeven = try #require(harness.probes.last)
        #expect(atSeven.time == 7 && atSeven.mode?.inHack == false)
        #expect(!atSeven.reasons.has(.interrupted) && !atSeven.reasons.has(.commandWatch))
        #expect(atSeven.mode?.mode == .resting && atSeven.mode?.ratePerSecond == 2 && atSeven.analysedLastSecond == 2)
        for reason in WatchReproductionHarness.freshReasons { #expect(!atSeven.reasons.has(reason)) }
        #expect(observedSettle != nil, "A rewound clock must settle without waiting for the future phase anchor")
        if let settled = observedSettle {
            #expect((3.0...3.15).contains(settled), "Rewound source should settle two seconds after losing coverage, not wait for source 105")
        }
        let rewoundProbes = harness.probes.filter { $0.time >= 1.05 && $0.time < 10 }
        #expect(!rewoundProbes.isEmpty && rewoundProbes.allSatisfy {
            $0.mode?.inHack == false && !$0.reasons.has(.commandWatch) && !$0.reasons.has(.interrupted)
        }, "A future phase anchor cannot authorize grace on the restarted source clock")
        #expect(rows.contains { $0["phase"] as? String == "command" && $0["headerSourceTime"] as? Double == 100 })
        let rewound = rows.filter { WatchReproductionHarness.time($0) < 10 }
        #expect(!rewound.isEmpty && rewound.allSatisfy {
            $0["phase"] as? String == "interrupted" && $0["calibration"] == nil
        })
        let slowTail = rewound.filter { WatchReproductionHarness.time($0) >= 3.2 }
        #expect(!slowTail.isEmpty && slowTail.allSatisfy { $0["analysisMode"] as? String == "resting" })
    }
}

// MARK: - Test-only harness (does not share or modify the existing private one)

final class WatchReproductionHarness {
    struct Probe {
        let time: Double
        let mode: ReadingMode?
        let reasons: AnalysisGateReasons
        let analysedLastSecond: UInt64
        let commandBandSamples: UInt64
    }
    static let freshReasons: [AnalysisGateReason] = [
        .calibration, .slots, .timer, .commandNotice, .resultPanel, .gearPanel,
        .portalPanel, .gearGroup, .gearObserver, .presenting, .input
    ]
    let directory: TemporaryDirectory
    let output: LiveGlyphOutput
    let traces: WatchReproductionValues<LiveGlyphTrace>
    private let clock: WatchReproductionClock
    private let meter: PowerMeter
    private let meterFollowsSource: Bool
    private(set) var probes: [Probe] = []

    init(lowPower: Bool = false, meterFollowsSource: Bool = true,
         headerOperation: @escaping GameHeaderReader.HeaderOperation) throws {
        self.meterFollowsSource = meterFollowsSource
        let directory = try TemporaryDirectory("watch-reproduction")
        self.directory = directory
        let clock = WatchReproductionClock()
        self.clock = clock
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        self.meter = meter
        meter.reset()
        let traces = WatchReproductionValues<LiveGlyphTrace>()
        self.traces = traces
        output = try LiveGlyphOutput(
            table: SetupDemo.builtInTable, sequenceTable: nil, sessionID: CaptureSessionID(rawValue: 91),
            directory: directory.url, readsResults: true, readsGear: true,
            power: PowerConditions(center: NotificationCenter(), read: { .init(lowPowerMode: lowPower) }),
            meter: meter, headerOperation: headerOperation, trace: { traces.append($0) },
            telemetry: { _ in }, deliverResult: { _ in }, deliver: { _ in })
    }

    static func header(_ phase: GamePhase, at time: Double) -> HeaderReading {
        HeaderReading(phase: phase, matchedText: phase == .unknown ? "" : "INJECTED \(phase.rawValue)",
                      confidence: phase == .unknown ? 0 : 1, sourceTime: time)
    }

    func maps(matching buffer: CVPixelBuffer) throws -> [CVPixelBuffer] {
        let maps = try (0..<4).map {
            try Frames.nightMap(phase: $0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        let gate = try maps.map { try #require(LumaGate().read($0)) }
        // Precompute the predicate: this SDK's #expect expansion can infer a
        // throwing function from a key-path allSatisfy argument.
        let allMapPhasesAreCandidates = gate.allSatisfy { $0.isCandidate }
        #expect(allMapPhasesAreCandidates, "All map phases must remain dim candidates")
        #expect(gate[0].difference(from: gate[2]) > AnalysisRateController.Policy().changeThreshold)
        return maps
    }

    func play(_ buffer: CVPixelBuffer, at time: Double, arrival: Double? = nil,
              status: CaptureFrameStatus = .complete, broken: Bool = false,
              waitForText: Bool = true) throws {
        // Meter time is monotonic even in the separately labelled rollback
        // test. Arrival and source clocks are deliberately independent.
        if meterFollowsSource { clock.set(time) } else { clock.advance() }
        output.process(CapturedFrame(sampleBuffer: try Frames.sample(buffer, at: time),
                                    metadata: CaptureFrameMetadata(status: status),
                                    arrivalUptime: arrival ?? (1000 + clock.seconds),
                                    deliveryGapMilliseconds: nil, continuityBroken: broken))
        if waitForText { try waitForTextReads() }
        // Advance by source-delivery cadence, not recognition wall time. The
        // rollback prelude is deliberately excluded from exact rate assertions.
        let snapshot = meter.snapshot()
        if probes.last?.reasons != snapshot.gateOccupancy.current || probes.last?.mode != snapshot.readingMode
            || (Int((time * 60).rounded()) % 3 == 0) {
            probes.append(Probe(time: time, mode: snapshot.readingMode,
                                reasons: snapshot.gateOccupancy.current, analysedLastSecond: snapshot.analysedLastSecond,
                                commandBandSamples: snapshot.total(.commandBand).count))
        }
    }

    func waitForTextReads() throws {
        let deadline = Date().addingTimeInterval(20)
        while output.isReadingText {
            guard Date() < deadline else { throw Frames.Failure(description: "Injected header lane did not finish within 20 seconds") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func finish() throws -> [[String: Any]] {
        output.close()
        let text = try String(contentsOf: directory.url.appendingPathComponent("recognition.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(UInt64(rows.count) == meter.snapshot().total(.framesAnalysed).count,
                "Recognition rows must count actual analyses, not gate looks")
        return rows
    }

    static func time(_ row: [String: Any]) -> Double { row["presentationTime"] as? Double ?? -.infinity }

    func report(_ label: String) {
        print("WATCH REPRODUCTION: \(label)")
        for probe in probes where [1.0, 1.6, 3.05, 3.1, 3.6, 5, 6, 7, 8, 8.5, 8.6, 10, 10.6, 12, 13].contains(where: { abs(probe.time - $0) < 0.001 }) {
            let reasons = AnalysisGateReason.allCases.filter { probe.reasons.has($0) }.map(\.label).joined(separator: ", ")
            print("  source=\(probe.time) mode=\(probe.mode?.mode.rawValue ?? "none") cap=\(probe.mode?.ratePerSecond ?? 0) measuredLastSecond=\(probe.analysedLastSecond) inHack=\(probe.mode?.inHack ?? false) reasons=[\(reasons)]")
        }
    }
}

final class WatchReproductionValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

private final class WatchReproductionClock: @unchecked Sendable {
    private var ticks: UInt64 = 0
    private(set) var now: UInt64 = 0
    var seconds: Double { Double(now) / 1e9 }
    func set(_ seconds: Double) { now = UInt64((seconds * 1e9).rounded()) }
    func advance() {
        ticks += 1
        now = ticks * 1_000_000_000 / 60
    }
}
