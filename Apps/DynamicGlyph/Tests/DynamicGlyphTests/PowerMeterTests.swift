import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Power meter")
struct PowerMeterTests {
    private static let second: UInt64 = 1_000_000_000

    @Test("The window holds the last 60 seconds; the totals hold everything")
    func rollingWindow() {
        var window = PowerWindow(metrics: 2)
        window.record(0, second: 100)
        window.record(0, count: 2, second: 130)
        window.record(0, second: 159)
        window.record(1, second: 159)
        #expect(window.recent(0, second: 159).count == 4)
        #expect(window.recent(1, second: 159).count == 1)
        // Second 100 falls out once 160 begins.
        #expect(window.recent(0, second: 160).count == 3)
        #expect(window.recent(0, second: 219).count == 0)
        #expect(window.totals[0].count == 4)
    }

    @Test("A reused bucket starts empty, and a record too late for its bucket counts only in the totals")
    func bucketReuse() {
        var window = PowerWindow(metrics: 1)
        window.record(0, nanoseconds: 5, second: 5)
        window.record(0, nanoseconds: 7, second: 65)   // the same slot, a minute on
        #expect(window.recent(0, second: 65) == PowerTally(count: 1, nanoseconds: 7, maxNanoseconds: 7,
                                                            maxAt: 65 * Self.second))
        window.record(0, nanoseconds: 9, second: 125)
        window.record(0, nanoseconds: 1, second: 65)   // late: the slot now holds 125
        #expect(window.recent(0, second: 125) == PowerTally(count: 1, nanoseconds: 9, maxNanoseconds: 9,
                                                             maxAt: 125 * Self.second))
        #expect(window.totals[0] == PowerTally(count: 4, nanoseconds: 22, maxNanoseconds: 9, maxAt: 125 * Self.second))
        // A second that has not happened yet is not in the window.
        #expect(window.recent(0, second: 124).count == 0)
    }

    @Test("Times add up per bucket and the window keeps the largest")
    func tallies() {
        var window = PowerWindow(metrics: 1)
        window.record(0, nanoseconds: 2_000_000, second: 10)
        window.record(0, nanoseconds: 6_000_000, second: 10)
        window.record(0, nanoseconds: 1_000_000, second: 11)
        let recent = window.recent(0, second: 11)
        #expect(recent.count == 3)
        #expect(recent.averageMilliseconds == 3)
        #expect(recent.maxMilliseconds == 6)
        #expect(PowerTally().averageMilliseconds == nil)
    }

    @Test("The span is at most the window and never before the session")
    func span() {
        let s = Self.second
        #expect(PowerWindow.span(now: 30 * s + s / 2, start: 0) == 30.5)
        // Seconds 141...200 are in the window at 200.25 s.
        #expect(PowerWindow.span(now: 200 * s + s / 4, start: 0) == 59.25)
        #expect(PowerWindow.span(now: 200 * s + s / 4, start: 150 * s) == 50.25)
        #expect(PowerWindow.span(now: 10 * s, start: 20 * s) == 0)
        #expect(PowerWindow.perMinute(30, span: 30) == 60)
        #expect(PowerWindow.perMinute(30, span: 0.5) == nil)
    }

    @Test("A cumulative value's rate is taken from the oldest sample in the window")
    func cumulative() {
        let s = Self.second
        var cpu = CumulativeWindow()
        cpu.note(0, at: 0)
        cpu.note(5 * s, at: 10 * s)
        cpu.note(6 * s, at: 10 * s + s / 2)  // the same second: the first sample stays
        #expect(cpu.rate(10 * s, at: 20 * s) == 0.5)
        // At 69 s, second 0 is out; the oldest is at 10 s.
        #expect(cpu.rate(34 * s + s / 2, at: 69 * s) == 0.5)
        // At 70 s both are.
        #expect(cpu.rate(40 * s, at: 70 * s) == nil)
        #expect(CumulativeWindow().rate(1, at: 5 * s) == nil)
    }

    @Test("A session counts from its reset: frames, timings, queue, extension, CPU and heat")
    func meter() {
        let s = Self.second
        let clock = FakeClock()
        clock.now = 1_000 * s
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { clock.thermal })
        meter.count(.framesDelivered)
        meter.noteExtension(published: 50, dropped: 1, overwritten: 0, lost: 0)
        meter.setQueueDepth(9)
        #expect(!meter.snapshot().hasSession)
        #expect(meter.snapshot().total(.framesDelivered).count == 1)

        let languages = GameLanguageMemory(language: .japanese, isAutomatic: false)
        meter.reset(languages: languages)
        #expect(meter.snapshot().total(.framesDelivered).count == 0)
        #expect(meter.snapshot().maxQueueDepth == 0)

        for _ in 0..<30 {
            clock.now += s / 2
            clock.cpu += s / 4
            meter.count(.framesDelivered)
            let started = meter.now()
            clock.now += 2_000_000
            meter.finish(.conversion, since: started)
        }
        meter.count(.framesAnalysed, 10)
        meter.record(PowerMetric(.headerAccurate), nanoseconds: 40_000_000)
        meter.setQueueDepth(3)
        meter.setQueueDepth(1)
        // The first look after the reset only takes the baseline; then
        // growth counts, and a count that went down started over.
        meter.noteExtension(published: 80, dropped: 1, overwritten: 2, lost: 0)
        meter.noteExtension(published: 5, dropped: 0, overwritten: 0, lost: 0)   // a new broadcast
        clock.thermal = ProcessInfo.ThermalState.serious.rawValue
        clock.now += s
        meter.count(.framesDelivered)
        clock.thermal = ProcessInfo.ThermalState.fair.rawValue

        let snapshot = meter.snapshot()
        #expect(snapshot.hasSession)
        #expect(snapshot.total(.framesDelivered).count == 31)
        #expect(snapshot.total(.conversion).count == 30)
        #expect(snapshot.total(.conversion).averageMilliseconds == 2)
        #expect(snapshot.total(.headerAccurate).maxMilliseconds == 40)
        #expect(snapshot.total(.framesAnalysed).count == 10)
        #expect(snapshot.queueDepth == 1 && snapshot.maxQueueDepth == 3 && snapshot.usesQueue)
        #expect(snapshot.total(.extensionPublished).count == 5)
        #expect(snapshot.total(.extensionOverwritten).count == 0)
        #expect(snapshot.total(.extensionDropped).count == 0)
        #expect(snapshot.extensionSeen)
        #expect(snapshot.cpuSeconds == 7.5)
        // 7.5 s of CPU over the 16.06 s since the reset's sample.
        #expect(snapshot.cpuPercentRecent.map { abs($0 - 7.5 / 16.06 * 100) < 0.01 } == true)
        #expect(snapshot.thermal == ProcessInfo.ThermalState.fair.rawValue)
        #expect(snapshot.worstThermal == ProcessInfo.ThermalState.serious.rawValue)
        #expect(snapshot.language == .japanese && !snapshot.languageAutomatic)
        // 31 frames over 16.06 s.
        #expect(snapshot.perMinute(.framesDelivered).map { abs($0 - 31 / 16.06 * 60) < 0.5 } == true)

        // A minute later the window is empty; the session totals are not.
        clock.now += 61 * s
        let later = meter.snapshot()
        #expect(later.recent(.framesDelivered).count == 0)
        #expect(later.total(.framesDelivered).count == 31)
    }

    @Test("Frames the ring published between sessions, or before a new reader, are not counted")
    func extensionBaseline() {
        let clock = FakeClock()
        clock.now = 100 * Self.second
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { 0 })
        meter.reset()
        meter.noteExtension(published: 100, dropped: 0, overwritten: 0, lost: 0)
        meter.noteExtension(published: 160, dropped: 0, overwritten: 0, lost: 3)
        #expect(meter.snapshot().total(.extensionPublished).count == 60)
        meter.end()
        // The broadcast went on between the sessions.
        clock.now += 30 * Self.second
        meter.noteExtension(published: 900, dropped: 0, overwritten: 0, lost: 3)
        meter.reset()
        meter.noteExtension(published: 1_500, dropped: 2, overwritten: 0, lost: 3)
        #expect(meter.snapshot().total(.extensionPublished).count == 0)
        meter.noteExtension(published: 1_520, dropped: 2, overwritten: 0, lost: 3)
        #expect(meter.snapshot().total(.extensionPublished).count == 20)
        // A new reader counts its losses from zero; the producer's go on.
        meter.restartExtensionCounts()
        meter.noteExtension(published: 1_530, dropped: 2, overwritten: 0, lost: 0)
        meter.noteExtension(published: 1_535, dropped: 2, overwritten: 0, lost: 1)
        let snapshot = meter.snapshot()
        #expect(snapshot.total(.extensionPublished).count == 25)
        #expect(snapshot.total(.ringLost).count == 1)
        #expect(snapshot.total(.extensionDropped).count == 0)
    }

    @Test("Stop freezes the session; work begun before a reset is not counted")
    func frozenAfterStop() {
        let s = Self.second
        let clock = FakeClock()
        clock.now = 1_000 * s
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { 0 })
        meter.reset()
        clock.now += 20 * s
        clock.cpu += 4 * s
        meter.count(.framesDelivered, 100)
        meter.end()
        let atStop = meter.snapshot()
        #expect(atStop.ended)
        #expect(atStop.elapsed == 20)
        #expect(atStop.cpuSeconds == 4)
        #expect(atStop.cpuPercentRecent.map { abs($0 - 20) < 1e-9 } == true)

        clock.now += 30 * s
        clock.cpu += 9 * s
        meter.count(.framesDelivered)
        meter.record(.headerFast, nanoseconds: 1_000_000)
        meter.setQueueDepth(0)
        let later = meter.snapshot()
        #expect(later.elapsed == 20 && later.cpuSeconds == 4)
        #expect(later.cpuPercentRecent == atStop.cpuPercentRecent)
        #expect(later.total(.framesDelivered).count == 100 && later.recent(.framesDelivered).count == 100)
        #expect(later.total(.headerFast).count == 0)
        #expect(PowerReport.lines(later).first?.hasPrefix("stopped 0:20") == true)

        // A read that began before the next session's reset belongs to the last.
        meter.reset()
        clock.now += s
        meter.record(.headerFast, nanoseconds: 2 * s)
        let started = meter.now() - s / 2
        meter.finish(.conversion, since: started)
        let next = meter.snapshot()
        #expect(!next.ended)
        #expect(next.total(.headerFast).count == 0)
        #expect(next.total(.conversion).count == 1)
        #expect(next.total(.framesDelivered).count == 0)
    }

    @Test("Each metric's longest run keeps when it ended, in session time")
    func maximumTimes() {
        let s = Self.second
        let clock = FakeClock()
        clock.now = 1_000 * s
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { 0 })
        meter.reset()
        clock.now += 10 * s
        meter.record(.droneFooter, nanoseconds: 72_000_000)
        clock.now += 124 * s   // 2:14 into the session
        meter.record(.droneFooter, nanoseconds: 760_000_000)
        clock.now += 30 * s
        meter.record(.droneFooter, nanoseconds: 80_000_000)   // longer than the first, not the longest
        var started = meter.now()
        clock.now += 3_000_000
        meter.finish(.gearCheck, since: started)
        started = meter.now()
        clock.now += 1_000_000
        meter.finish(.gearCheck, since: started)
        let snapshot = meter.snapshot()
        #expect(snapshot.maxAt(.droneFooter) == 134)
        #expect(snapshot.total(.droneFooter).maxMilliseconds == 760)
        #expect(snapshot.maxAt(.gearCheck).map { abs($0 - 164.003) < 1e-6 } == true)
        #expect(snapshot.maxAt(.headerFast) == nil)
        let lines = PowerReport.lines(snapshot)
        #expect(lines.contains(PowerReport.row("drone foot.", "760", "2:14")))
        #expect(lines.contains(PowerReport.row("gear check", "3.00", "2:44")))
        #expect(PowerReport.clock(5_999) == "99:59" && PowerReport.clock(6_000) == "100m" && PowerReport.clock(nil) == "-")
        // A merge keeps the longest run's time.
        var a = PowerTally(), b = PowerTally()
        a.add(count: 1, nanoseconds: 5, at: 10)
        b.add(count: 1, nanoseconds: 9, at: 20)
        b.add(count: 1, nanoseconds: 9, at: 30)   // as long, later: the first stays
        a.merge(b)
        #expect(a.maxNanoseconds == 9 && a.maxAt == 20)
    }

    @Test("Untimed CPU is the CPU time less the timed work that never overlaps")
    func untimed() {
        let s = Self.second
        let clock = FakeClock()
        clock.now = 50 * s
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { 0 })
        meter.reset()
        clock.now += 100 * s
        clock.cpu += 95 * s
        meter.record(.frameWork, nanoseconds: 40 * s)
        meter.record(.conversion, nanoseconds: 10 * s)       // inside the frame's work: not again
        meter.record(.skippedFrame, nanoseconds: 5 * s)
        meter.record(.frameIntake, nanoseconds: 1 * s)
        meter.record(.pipTick, nanoseconds: 6 * s)
        meter.record(.pipDraw, nanoseconds: 4 * s)           // inside the ticks
        meter.record(.displayUpdate, nanoseconds: 2 * s)
        meter.record(.liveActivity, nanoseconds: 1 * s)      // inside the display update
        meter.record(.telemetryRow, nanoseconds: 1 * s)
        meter.record(.droneFooter, nanoseconds: 3 * s)
        meter.record(.droneFooterFast, nanoseconds: 1 * s)
        let snapshot = meter.snapshot()
        #expect(abs(snapshot.timedSeconds - 59) < 1e-9)
        let lines = PowerReport.lines(snapshot)
        #expect(lines.contains("timed 59.0 s · untimed 36.0 s"))
        for metric in [PowerMetric.skippedFrame, .frameIntake, .pipTick, .pipDraw, .displayUpdate, .liveActivity,
                       .telemetryRow] {
            #expect(lines.contains { $0.hasPrefix(metric.label) }, "\(metric.label) has a step row")
        }
        #expect(lines.allSatisfy { $0.count <= 42 })
        // Every metric is in exactly one place in the report, and the top
        // level holds no step that runs inside another.
        #expect(Set(PowerMetric.topLevel).isSubset(of: Set(PowerMetric.textReads + PowerMetric.steps)))
        #expect(!PowerMetric.topLevel.contains(.conversion) && !PowerMetric.topLevel.contains(.pipDraw)
                && !PowerMetric.topLevel.contains(.liveActivity))
        #expect(Set(PowerMetric.allCases.map { $0.label }).count == PowerMetric.allCases.count)
        #expect(PowerMetric.allCases.allSatisfy { $0.label.count <= 12 })
        // One column is the latest-input star.
        #expect(AnalysisGateReason.allCases.allSatisfy { $0.label.count <= 11 })
    }

    @Test("Gate inputs overlap, accrue bounded source time, and count real samples separately from looks")
    func gateOccupancy() throws {
        let dark = try #require(LumaGate().read(width: 32, height: 64, luma: { _, _ in 0 }))
        var stats = AnalysisGateOccupancy()
        var reasons = AnalysisGateReasons(.resultContext)
        reasons.set(.slots, true)
        stats.note(reasons, at: 10, still: false, gate: dark)
        stats.analyzed(.active)
        stats.note(reasons, at: 10.5, still: true, gate: nil)
        stats.note(AnalysisGateReasons(.resultContext), at: 11, still: true, gate: nil)
        stats.note([], at: 30, still: true, gate: nil) // paused gap: at most two seconds
        stats.note([], at: 5, still: false, gate: nil) // restarted source clock: no negative time
        stats.analyzed(.quiet)
        #expect(stats.looks == 5 && stats.stillLooks == 3)
        #expect(stats.counts[AnalysisGateReason.resultContext.rawValue] == 3)
        #expect(stats.seconds[AnalysisGateReason.resultContext.rawValue] == 3)
        #expect(stats.seconds[AnalysisGateReason.slots.rawValue] == 1)
        #expect(stats.samples == [1, 0, 1])
        #expect(stats.dark == 1 && stats.bright == 0, "still looks retain only scalar luma statistics")
        #expect(stats.minimumDark == 1 && stats.maximumDark == 1)
        #expect(stats.current.isEmpty)
        let lines = PowerReport.gateLines(stats)
        #expect(lines.contains("gate looks 5 · still 3"))
        #expect(lines.contains { $0.contains("result ctx") })
        #expect(lines.allSatisfy { $0.count <= 42 })
    }

    @Test("The copied Power report keeps gate reasons and samples at Stop, and clears them at Start")
    func gateReportLifecycle() throws {
        let clock = FakeClock()
        clock.now = 100 * Self.second
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        var reasons = AnalysisGateReasons()
        for reason in AnalysisGateReason.allCases { reasons.set(reason, true) }
        let mode = ReadingMode(mode: .active, interval: 0.049, powerSaving: true, inHack: false)
        meter.noteAnalysisMode(.active, at: 0, current: mode, reasons: reasons)
        meter.count(.framesAnalysed)
        meter.noteAnalysisSample(.active)
        clock.now += Self.second
        meter.noteAnalysisMode(.active, at: 1, current: mode, reasons: reasons, still: true)
        let snapshot = meter.snapshot()
        #expect(snapshot.analysedLastSecond == 1)
        #expect(snapshot.gateOccupancy.samples == [0, 0, 1])
        let lines = PowerReport.lines(snapshot)
        for reason in AnalysisGateReason.allCases {
            #expect(lines.contains { $0.hasPrefix("*" + reason.label) })
        }
        #expect(lines.contains { $0.contains("20/s · last s 1") }, "a cap is not a measured rate")
        #expect(lines.allSatisfy { $0.count <= 42 })
        meter.end()
        meter.noteAnalysisMode(.quiet, at: 2, reasons: [])
        meter.noteAnalysisSample(.quiet)
        #expect(meter.snapshot().gateOccupancy.looks == 2)
        #expect(meter.snapshot().gateOccupancy.samples == [0, 0, 1])
        meter.reset()
        #expect(meter.snapshot().gateOccupancy.looks == 0)
        #expect(meter.snapshot().gateOccupancy.samples == [0, 0, 0])
        #expect(PowerReport.gateLines(meter.snapshot().gateOccupancy).isEmpty)
    }

    @Test("Header admission and unchanged-skip counts are separate from OCR timing")
    func headerWorkCounts() {
        let meter = PowerMeter()
        meter.reset()
        meter.count(.headerInHack, 3)
        meter.count(.headerOutside, 2)
        meter.count(.headerUnchanged, 4)
        let snapshot = meter.snapshot(), lines = PowerReport.lines(snapshot)
        #expect(snapshot.total(.headerInHack).count == 3)
        #expect(snapshot.total(.headerOutside).count == 2)
        #expect(snapshot.total(.headerUnchanged).count == 4)
        #expect(snapshot.timedSeconds == 0)
        for metric in PowerMetric.headerWork {
            #expect(metric.label.count <= 11)
            #expect(lines.contains { $0.hasPrefix(metric.label) })
            #expect(!PowerMetric.topLevel.contains(metric))
        }
        #expect(lines.allSatisfy { $0.count <= 42 })
        meter.reset()
        #expect(meter.snapshot().total(.headerUnchanged).count == 0)
    }

    @Test("Every text read kind has its own row")
    func textKinds() {
        let metrics = TextReadKind.allCases.map { PowerMetric($0) }
        #expect(Set(metrics).count == TextReadKind.allCases.count)
        #expect(Set(metrics) == Set(PowerMetric.textReads))
    }

    @Test("The report's table rows fit a phone screen")
    func report() {
        let clock = FakeClock()
        clock.now = 500 * Self.second
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { clock.cpu }, thermalState: { 0 })
        #expect(PowerReport.lines(meter.snapshot()).count == 1)
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: true))
        meter.count(.framesDelivered, 1_200_000)
        meter.count(.framesAnalysed, 400_000)
        clock.now += Self.second   // a run that began after the reset
        meter.record(.slotStrip, nanoseconds: 123_456_789)
        meter.setQueueDepth(40)
        meter.noteExtension(published: 1_200_000, dropped: 0, overwritten: 0, lost: 0)
        clock.now += 300 * Self.second
        let lines = PowerReport.lines(meter.snapshot())
        #expect(lines.contains("queue now 40 · max 40 of 40"))
        #expect(lines.contains("game language en (auto, guess)"))
        #expect(lines.contains("header OCR fast en-US"))
        #expect(lines.contains { $0.hasPrefix("slot strip") })
        #expect(!lines.contains { $0.hasPrefix("grid hunt") })   // never ran
        #expect(lines.allSatisfy { $0.count <= 42 })
        // The longest language lines, for every game language.
        for language in GameLanguage.allCases {
            var snapshot = meter.snapshot()
            snapshot.language = language
            snapshot.languageAutomatic = true
            snapshot.languageConfirmed = false
            let languageLines = PowerReport.lines(snapshot).filter { $0.hasPrefix("game") || $0.hasPrefix("header OCR") }
            #expect(languageLines.count == 2 && languageLines.allSatisfy { $0.count <= 42 })
        }
    }
}

private final class FakeClock: @unchecked Sendable {
    var now: UInt64 = 0
    var cpu: UInt64 = 0
    var thermal = 0
}
