import CoreVideo
import Foundation
import GlyphRecognition
import Testing

@Suite("Source clock activity ownership", .serialized)
struct SourceClockActivityTests {
    @Test("An idle-only rewind cannot recycle the old numeric fit time as fresh activity",
          arguments: [false, true])
    func idleRewindDoesNotRearmOldFit(lowPower: Bool) throws {
        let harness = try WatchReproductionHarness(lowPower: lowPower, meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 100 ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00381")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 100, arrival: 1000)
        try harness.play(empty, at: 100.05, arrival: 1000.05)
        // Idle does not call GlyphFrameSession.observe, so its previousTime
        // and validatedAt remain on the old epoch. Catching up numerically
        // must not turn this cached geometry into a fresh node-array match.
        try harness.play(empty, at: 1, arrival: 1000.1, status: .idle)
        try harness.play(empty, at: 1, arrival: 1099.1, status: .idle)
        for index in 0...180 {
            try harness.play(maps[(index / 3) % maps.count], at: 100.1 + Double(index) / 60,
                             arrival: 1099.2 + Double(index) / 60)
        }
        let caughtUp = harness.probes.filter { (100.099...103.2).contains($0.time) }
        #expect(!caughtUp.isEmpty && caughtUp.allSatisfy {
            !$0.reasons.has(.commandWatch) && !$0.reasons.has(.interrupted) && !$0.reasons.has(.calibration)
                && $0.mode?.inHack == false
        })
        #expect(caughtUp.last?.mode?.mode == .resting)
        #expect(caughtUp.last?.mode?.ratePerSecond == (lowPower ? 2 : 4))
        // A real new empty-array validation (not merely recognizing with the
        // cached fit) must restore normal fresh-fit wake and watch coverage.
        for index in 1...42 {
            try harness.play(empty, at: 103.1 + Double(index) / 60,
                             arrival: 1102.2 + Double(index) / 60)
        }
        let fresh = try #require(harness.probes.last)
        #expect(fresh.reasons.has(.calibration) && fresh.reasons.has(.commandWatch))
        #expect(fresh.mode?.ratePerSecond == 20 && fresh.mode?.inHack == true)
        let rows = try harness.finish()
        let reused = try #require(rows.first { abs(WatchReproductionHarness.time($0) - 100.1) < 0.001 })
        #expect(reused["calibration"] != nil, "Clock invalidation must not throw recognition geometry away just to sleep")
        harness.report("idle-only rewind lowPower=\(lowPower); old fit cannot re-arm after numeric catch-up")
    }

    @Test("Startup after an idle rewind refreshes identical outside pixels before the old baseline expires")
    func startupHeaderAfterNumericCatchUp() throws {
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 100 ? .unknown : .presenting, at: time)
        }
        defer { harness.output.close() }
        let map = try Frames.identicalHeader(Frames.nightMap(phase: 0))
        try harness.play(map, at: 100, arrival: 1000)
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 1)
        try harness.play(map, at: 1, arrival: 1000.05, status: .idle)
        // Arrival time explains the long delivery gap: the idle rewind, not
        // an accidental second forward-jump invalidation, must clear baseline.
        try harness.play(map, at: 100.5, arrival: 1099.55)
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 2)
        #expect(harness.output.textReadMetrics.headerSkippedUnchanged == 0)
        try harness.play(map, at: 100.75, arrival: 1099.8)
        #expect(harness.traces.values.contains {
            $0.state == .presenting && $0.phaseTime == 100.5 && $0.hackID == 1
        }, "Identical startup pixels must not hide the first known phase in the new epoch")
        let rows = try harness.finish()
        #expect(rows.allSatisfy { $0["calibration"] == nil && $0["slotCount"] == nil },
                "Only the phase-epoch reset, not independent hack cues, may bypass the old baseline")
        #expect(rows.contains { $0["headerSourceTime"] as? Double == 100.5 })
    }

    @Test("Old-epoch geometry cannot bypass a new unchanged-header baseline after numeric catch-up")
    func staleFitDoesNotBypassHeaderGate() throws {
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.identicalHeader(Frames.recorded("field-00381"))
        let map = try Frames.identicalHeader(Frames.nightMap(phase: 0,
            width: CVPixelBufferGetWidth(empty), height: CVPixelBufferGetHeight(empty)))
        try harness.play(empty, at: 100, arrival: 1000)
        try harness.play(empty, at: 1, arrival: 1000.05, status: .idle)
        try harness.play(map, at: 100.5, arrival: 1099.55)
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 2)
        try harness.play(map, at: 101, arrival: 1100.05)
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 2,
                "A retained fit with numerically young validatedAt is not a current-epoch fresh-header cue")
        #expect(harness.output.textReadMetrics.headerSkippedUnchanged == 1)
        let rows = try harness.finish()
        let caughtUp = rows.filter { WatchReproductionHarness.time($0) > 100 }
        #expect(caughtUp.count == 2)
        #expect(caughtUp.allSatisfy {
            $0["calibration"] != nil && $0["slotCount"] == nil && $0["inputTimerVisible"] as? Bool == false
        }, "Keep useful geometry, but do not confuse it with current fit/slot/timer evidence")
        #expect(harness.probes.filter { $0.time > 100 }.allSatisfy {
            !$0.reasons.has(.calibration) && !$0.reasons.has(.commandWatch)
        })
    }

    @Test("An unexplained forward source jump clears old phase activity without resetting a session")
    func forwardJump() throws {
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 1 ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00381")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 1, arrival: 1001)
        try harness.play(maps[0], at: 1.05, arrival: 1001.05)
        for index in 0...180 {
            try harness.play(maps[(index / 3) % maps.count], at: 100 + Double(index) / 60,
                             arrival: 1001.1 + Double(index) / 60)
        }
        let afterJump = harness.probes.filter { $0.time >= 100 }
        #expect(!afterJump.isEmpty && afterJump.allSatisfy {
            !$0.reasons.has(.interrupted) && !$0.reasons.has(.commandWatch) && $0.mode?.inHack == false
        })
        #expect(harness.traces.values.filter { $0.time >= 100 }.allSatisfy { $0.phaseTime == nil })
        let settled = try #require(afterJump.first { $0.mode?.mode == .resting })
        print("WATCH REPRODUCTION: forward jump first resting source=\(settled.time)")
        #expect((100...102.2).contains(settled.time))
        #expect(afterJump.last?.mode?.ratePerSecond == 4)
        #expect(afterJump.last?.analysedLastSecond == 4)
        _ = try harness.finish()
    }

    @Test("Repeated idle callbacks followed by an ordinary complete frame do not create a clock epoch",
          arguments: [false, true])
    func explainedDeliveryGap(repeatedIdle: Bool) throws {
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 0 ? .presenting : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00381")
        let glyph = try Frames.recorded("field-00443")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 0, arrival: 1000)
        try harness.play(glyph, at: 0.05, arrival: 1000.05)
        #expect(harness.traces.values.contains { $0.phaseTime == 0 })
        if repeatedIdle {
            for index in 1...13 {
                try harness.play(glyph, at: 0.05, arrival: 1000.05 + Double(index), status: .idle)
            }
        }
        try harness.play(maps[1], at: 13.1, arrival: 1013.1)
        let gap = try #require(harness.traces.values.last { $0.time == 13.1 })
        #expect(gap.phaseTime == 0,
                "Arrival uptime explains the source gap; do not invalidate phase ownership just because idle callbacks updated lastArrival")
        #expect(harness.output.textReadMetrics.staleCompletions == 0)
        _ = try harness.finish()
    }

    @Test("A new header on the rewound epoch gets its own bounded unknown grace")
    func freshHeaderAfterRewind() throws {
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            WatchReproductionHarness.header(time == 100 || time == 1 ? .command : .unknown, at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00381")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: 100)
        try harness.play(maps[0], at: 100.05)
        for index in 60...552 {
            try harness.play(maps[(index / 3) % maps.count], at: Double(index) / 60)
        }
        #expect(harness.traces.values.contains { $0.time < 10 && $0.phaseTime == 1 && $0.state == .command })
        let atThree = try #require(harness.probes.first { abs($0.time - 3) < 0.001 })
        #expect(atThree.reasons.has(.interrupted) && atThree.mode?.inHack == true)
        let atSeven = try #require(harness.probes.first { abs($0.time - 7) < 0.001 })
        #expect(!atSeven.reasons.has(.interrupted) && atSeven.mode?.inHack == false)
        let settled = try #require(harness.probes.first { $0.time < 10 && $0.mode?.mode == .resting })
        #expect((8...8.2).contains(settled.time), "Grace is anchored at new header1, not old header100")
        _ = try harness.finish()
    }

    @Test("Closing and restarting a live-output session cannot inherit the old phase anchor")
    func sessionRestart() throws {
        let first = try WatchReproductionHarness { _, time in
            WatchReproductionHarness.header(.command, at: time)
        }
        let empty = try Frames.recorded("field-00381")
        try first.play(empty, at: 100)
        try first.play(empty, at: 100.05)
        #expect(first.traces.values.contains { $0.phaseTime == 100 })
        _ = try first.finish()
        let next = try WatchReproductionHarness { _, time in
            WatchReproductionHarness.header(.unknown, at: time)
        }
        defer { next.output.close() }
        let maps = try next.maps(matching: empty)
        for index in 60...252 {
            try next.play(maps[(index / 3) % maps.count], at: Double(index) / 60)
        }
        #expect(next.probes.allSatisfy { !$0.reasons.has(.interrupted) && !$0.reasons.has(.commandWatch) })
        #expect(next.probes.last?.mode?.mode == .resting)
        #expect(next.traces.values.allSatisfy { $0.phaseTime == nil })
        _ = try next.finish()
    }

    @Test("A live-pipeline clock jump rejects an old asynchronous header without freeing its lane early",
          arguments: [false, true])
    func staleAsyncHeader(forward: Bool) async throws {
        let barrier = ActivityHeaderBarrier()
        let old = forward ? 1.0 : 100.0, new = forward ? 100.0 : 1.0
        let harness = try WatchReproductionHarness(meterFollowsSource: false) { _, time in
            await barrier.read(at: time)
        }
        defer { harness.output.close() }
        let empty = try Frames.recorded("field-00381")
        let maps = try harness.maps(matching: empty)
        try harness.play(empty, at: old, arrival: 1000, waitForText: false)
        await barrier.waitForStart()
        try harness.play(maps[0], at: new, arrival: 1000.05, waitForText: false)
        #expect(harness.output.isReadingText)
        #expect(harness.output.textReadMetrics.submitted == 1)
        await barrier.release()
        try harness.waitForTextReads()
        #expect(harness.output.textReadMetrics.staleCompletions == 1)
        for index in 1...12 {
            try harness.play(maps[(index / 3) % maps.count], at: new + Double(index) / 60,
                             arrival: 1000.05 + Double(index) / 60)
        }
        let rows = try harness.finish()
        #expect(!rows.contains { $0["headerSourceTime"] as? Double == old })
        #expect(harness.probes.filter { $0.time >= new && $0.time < new + 1 }.allSatisfy {
            !$0.reasons.has(.commandWatch) && !$0.reasons.has(.interrupted)
        })
        #expect(harness.traces.values.allSatisfy { $0.phaseTime == nil })
    }
}

private actor ActivityHeaderBarrier {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func read(at time: Double) async -> HeaderReading {
        if !started {
            await withCheckedContinuation { continuation in
                pending = continuation
                started = true
                waiter?.resume(); waiter = nil
            }
            return WatchReproductionHarness.header(.command, at: time)
        }
        return WatchReproductionHarness.header(.unknown, at: time)
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}
