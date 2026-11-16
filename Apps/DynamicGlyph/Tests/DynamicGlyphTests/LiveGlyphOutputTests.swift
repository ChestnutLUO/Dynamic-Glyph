import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages
import ImageIO
import Testing
import VideoToolbox

@Suite("Callback gap monitor")
struct CallbackGapMonitorTests {
    @Test("The first callback has no gap and breaks nothing")
    func first() {
        var monitor = CallbackGapMonitor()
        #expect(monitor.arrive(at: 50) == .init(gapMilliseconds: nil, continuityBroken: false))
    }

    @Test("Only a pause longer than a second breaks continuity")
    func threshold() {
        var monitor = CallbackGapMonitor()
        _ = monitor.arrive(at: 10)
        let steady = monitor.arrive(at: 10.5)
        #expect(steady.gapMilliseconds == 500)
        #expect(!steady.continuityBroken)
        #expect(!monitor.arrive(at: 11.5).continuityBroken)
        let stalled = monitor.arrive(at: 12.75)
        #expect(stalled.gapMilliseconds == 1250)
        #expect(stalled.continuityBroken)
        #expect(!monitor.arrive(at: 12.8).continuityBroken)
    }
}

/// The recognition entry point every capture source feeds, driven by
/// synthetic and recorded frames instead of ScreenCaptureKit.
@Suite("Recognition entry point")
struct LiveGlyphOutputTests {
    @Test("A recorded 420f frame of the empty array yields the node fit and the colour slot reading")
    func recordedEmptyArray() throws {
        let harness = try Harness()
        harness.output.process(try harness.frame(try Frames.recorded("field-00456"), at: 100))
        let rows = try harness.finish()
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row["captureStatus"] as? String == "complete")
        #expect(row["pixelFormat"] as? String == "420f")
        #expect(row["width"] as? Int == 603 && row["height"] as? Int == 1311)
        #expect(row["state"] as? String == "noStroke")
        let calibration = try #require(row["calibration"] as? [String: Any])
        #expect(calibration["matchedNodes"] as? Int == 11)
        #expect(row["slotCount"] as? Int == 4)
        #expect(row["slotHighlight"] as? Int == 1)
        #expect(row["error"] == nil)
    }

    @Test("A frame with a stroke drawn is read for its slots but never becomes the node fit")
    func recordedStroke() throws {
        let harness = try Harness()
        harness.output.process(try harness.frame(try Frames.recorded("field-00443"), at: 100))
        let row = try #require(try harness.finish().first)
        #expect(row["state"] as? String == "waitingForEmptyArray")
        #expect(row["calibration"] == nil)
        #expect(row["slotCount"] as? Int == 4)
        #expect(row["slotHighlight"] as? Int == 0)
    }

    @Test("Statuses other than complete are logged by name and never analyzed")
    func statuses() throws {
        let harness = try Harness()
        let statuses: [CaptureFrameStatus] = [.idle, .blank, .suspended, .started, .stopped, .unknown]
        for (index, status) in statuses.enumerated() {
            harness.output.process(try harness.frame(try Frames.recorded(), status: status, at: Double(index)))
        }
        let rows = try harness.finish()
        #expect(rows.map { $0["captureStatus"] as? String } == statuses.map(\.rawValue))
        #expect(rows.map { $0["state"] as? String } == statuses.map { "capture_\($0.rawValue)" })
        #expect(rows.allSatisfy { $0["calibration"] == nil && $0["slotCount"] == nil })
    }

    @Test("Landscape buffers and rotated frames are rejected; an upright tag is not")
    func orientation() throws {
        let harness = try Harness()
        harness.output.process(try harness.frame(try Frames.solid(width: 1311, height: 603), at: 0))
        harness.output.process(try harness.frame(try Frames.solid(), orientation: 6, at: 1))
        harness.output.process(try harness.frame(try Frames.solid(), orientation: 1, at: 2))
        let states = try harness.finish().map { $0["state"] as? String }
        #expect(states == ["unsupportedOrientation", "unsupportedOrientation", "waitingForEmptyArray"])
    }

    @Test("Frames are analyzed at 20 Hz by presentation time, and a restarted clock is followed")
    func sampling() throws {
        let harness = try Harness()
        let buffer = try Frames.solid()
        for index in 0..<60 { harness.output.process(try harness.frame(buffer, at: 100 + Double(index) / 60)) }
        harness.output.process(try harness.frame(buffer, at: 5))
        let times = try harness.finish().compactMap { $0["presentationTime"] as? Double }
        #expect(times.count == 21)
        #expect(times.last == 5)
        #expect(zip(times.dropLast(), times.dropFirst().dropLast()).allSatisfy { $1 - $0 >= 0.049 })
    }

    @Test("The source's delivery gap and arrival time are carried through unchanged")
    func deliveryTiming() throws {
        let harness = try Harness()
        let buffer = try Frames.solid()
        harness.output.process(try harness.frame(buffer, at: 0, arrival: 40))
        harness.output.process(try harness.frame(buffer, at: 1, arrival: 41.25, gap: 1250, broken: true))
        let rows = try harness.finish()
        #expect(rows[0]["callbackGapMilliseconds"] == nil)
        #expect(rows[1]["callbackGapMilliseconds"] as? Double == 1250)
        let snapshots = harness.updates.values.map(\.snapshot)
        #expect(snapshots.map(\.sourceFrameTime) == [0, 1])
        #expect(snapshots.map(\.evidenceArrivalUptime) == [40, 41.25])
    }

    @Test("Time spent waiting before recognition is logged apart from recognition's own")
    func queueTime() throws {
        let harness = try Harness()
        let waited = ProcessInfo.processInfo.systemUptime - 2
        harness.output.process(try harness.frame(try Frames.solid(), at: 0, arrival: waited))
        let row = try #require(try harness.finish().first)
        #expect((row["queueMilliseconds"] as? Double ?? 0) >= 2000)
        #expect((row["processingMilliseconds"] as? Double ?? .infinity) < 2000)
    }

    @Test("Every callback gets a telemetry row; a picture only for complete frames, five seconds apart")
    func telemetry() throws {
        let harness = try Harness()
        let buffer = try Frames.solid()
        let frames: [(Double, CaptureFrameStatus)] = [(0, .idle), (0.01, .complete), (0.02, .complete),
                                                      (4.9, .complete), (5.01, .idle), (5.02, .complete)]
        for (time, status) in frames { harness.output.process(try harness.frame(buffer, status: status, at: time)) }
        _ = try harness.finish()
        let rows = harness.telemetry.values
        #expect(rows.map(\.index) == Array(0..<6))
        #expect(rows.map(\.facts.status) == frames.map(\.1))
        #expect(rows.map { $0.buffer != nil } == [false, true, false, false, false, true])
    }

    @Test("Without session logs nothing is written or described, but the display is still fed")
    func withoutLogs() throws {
        let harness = try Harness(keepsLogs: false)
        harness.output.process(try harness.frame(try Frames.recorded(), at: 0))
        harness.output.close()
        #expect(harness.telemetry.values.isEmpty)
        #expect(harness.updates.values.count == 1)
        #expect(harness.updates.values.allSatisfy { $0.diagnostics == nil })
    }

    @Test("Gear is read without session logs, and logged only with them")
    func gearWithoutLogs() throws {
        let unlogged = try Harness(keepsLogs: false, readsResults: true, readsGear: true)
        #expect(unlogged.output.readsGear)
        unlogged.output.process(try unlogged.frame(try Frames.recorded(), at: 0))
        unlogged.output.close()
        #expect(unlogged.updates.values.count == 1)
        let logged = try Harness(keepsLogs: true, readsResults: true, readsGear: true)
        logged.output.close()
        let folder = try #require(logged.directory?.url)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("gear-drops.jsonl").path))
        // Gear needs each hack's result, so it isn't read without results.
        #expect(try !Harness(keepsLogs: false, readsResults: false, readsGear: true).output.readsGear)
    }

    /// Gear-only capture on the harness's Swift arm, or on what a capture runs
    /// for a player who never chose: the default engine, cuts and logic, made
    /// as `CaptureEngine` makes them.
    private static func gearOnlyHarness(keepsLogs: Bool, onDefaults: Bool) throws -> Harness {
        guard onDefaults else { return try Harness(keepsLogs: keepsLogs, assistsGlyphs: false) }
        let cuts = AppPreferences.defaultRecognitionCuts
        let setup = makeRecognitionEngine(choice: AppPreferences.defaultRecognitionEngine, table: nil, cuts: cuts)
        #expect(setup.engine.name == "cpp" && setup.fallback == nil && setup.cuts == cuts)
        return try Harness(keepsLogs: keepsLogs, assistsGlyphs: false, engine: setup.engine, cuts: setup.cuts,
                           logic: AppPreferences.defaultRecognitionLogic)
    }

    @Test("Without a shape list only gear is read, whatever the result switches say, on Swift and on the defaults",
          arguments: [false, true])
    func gearOnlySwitches(onDefaults: Bool) throws {
        let harness = try Self.gearOnlyHarness(keepsLogs: false, onDefaults: onDefaults)
        #expect(!harness.output.assistsGlyphs && harness.output.readsGear)
        // A Glyph on screen is not looked for: the display only watches for gear.
        harness.output.process(try harness.frame(try Frames.recorded(), at: 0))
        harness.output.close()
        let snapshot = try #require(harness.updates.values.last?.snapshot)
        #expect(snapshot.slots.isEmpty && snapshot.provisionalGlyph == nil)
        #expect(snapshot.gear == GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
    }

    @Test("Gear-only capture saves a drop group with what its panel showed, on Swift and on the defaults",
          arguments: [false, true])
    func gearOnlyDrop(onDefaults: Bool) throws {
        let harness = try Self.gearOnlyHarness(keepsLogs: true, onDefaults: onDefaults)
        let panel = try Frames.recorded("five-base")
        let blank = try Frames.solid(width: CVPixelBufferGetWidth(panel), height: CVPixelBufferGetHeight(panel))
        // Text recognition runs on its own queue. Each frame waits for its
        // read to finish, however long the machine takes, so reads land at
        // the frames' times as they would on a phone keeping up.
        var time = 0.0
        for _ in 0..<20 {
            harness.output.process(try harness.frame(panel, at: time))
            try harness.waitForTextReads()
            time += 0.1
        }
        for _ in 0..<6 {
            harness.output.process(try harness.frame(blank, at: time))
            try harness.waitForTextReads()
            time += 0.1
        }
        harness.output.close()
        let drops = harness.drops.values
        #expect(drops.count == 1)
        let drop = try #require(drops.first)
        #expect(drop.summary.hackID == nil && drop.summary.association == .noWaitingHack)
        let items = drop.summary.panels.flatMap(\.entries).map { "\($0.item ?? "?") ×\($0.quantity)" }
        #expect(items.sorted() == ["Resonator ×1", "Turret ×1"])
        #expect(drop.summary.panelsReadInFull)
        #expect(drop.sessionFolder == harness.directory?.url.lastPathComponent, "A report finds its logs through it")
        #expect(harness.results.values.isEmpty, "No hack result is read without Glyph assistance")
        let log = try String(contentsOf: try #require(harness.directory).url.appendingPathComponent("gear-drops.jsonl"),
                             encoding: .utf8)
        #expect(log.contains("\"kind\":\"group\""))
    }

    @Test("On the map analysis rests at 4 Hz with no array search or header read; a hack frame wakes it at once")
    func quietMap() throws {
        let harness = try Harness()
        let map = try Frames.recorded("frame-02092", ext: "jpg"), hack = try Frames.recorded("field-00443")
        // 30 Hz, as a broadcast delivers: four seconds of map, then the hack.
        for index in 0..<120 { harness.output.process(try harness.frame(map, at: Double(index) / 30)) }
        for index in 120..<135 { harness.output.process(try harness.frame(hack, at: Double(index) / 30)) }
        let rows = try harness.finish()
        func time(_ row: [String: Any]) -> Double { row["presentationTime"] as? Double ?? -1 }
        let mapRows = rows.filter { time($0) < 3.99 }, hackRows = rows.filter { time($0) >= 3.99 }
        let rested = mapRows.filter { time($0) >= 2.1 }
        #expect(mapRows.filter { time($0) < 2 }.allSatisfy { $0["analysisMode"] as? String == "active" })
        #expect(!rested.isEmpty && rested.allSatisfy {
            $0["analysisMode"] as? String == "quiet" && $0["state"] as? String == "quietScreen" && $0["calibration"] == nil
        })
        #expect(zip(rested, rested.dropFirst()).allSatisfy { time($1) - time($0) >= 0.249 })
        #expect(rested.count <= 8, "about 4 Hz for two seconds: \(rested.count)")
        let headers = Set(rested.compactMap { $0["headerSubmitted"] as? Int })
        #expect(headers.count == 1, "no header read while quiet: \(headers)")
        // The first hack frame is analyzed, fully, and every one at 20 Hz after it.
        let first = try #require(hackRows.first)
        #expect(abs(time(first) - 4) < 0.001)
        #expect(first["analysisMode"] as? String == "active" && first["state"] as? String != "quietScreen")
        #expect(hackRows.count >= 7)
        #expect(hackRows.allSatisfy { $0["slotCount"] as? Int == 4 })
    }

    @Test("At 60-Hz delivery, stable and moving maps really sample at 4 Hz (2 constrained), not just show Idle",
          arguments: [false, true], [false, true])
    func mapRateAndReasons60Hz(moving: Bool, lowPower: Bool) throws {
        let clock = ReplayMeterClock(), signal = ReadingModeSignal()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let harness = try Harness(keepsLogs: false, power: .init(lowPowerMode: lowPower), readingMode: signal, meter: meter)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        let other = try Frames.shiftedMap()
        let first = try #require(LumaGate().read(map)), second = try #require(LumaGate().read(other))
        #expect(!first.isCandidate && !second.isCandidate)
        #expect(first.difference(from: second) > AnalysisRateController.Policy().changeThreshold,
                "the moving-map case must actually change the gate's pixels")
        for index in 0..<420 {
            let time = Double(index) / 60
            clock.set(time)
            // Change every gate look, not every third look aliasing the same map.
            let buffer = moving && (index / 3) % 2 == 1 ? other : map
            harness.output.process(try harness.frame(buffer, at: time, arrival: 100 + time))
        }
        let snapshot = meter.snapshot()
        #expect(signal.tint == (lowPower ? .backingOff : .idle))
        #expect(snapshot.readingMode?.mode == .quiet)
        #expect(snapshot.readingMode?.ratePerSecond == (lowPower ? 2 : 4))
        #expect(snapshot.analysedLastSecond == (lowPower ? 2 : 4), "actual output samples, not an interval estimate")
        #expect(snapshot.total(.framesAnalysed).count == UInt64(harness.updates.values.count))
        #expect(snapshot.gateOccupancy.samples.reduce(0, +) == snapshot.total(.framesAnalysed).count)
        #expect(snapshot.gateOccupancy.samples[0] > 0)
        for reason in AnalysisGateReason.allCases {
            #expect(snapshot.gateOccupancy.counts[reason.rawValue] == 0,
                    "map alone must not invent candidate/busy/hack evidence: \(reason.label)")
        }
        #expect(PowerReport.lines(snapshot).contains { $0.contains("last s \(lowPower ? 2 : 4)") })
        harness.output.close()
    }

    @Test("An uncertain result behind a covered map retains ownership but cannot alone pin 20 Hz")
    func retainedResultDoesNotPinRate() throws {
        let clock = ReplayMeterClock(), signal = ReadingModeSignal()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let harness = try Harness(readsResults: true, readingMode: signal, meter: meter)
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        let input = try Frames.recorded("field-00492")
        let map = try Frames.coveredMap()
        let script: [(CVPixelBuffer, Int)] = [(empty, 60), (glyph, 60), (input, 60), (map, 720)]
        var index = 0
        for (buffer, count) in script {
            for _ in 0..<count {
                let time = Double(index) / 60
                clock.set(time)
                harness.output.process(try harness.frame(buffer, at: time, arrival: 100 + time))
                try harness.waitForTextReads()
                index += 1
            }
            if buffer === input {
                #expect(meter.snapshot().gateOccupancy.current.has(.resultContext), "fixture must reach input and open a result")
                #expect(signal.tint == .reading)
            }
        }
        let snapshot = meter.snapshot()
        #expect(snapshot.gateOccupancy.current.has(.resultContext), "uncertainty is preserved; no power timeout closes it")
        #expect(!snapshot.gateOccupancy.current.has(.slots) && !snapshot.gateOccupancy.current.has(.timer))
        #expect(!snapshot.gateOccupancy.current.has(.commandWatch))
        #expect(signal.tint == .idle && snapshot.readingMode?.mode == .quiet)
        #expect(snapshot.analysedLastSecond == 4, "before the fix retained context alone kept this at 20")
        let rows = try harness.finish()
        let mapRows = rows.filter { ($0["presentationTime"] as? Double ?? -1) >= 3 }
        #expect(mapRows.allSatisfy { $0["slotRejection"] as? String == "coveredByOverlay" },
                "no positive noMarkers exit is allowed to hide the retained-context regression")
        let tail = mapRows.filter { ($0["presentationTime"] as? Double ?? -1) >= 13 }
        #expect(tail.count == 8 && tail.allSatisfy { $0["analysisMode"] as? String == "quiet" })
    }

    @Test("Gear bounds, an open group and its observer release full speed after the panel closes at 60 Hz")
    func gearPanelCloses60Hz() throws {
        let clock = ReplayMeterClock(), signal = ReadingModeSignal()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let harness = try Harness(keepsLogs: false, assistsGlyphs: false, readingMode: signal, meter: meter)
        let panel = try Frames.recorded("five-base"), map = try Frames.recorded("frame-02092", ext: "jpg")
        // Panel, its 0.15-s release, then two quiet seconds and a whole measured one.
        for index in 0..<480 {
            let time = Double(index) / 60
            clock.set(time)
            harness.output.process(try harness.frame(index < 120 ? panel : map, at: time, arrival: 100 + time))
            try harness.waitForTextReads()
            if index == 119 {
                let open = meter.snapshot()
                #expect(signal.tint == .reading)
                #expect(open.analysedLastSecond == 20)
                #expect(open.gateOccupancy.current.has(.gearPanel))
                #expect(open.gateOccupancy.current.has(.gearObserver) && open.gateOccupancy.current.has(.gearGroup))
            }
        }
        let closed = meter.snapshot()
        #expect(signal.tint == .idle && closed.analysedLastSecond == 4)
        for reason in [AnalysisGateReason.gearPanel, .gearGroup, .gearObserver] {
            #expect(!closed.gateOccupancy.current.has(reason))
            #expect(closed.gateOccupancy.counts[reason.rawValue] > 0)
        }
        harness.output.close()
        #expect(harness.drops.values.count == 1)
    }

    @Test("A quick first Glyph and its 100-ms blank get the same samples at 60 Hz with saving on and off")
    func quickFirstGlyph60Hz() throws {
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        let script: [(CVPixelBuffer, Int)] = [(map, 180), (empty, 6), (glyph, 6), (empty, 6), (glyph, 6), (empty, 12)]
        func normalRun(_ saving: Bool) throws -> [[String: Any]] {
            let harness = try Harness(powerSaving: saving)
            var index = 0
            for (buffer, count) in script {
                for _ in 0..<count {
                    harness.output.process(try harness.frame(buffer, at: Double(index) / 60))
                    index += 1
                }
            }
            return try harness.finish().filter { ($0["presentationTime"] as? Double ?? -1) >= 3 }
        }
        let saving = try normalRun(true), baseline = try normalRun(false)
        func signature(_ row: [String: Any]) -> String {
            ["presentationTime", "state", "edges", "slotCount", "slotHighlight", "inputTimerVisible"]
                .map { "\(row[$0] ?? "-")" }.joined(separator: "|") + "|\(row["calibration"] != nil)"
        }
        #expect(saving.map(signature) == baseline.map(signature))
        #expect(saving.count == 12)
        #expect(saving.allSatisfy { $0["analysisMode"] as? String == "active" && $0["calibration"] != nil })
        let firstGlyph = try #require(saving.first { ($0["presentationTime"] as? Double ?? -1) >= 3.1 })
        #expect(abs((firstGlyph["presentationTime"] as? Double ?? 0) - 3.1) < 0.001)
        #expect(firstGlyph["state"] as? String != "noStroke")
    }

    @Test("Low Power Mode halves gear-panel OCR, gear-only and beside Glyph reading", arguments: [false, true])
    func lowPowerHalvesGearReads(gearOnly: Bool) throws {
        let panel = try Frames.recorded("five-base")
        func gearReads(lowPower: Bool) throws -> Int {
            let harness = try Harness(keepsLogs: false, readsResults: !gearOnly, readsGear: !gearOnly,
                                      assistsGlyphs: !gearOnly, power: .init(lowPowerMode: lowPower))
            for index in 0..<240 {
                harness.output.process(try harness.frame(panel, at: Double(index) / 60))
                try harness.waitForTextReads()
            }
            defer { harness.output.close() }
            return harness.output.textReadMetrics.gearSubmitted
        }
        let normal = try gearReads(lowPower: false), constrained = try gearReads(lowPower: true)
        // 4 s of panel: a read every 0.2 s normally, every 0.4 s in Low Power Mode.
        #expect(normal >= 15, "the panel must actually be read: \(normal)")
        #expect(constrained >= 7, "Low Power Mode still reads the panel: \(constrained)")
        #expect(constrained * 2 <= normal + 2, "normal \(normal), Low Power Mode \(constrained)")
    }

    @Test("A dark map that changes on every look settles to 4 Hz within the settle time and stays there, header at 2 Hz")
    func nightMapSettles() throws {
        let signal = ReadingModeSignal()
        let harness = try Harness(readingMode: signal, meter: Self.meter())
        let phases = try (0..<4).map { try Frames.nightMap(phase: $0) }
        let readings = try phases.map { try #require(LumaGate().read($0)) }
        #expect(readings.allSatisfy { $0.isCandidate }, "dim, as the field's map at night")
        let threshold = AnalysisRateController.Policy().changeThreshold
        #expect(readings[0].difference(from: readings[2]) > threshold && readings[1].difference(from: readings[3]) > threshold,
                "every 20-Hz look sees a changed screen")
        // 30 Hz for eight seconds: the 20-Hz looks take every other frame.
        for index in 0..<240 {
            harness.output.process(try harness.frame(phases[index % 4], at: Double(index) / 30))
            try harness.waitForTextReads()
        }
        #expect(signal.tint == .waiting)
        let rows = try harness.finish()
        func time(_ row: [String: Any]) -> Double { row["presentationTime"] as? Double ?? -1 }
        #expect(rows.filter { time($0) < 1.99 }.allSatisfy { $0["analysisMode"] as? String == "active" })
        let settled = rows.filter { time($0) >= 1.99 }
        // Resting, not quiet: each slow look still searches for the array and
        // reads the header, so a hack screen is found; none is invented here.
        #expect(!settled.isEmpty && settled.allSatisfy {
            $0["analysisMode"] as? String == "resting" && $0["state"] as? String != "quietScreen"
                && $0["calibration"] == nil && $0["slotCount"] == nil
        })
        #expect(zip(settled, settled.dropFirst()).allSatisfy { time($1) - time($0) >= 0.249 })
        #expect((20...25).contains(settled.count), "about 4 Hz for six seconds: \(settled.count)")
        let first = try #require(settled.first?["headerSubmitted"] as? Int)
        let last = try #require(settled.last?["headerSubmitted"] as? Int)
        #expect(last > first, "the header is still read: a command channel must be seen")
        #expect(last - first <= 13, "at most twice a second: \(last - first)")
    }

    @Test("On the settled night map, a hack screen is analysed within one slow interval and its evidence restores 20 Hz on the next look",
          arguments: ["field-00381", "field-00456", "field-00443", "field-00492"])
    func evidenceWakesFromNightMap(_ name: String) throws {
        let harness = try Harness()
        let phases = try (0..<4).map { try Frames.nightMap(phase: $0) }
        let hack = try Frames.recorded(name)
        // A candidate after a candidate: no entry look helps here, as on the field's map.
        #expect(try #require(LumaGate().read(hack)).isCandidate)
        for index in 0..<120 { harness.output.process(try harness.frame(phases[index % 4], at: Double(index) / 30)) }
        for index in 120..<150 { harness.output.process(try harness.frame(hack, at: Double(index) / 30)) }
        let rows = try harness.finish()
        func time(_ row: [String: Any]) -> Double { row["presentationTime"] as? Double ?? -1 }
        let map = rows.filter { time($0) >= 2.2 && time($0) < 3.99 }
        #expect(!map.isEmpty && map.allSatisfy { $0["analysisMode"] as? String == "resting" })
        let hackRows = rows.filter { time($0) >= 3.99 }
        let first = try #require(hackRows.first)
        // Worst case one slow interval: the last map sample can fall just before the hack.
        #expect(time(first) - 4 <= 0.25 + 0.001, "first hack frame analysed at \(time(first))")
        #expect(first["calibration"] != nil || first["slotCount"] != nil || first["inputTimerVisible"] as? Bool == true,
                "\(name) shows the array, the slot strip or the timer to a slow look")
        let after = Array(hackRows.dropFirst())
        #expect(after.count >= 9)
        #expect(after.allSatisfy { $0["analysisMode"] as? String == "active" })
        #expect(zip(hackRows, after).allSatisfy { time($1) - time($0) < 0.07 }, "every 20-Hz look analysed")
    }

    @Test("A gear-panel candidate whose reads keep finding no panel stops pinning 20 Hz; its reads go on")
    func rejectedGearCandidate() throws {
        let clock = ReplayMeterClock(), signal = ReadingModeSignal()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let harness = try Harness(keepsLogs: true, assistsGlyphs: false, readingMode: signal, meter: meter)
        let panel = try Frames.untitledPanel()
        for index in 0..<420 {
            let time = Double(index) / 60
            clock.set(time)
            harness.output.process(try harness.frame(panel, at: time, arrival: 100 + time))
            try harness.waitForTextReads()
        }
        let snapshot = meter.snapshot()
        #expect(snapshot.gateOccupancy.counts[AnalysisGateReason.gearPanel.rawValue] > 0,
                "the geometry kept the pace until its reads failed")
        #expect(snapshot.gateOccupancy.current.has(.gearRejected) && !snapshot.gateOccupancy.current.has(.gearPanel))
        #expect(!snapshot.gateOccupancy.current.has(.gearObserver) && !snapshot.gateOccupancy.current.has(.gearGroup))
        #expect(signal.tint == .waiting && snapshot.readingMode?.mode == .resting)
        #expect(snapshot.analysedLastSecond == 4, "before the fix a nonPanel candidate kept this at 20")
        let reads = harness.output.textReadMetrics.gearSubmitted
        harness.output.close()
        #expect(reads >= 6, "the candidate is still read, at the back-off cadence: \(reads)")
        let log = try String(contentsOf: try #require(harness.directory).url.appendingPathComponent("gear-drops.jsonl"),
                             encoding: .utf8)
        let readings = log.split(separator: "\n").filter { $0.contains("\"kind\":\"reading\"") }
        #expect(readings.count >= 3 && readings.allSatisfy { $0.contains("\"disposition\":\"nonPanel\"") },
                "the fixture must actually be read as no panel: \(readings.count) reads")
        #expect(harness.drops.values.isEmpty)
    }

    @Test("From a settled night map, a hack's 100-ms empty array is fitted before its first Glyph at 60 Hz",
          arguments: [false, true])
    func nightMapQuickFirstGlyph60Hz(lowPower: Bool) throws {
        let harness = try Harness(power: .init(lowPowerMode: lowPower))
        let phases = try (0..<4).map { try Frames.nightMap(phase: $0) }
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        // A candidate after a candidate: no entry look; only the switch of screens can help.
        #expect(try #require(LumaGate().read(phases[0])).isCandidate)
        // Three seconds of night map, every 20-Hz look a new phase, then the hack.
        for index in 0..<180 {
            harness.output.process(try harness.frame(phases[(index / 3) % 4], at: Double(index) / 60))
        }
        let script: [(CVPixelBuffer, Int)] = [(empty, 6), (glyph, 6), (empty, 6), (glyph, 6), (empty, 12)]
        var index = 180
        for (buffer, count) in script {
            for _ in 0..<count {
                harness.output.process(try harness.frame(buffer, at: Double(index) / 60))
                index += 1
            }
        }
        let rows = try harness.finish()
        func time(_ row: [String: Any]) -> Double { row["presentationTime"] as? Double ?? -1 }
        let map = rows.filter { time($0) >= 2.2 && time($0) < 2.99 }
        #expect(!map.isEmpty && map.allSatisfy { $0["analysisMode"] as? String == "resting" }, "the map had settled")
        let hack = rows.filter { time($0) >= 2.99 }
        let first = try #require(hack.first)
        #expect(abs(time(first) - 3) < 0.001, "the switching frame itself is analysed: \(time(first))")
        #expect(first["calibration"] != nil && first["state"] as? String == "noStroke")
        let firstGlyph = try #require(hack.first { time($0) >= 3.099 })
        #expect(abs(time(firstGlyph) - 3.1) < 0.001, "first Glyph frame analysed at \(time(firstGlyph))")
        #expect(firstGlyph["calibration"] != nil && firstGlyph["state"] as? String != "noStroke",
                "the first Glyph is read against the fit from the empty array")
        #expect(hack.allSatisfy { $0["analysisMode"] as? String == "active" })
    }

    @Test("A rejected gear candidate is forgotten after seconds without panel geometry: the next panel gets the full pace")
    func rejectedGearCandidateForgotten() throws {
        let clock = ReplayMeterClock()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let harness = try Harness(keepsLogs: false, assistsGlyphs: false, meter: meter)
        let panel = try Frames.untitledPanel()
        let blank = try Frames.solid(width: CVPixelBufferGetWidth(panel), height: CVPixelBufferGetHeight(panel))
        var index = 0
        func play(_ buffer: CVPixelBuffer, _ count: Int) throws {
            for _ in 0..<count {
                let time = Double(index) / 60
                clock.set(time)
                harness.output.process(try harness.frame(buffer, at: time, arrival: 100 + time))
                try harness.waitForTextReads()
                index += 1
            }
        }
        try play(panel, 420)
        #expect(meter.snapshot().gateOccupancy.current.has(.gearRejected), "the candidate's reads found no panel")
        // Four seconds without the panel's geometry, then it is back.
        try play(blank, 240)
        let before = meter.snapshot().gateOccupancy.counts[AnalysisGateReason.gearPanel.rawValue]
        try play(panel, 30)
        let after = meter.snapshot().gateOccupancy.counts[AnalysisGateReason.gearPanel.rawValue]
        #expect(after > before, "the returning panel keeps the full pace until its own reads fail")
        harness.output.close()
    }

    @Test("Idle frames with times of their own keep the last analysed frame's evidence: a still hack screen stays at 20 Hz")
    func idleFramesKeepActivity() throws {
        let signal = ReadingModeSignal(), meter = Self.meter()
        let harness = try Harness(keepsLogs: false, readingMode: signal, meter: meter)
        let empty = try Frames.recorded("field-00456")
        for index in 0..<10 {
            let time = Double(index) / 20
            harness.output.process(try harness.frame(empty, at: time, arrival: time))
            try harness.waitForTextReads()
        }
        // Four seconds of idle frames, longer than the settle time.
        for index in 10..<90 {
            let time = Double(index) / 20
            harness.output.process(try harness.frame(empty, status: .idle, at: time, arrival: time))
        }
        let current = meter.snapshot().gateOccupancy.current
        #expect(current.has(.slots), "the slot strip the last real frame showed")
        #expect(signal.tint == .reading)
        harness.output.close()
    }

    @Test("After a hack, its result and its gear drop are read as with power saving off, at full speed on their own evidence",
          arguments: [false, true])
    func resultAndGearAfterHack(sameSize: Bool) throws {
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        let input = try Frames.recorded("field-00492")
        let width = CVPixelBufferGetWidth(empty), height = CVPixelBufferGetHeight(empty)
        // `sameSize`: the panels at the hack's size, so the session keeps the
        // hack's node fit through them, as on a phone.
        let size: (width: Int, height: Int)? = sameSize ? (width: width, height: height) : nil
        let result = try Frames.recorded("four-final", size: size)
        let base = try Frames.recorded("five-base", size: size), bonus = try Frames.recorded("five-bonus", size: size)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        // 60 Hz: the hack to its input, three seconds of result, two of each
        // gear panel, then six seconds of map.
        let script: [(CVPixelBuffer, Int)] = [(empty, 60), (glyph, 60), (input, 60), (result, 180), (base, 120),
                                              (bonus, 120), (map, 360)]
        struct Run {
            var rows: [[String: Any]]
            var results: [HackResultSummary]
            var items: [String]
        }
        func run(powerSaving: Bool) throws -> Run {
            let clock = ReplayMeterClock(), signal = ReadingModeSignal()
            let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
            meter.reset()
            let harness = try Harness(readsResults: true, readsGear: true, powerSaving: powerSaving,
                                      readingMode: signal, meter: meter)
            var index = 0
            for (buffer, count) in script {
                for _ in 0..<count {
                    let time = Double(index) / 60
                    clock.set(time)
                    harness.output.process(try harness.frame(buffer, at: time, arrival: 100 + time))
                    try harness.waitForTextReads()
                    index += 1
                }
                guard powerSaving else { continue }
                let snapshot = meter.snapshot(), current = snapshot.gateOccupancy.current
                if buffer === result {
                    #expect(current.has(.resultPanel), "the result panel is its own evidence")
                    #expect(snapshot.analysedLastSecond == 20 && signal.tint == .reading)
                }
                if buffer === base || buffer === bonus {
                    #expect(current.has(.gearPanel) || current.has(.gearGroup) || current.has(.gearObserver),
                            "the gear panel is its own evidence")
                    #expect(snapshot.analysedLastSecond == 20 && signal.tint == .reading)
                }
                if buffer === result || buffer === base || buffer === bonus {
                    #expect(!current.has(.calibration), "no stale node fit seconds after the hack")
                }
                if buffer === map {
                    #expect(!current.has(.calibration))
                    #expect(snapshot.readingMode?.mode == .quiet && snapshot.analysedLastSecond == 4,
                            "the map after the panels is not held at 20 Hz")
                }
            }
            let rows = try harness.finish()
            let summaries = harness.drops.values.map(\.summary)
                + harness.gear.values.compactMap { attachment -> GearDropSummary? in
                    if case .read(let summary) = attachment.reading { return summary }
                    return nil
                }
            let items = summaries.flatMap { $0.panels.flatMap { $0.entries } }
                .map { "\($0.item ?? "?") ×\($0.quantity)" }.sorted()
            return Run(rows: rows, results: harness.results.values, items: items)
        }
        let saving = try run(powerSaving: true), before = try run(powerSaving: false)
        func outcome(_ summary: HackResultSummary?) -> String {
            guard let summary else { return "none" }
            let slots = summary.slots.map { $0.outcome.rawValue }.joined(separator: ",")
            return "\(summary.hackID)|\(summary.state.rawValue)|\(summary.hackingBonus?.percent ?? -1)"
                + "|\(summary.speedBonus?.percent ?? -1)|\(slots)"
        }
        let last = try #require(saving.results.last, "the hack's result was read")
        #expect(last.hackingBonus != nil && last.speedBonus != nil, "\(outcome(last))")
        #expect(outcome(saving.results.last) == outcome(before.results.last))
        #expect(!saving.items.isEmpty, "the drop was read")
        #expect(saving.items == before.items)
        // Every 20-Hz frame of the result and the panels was analysed, as without saving.
        func panelTimes(_ run: Run) -> [Double] {
            run.rows.compactMap { $0["presentationTime"] as? Double }.filter { $0 >= 3 && $0 < 9.99 }
        }
        #expect(panelTimes(saving) == panelTimes(before))
        #expect(panelTimes(saving).count >= 139)
    }

    @Test("Low Power Mode halves analysis outside a hack")
    func lowPower() throws {
        let harness = try Harness(power: .init(lowPowerMode: true))
        let buffer = try Frames.solid()
        for index in 0..<60 { harness.output.process(try harness.frame(buffer, at: 100 + Double(index) / 60)) }
        let rows = try harness.finish()
        let times = rows.compactMap { $0["presentationTime"] as? Double }
        #expect((9...11).contains(times.count))
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.099 })
        #expect(rows.allSatisfy { $0["powerConstrained"] as? Bool == true })
    }

    @Test("With power saving off the map is analyzed fully at 20 Hz, as before, even in Low Power Mode")
    func powerSavingOff() throws {
        let harness = try Harness(power: .init(lowPowerMode: true), powerSaving: false)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        for index in 0..<120 { harness.output.process(try harness.frame(map, at: Double(index) / 30)) }
        let rows = try harness.finish()
        let times = rows.compactMap { $0["presentationTime"] as? Double }
        #expect(times.count == 60, "every other 30-Hz frame, as at 20 Hz")
        #expect(rows.allSatisfy {
            $0["analysisMode"] as? String == "active" && $0["state"] as? String != "quietScreen"
                && $0["powerConstrained"] as? Bool == false && $0["powerSaving"] as? Bool == false
        })
    }

    @Test("The floating window's debug fill follows the gate: Idle on the map, Reading at the hack, told once per change")
    func readingModeFollowsGate() throws {
        let signal = ReadingModeSignal()
        let harness = try Harness(keepsLogs: false, readingMode: signal)
        let map = try Frames.recorded("frame-02092", ext: "jpg"), hack = try Frames.recorded("field-00443")
        harness.output.process(try harness.frame(map, at: 0))
        #expect(signal.tint == .reading, "the gate starts at full speed")
        for index in 1..<120 { harness.output.process(try harness.frame(map, at: Double(index) / 30)) }
        #expect(signal.tint == .idle)
        for index in 120..<135 { harness.output.process(try harness.frame(hack, at: Double(index) / 30)) }
        #expect(signal.tint == .reading)
        #expect(signal.changes == 3, "none → Reading → Idle → Reading, not once per frame: \(signal.changes)")
        harness.output.close()
    }

    @Test("Low Power Mode shows Backing off only while it halves the rate; power saving off keeps the window's own fill")
    func readingModeBackingOff() throws {
        let buffer = try Frames.solid()
        let constrained = ReadingModeSignal()
        let saving = try Harness(keepsLogs: false, power: .init(lowPowerMode: true), readingMode: constrained)
        for index in 0..<20 { saving.output.process(try saving.frame(buffer, at: 100 + Double(index) / 60)) }
        #expect(constrained.tint == .backingOff)
        saving.output.close()

        let off = ReadingModeSignal()
        let unsaved = try Harness(keepsLogs: false, power: .init(lowPowerMode: true), powerSaving: false,
                                  readingMode: off)
        for index in 0..<20 { unsaved.output.process(try unsaved.frame(buffer, at: 100 + Double(index) / 60)) }
        #expect(off.tint == .none && off.changes == 0)
        unsaved.output.close()
    }

    /// A meter of its own, with a session, so the shared one's other users
    /// cannot change what a test counts.
    static func meter() -> PowerMeter {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        return meter
    }

    @Test("A broadcast's still screen settles the fill after the settle time, Idle on the map, analysing nothing")
    func stillBroadcastMap() throws {
        let signal = ReadingModeSignal(), meter = Self.meter()
        let harness = try Harness(keepsLogs: false, readingMode: signal, meter: meter)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        // Half a second of map at 30 Hz, arriving 100 s into uptime; then the
        // broadcast sends nothing and its link asks four times a second.
        for index in 0..<15 {
            let time = Double(index) / 30
            harness.output.process(try harness.frame(map, at: time, arrival: 100 + time))
        }
        #expect(signal.tint == .reading)
        let analysed = meter.snapshot().total(.framesAnalysed).count
        let updates = harness.updates.values.count
        func still(_ step: Int) { harness.output.noteStillScreen(uptime: 100.5 + Double(step) * 0.25) }
        for step in 0...5 { still(step) }
        #expect(signal.tint == .reading, "1.75 s in: not yet")
        for step in 6...8 { still(step) }
        #expect(signal.tint == .idle, "two seconds after the map was first seen")
        #expect(signal.changes == 2, "none → Reading → Idle: \(signal.changes)")
        #expect(meter.snapshot().total(.framesAnalysed).count == analysed, "a still look analyses nothing")
        #expect(harness.updates.values.count == updates, "nor tells the displays anything")
        #expect(meter.snapshot().modes.seconds(.quiet) > 0, "the time split counts the still screen")
        // The next frame carries its own timestamp, a little before the last
        // look's extrapolated one: an unchanged map stays Idle, the hack wakes it.
        harness.output.process(try harness.frame(map, at: 2.2, arrival: 102.24))
        #expect(signal.tint == .idle)
        harness.output.process(try harness.frame(try Frames.recorded("field-00443"), at: 2.26, arrival: 102.27))
        #expect(signal.tint == .reading)
        harness.output.close()
        harness.output.noteStillScreen(uptime: 110)
        #expect(signal.tint == .reading, "nothing after close")
    }

    @Test("A broadcast's still game screen shows Waiting; without power saving still looks do nothing")
    func stillBroadcastGameScreen() throws {
        let signal = ReadingModeSignal(), meter = Self.meter()
        let harness = try Harness(keepsLogs: false, readingMode: signal, meter: meter)
        let dark = try Frames.solid()
        harness.output.noteStillScreen(uptime: 50)
        #expect(signal.tint == .none, "no look before the first frame")
        for index in 0..<10 {
            let time = 7 + Double(index) / 20
            harness.output.process(try harness.frame(dark, at: time, arrival: 40 + time))
            try harness.waitForTextReads()
        }
        let analysed = meter.snapshot().total(.framesAnalysed).count
        #expect(analysed == 10)
        // A candidate with no hack evidence rests two seconds after the first
        // look, as on unchanged frames; being dark does not keep it awake.
        for step in 1...6 { harness.output.noteStillScreen(uptime: 47.45 + Double(step) * 0.25) }
        #expect(signal.tint == .reading, "under two seconds after the first look: not yet")
        for step in 7...8 { harness.output.noteStillScreen(uptime: 47.45 + Double(step) * 0.25) }
        #expect(signal.tint == .waiting)
        #expect(meter.snapshot().total(.framesAnalysed).count == analysed)
        harness.output.close()

        let off = ReadingModeSignal()
        let unsaved = try Harness(keepsLogs: false, powerSaving: false, readingMode: off, meter: Self.meter())
        unsaved.output.process(try unsaved.frame(dark, at: 0, arrival: 10))
        for step in 1...40 { unsaved.output.noteStillScreen(uptime: 10 + Double(step) * 0.25) }
        #expect(off.tint == .none && off.changes == 0)
        unsaved.output.close()
    }

    @Test("ScreenCaptureKit's idle frames repeating the last timestamp settle the pace too, and are not analysed")
    func stillScreenCaptureFrames() throws {
        let signal = ReadingModeSignal(), meter = Self.meter()
        let harness = try Harness(readingMode: signal, meter: meter)
        let dark = try Frames.solid()
        for index in 0..<10 {
            let time = 3 + Double(index) / 20
            harness.output.process(try harness.frame(dark, at: time, arrival: 20 + time))
            try harness.waitForTextReads()
        }
        let analysed = meter.snapshot().total(.framesAnalysed).count
        // Five seconds of idle frames at 60 Hz, all stamped with the last
        // complete frame's time.
        let last = 3 + Double(9) / 20
        for index in 1...300 {
            harness.output.process(try harness.frame(dark, status: .idle, at: last,
                                                     arrival: 20 + last + Double(index) / 60))
        }
        #expect(signal.tint == .waiting)
        #expect(meter.snapshot().total(.framesAnalysed).count == analysed)
        let rows = try harness.finish()
        #expect(rows.count == 10, "only the complete frames were analysed: \(rows.count)")
        #expect(harness.telemetry.values.count == 310, "every callback still gets its telemetry row")
    }

    @Test("Every delivered frame is timed once: a skipped one whole, an analysed one as intake and work")
    func framesAreTimedOnce() throws {
        let meter = Self.meter()
        let harness = try Harness(meter: meter)
        let dark = try Frames.solid()
        for index in 0..<30 {
            // 60 Hz: at least two of every three fall to the 20-Hz throttle.
            let time = 3 + Double(index) / 60
            harness.output.process(try harness.frame(dark, at: time, arrival: 20 + time))
            try harness.waitForTextReads()
        }
        let snapshot = meter.snapshot()
        let analysed = snapshot.total(.framesAnalysed).count
        #expect(snapshot.total(.framesDelivered).count == 30)
        #expect(analysed > 0)
        #expect(snapshot.total(.frameIntake).count == analysed)
        #expect(snapshot.total(.frameWork).count == analysed)
        #expect(snapshot.total(.skippedFrame).count + analysed == 30)
        #expect(snapshot.total(.skippedFrame).count >= 15)
        harness.output.close()
    }

    @Test("Idle frames with timestamps of their own count as an unchanged screen")
    func idleFramesWithTimes() throws {
        let signal = ReadingModeSignal()
        let harness = try Harness(keepsLogs: false, readingMode: signal, meter: Self.meter())
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        harness.output.process(try harness.frame(map, at: 0, arrival: 0))
        for index in 1...50 {
            let time = Double(index) / 20
            harness.output.process(try harness.frame(map, status: .idle, at: time, arrival: time))
        }
        #expect(signal.tint == .idle)
        harness.output.close()
    }

    @Test("Still ticks preserve busy hack safety and do no conversions, OCR or analysis")
    func stillTicksWhileBusy() throws {
        let signal = ReadingModeSignal(), meter = Self.meter()
        let harness = try Harness(readingMode: signal, meter: meter)
        let empty = try Frames.recorded("field-00456")
        for index in 0..<10 {
            let time = Double(index) / 20
            harness.output.process(try harness.frame(empty, at: time, arrival: 100 + time))
            try harness.waitForTextReads()
        }
        let before = meter.snapshot()
        let updates = harness.updates.values.count
        for step in 1...80 { harness.output.noteStillScreen(uptime: 100.45 + Double(step) / 4) }
        #expect(signal.tint == .reading, "a visible slot strip keeps the reader busy despite silence")
        let after = meter.snapshot()
        let metrics: [PowerMetric] = [.framesAnalysed, .conversion, .glyphRead]
        for metric in metrics {
            #expect(after.total(metric).count == before.total(metric).count)
        }
        #expect(harness.updates.values.count == updates)
        // Real presentation time resumes slightly behind the extrapolated look.
        harness.output.process(try harness.frame(empty, at: 20.4, arrival: 120.5))
        #expect(signal.tint == .reading)
        let rows = try harness.finish()
        #expect(rows.count == 11)
        #expect(rows.allSatisfy { $0["analysisMode"] as? String == "active" })
    }

    @Test("A still hack screen with its slot strip keeps the full pace and its node fit")
    func stillHackScreen() throws {
        let harness = try Harness()
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        // Three seconds of an unchanging empty array, longer than the gate's
        // settle time, then a Glyph.
        for index in 0..<90 { harness.output.process(try harness.frame(empty, at: Double(index) / 30)) }
        for index in 90..<96 { harness.output.process(try harness.frame(glyph, at: Double(index) / 30)) }
        let rows = try harness.finish()
        #expect(rows.count == 48, "every 20-Hz frame analyzed: \(rows.count)")
        #expect(rows.allSatisfy { $0["analysisMode"] as? String == "active" })
        #expect(rows.prefix(45).allSatisfy { $0["state"] as? String == "noStroke" && $0["calibration"] != nil })
        let first = try #require(rows.first { ($0["presentationTime"] as? Double ?? 0) >= 2.99 })
        #expect(first["calibration"] != nil && first["state"] as? String != "noStroke",
                "the Glyph is read against the fit kept through the still screen")
    }

    @Test("From the first hack frame on, power saving changes nothing the recognizer reads")
    func hackEquivalence() throws {
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
        // 30 Hz: three seconds of map, then empty array, Glyph, empty, Glyph.
        let script: [(CVPixelBuffer, Int)] = [(map, 90), (empty, 30), (glyph, 30), (empty, 6), (glyph, 30), (empty, 15)]
        func run(powerSaving: Bool) throws -> [[String: Any]] {
            let harness = try Harness(powerSaving: powerSaving)
            var index = 0
            for (buffer, count) in script {
                for _ in 0..<count {
                    harness.output.process(try harness.frame(buffer, at: Double(index) / 30))
                    index += 1
                }
            }
            return try harness.finish().filter { ($0["presentationTime"] as? Double ?? 0) >= 2.99 }
        }
        func seen(_ row: [String: Any]) -> String {
            ["presentationTime", "state", "exactMatches", "edges", "slotCount", "slotHighlight", "inputTimerVisible"]
                .map { "\(row[$0] ?? "-")" }.joined(separator: "|") + "|\(row["calibration"] != nil)"
        }
        let saving = try run(powerSaving: true), before = try run(powerSaving: false)
        #expect(before.count == 56)
        #expect(saving.map(seen) == before.map(seen))
        #expect(saving.allSatisfy { $0["analysisMode"] as? String == "active" })
    }

    /// One hack from the fixtures through the output at 20 Hz, waiting for
    /// each text read: the map, the command channel, two Glyphs, the input,
    /// the result, both gear panels, the map again. Nil `logic` and `engine`
    /// leave the output its own Swift arms.
    private struct ScriptedHack {
        var snapshots: [GlyphDisplaySnapshot]
        var logs: [String: [String]]
        var results: [HackResultSummary]
        var gear: [HackGearAttachment]
        var drops: [GearDrop]
        var logicName: String
        var engineName: String
        /// Gear and result reads the lane ran, and those the settle cuts
        /// answered instead.
        var gearReads = 0
        var gearHeld: UInt64 = 0
        var resultReads = 0
        var resultHeld: UInt64 = 0
        /// What the gear read cuts left out (`PowerMetric.gearSkipped`).
        var gearSkipped: [PowerMetric: UInt64] = [:]

        static func run(logic: RecognitionLogicChoice? = nil, engine: FrameRecognitionEngine? = nil,
                        cuts: Set<RecognitionCut> = [],
                        table: GlyphTable = SetupDemo.builtInTable) throws -> ScriptedHack {
            let empty = try Frames.recorded("field-00456"), glyph = try Frames.recorded("field-00443")
            let input = try Frames.recorded("field-00492"), command = try Frames.recorded("field-00381")
            let width = CVPixelBufferGetWidth(empty), height = CVPixelBufferGetHeight(empty)
            let size = (width: width, height: height)
            let result = try Frames.recorded("four-final", size: size)
            let base = try Frames.recorded("five-base", size: size)
            let bonus = try Frames.recorded("five-bonus", size: size)
            let map = try Frames.recorded("frame-02092", ext: "jpg")
            let script: [(CVPixelBuffer, Int)] = [(map, 20), (command, 20), (empty, 20), (glyph, 20), (empty, 4),
                                                  (glyph, 20), (input, 30), (result, 60), (base, 40), (bonus, 40),
                                                  (map, 40)]
            let meter = LiveGlyphOutputTests.meter()
            let harness = try Harness(readsResults: true, readsGear: true, table: table, engine: engine, cuts: cuts,
                                      logic: logic, meter: meter)
            var index = 0
            for (buffer, count) in script {
                for _ in 0..<count {
                    let time = Double(index) / 20
                    harness.output.process(try harness.frame(buffer, at: time, arrival: 100 + time))
                    try harness.waitForTextReads()
                    index += 1
                }
            }
            let logicName = harness.output.logicName
            let gearReads = harness.output.textReadMetrics.gearSubmitted
            let resultReads = harness.output.textReadMetrics.resultSubmitted
            _ = try harness.finish()
            let folder = try #require(harness.directory).url
            // Every log a session keeps, less the per-frame timings, the
            // text lane's latencies and each gear read pass's Vision time,
            // which no logic decides.
            let timed: Set<String> = ["processingMilliseconds", "queueMilliseconds", "recordingOfferMilliseconds",
                                      "headerLatencyMilliseconds", "resultLatencyMilliseconds",
                                      "resultTotalLatencyMilliseconds"]
            var logs: [String: [String]] = [:]
            for name in ["recognition", "tracking", "results", "gear-drops", "commands", "input-validation"] {
                let text = try String(contentsOf: folder.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
                logs[name] = try text.split(separator: "\n").map { line in
                    var row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                    for key in timed { row[key] = nil }
                    if let passes = row["passes"] as? [[String: Any]] {
                        row["passes"] = passes.map { pass in pass.filter { $0.key != "milliseconds" } }
                    }
                    return String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                                  as: UTF8.self)
                }
            }
            // Each run has its own session folder; the pictures in it match.
            func local(_ pictures: [HackGearPicture]) -> [HackGearPicture] {
                pictures.map { HackGearPicture(path: URL(fileURLWithPath: $0.path).lastPathComponent, stage: $0.stage) }
            }
            let gear = harness.gear.values.map { attachment -> HackGearAttachment in
                var attachment = attachment
                attachment.sessionFolder = nil
                attachment.pictures = attachment.pictures.map(local)
                return attachment
            }
            let drops = harness.drops.values.map { drop -> GearDrop in
                var drop = drop
                drop.sessionFolder = nil
                drop.pictures = local(drop.pictures)
                return drop
            }
            return ScriptedHack(snapshots: harness.updates.values.map(\.snapshot), logs: logs,
                                results: harness.results.values, gear: gear, drops: drops, logicName: logicName,
                                engineName: engine?.name ?? "swift", gearReads: gearReads,
                                gearHeld: meter.snapshot().total(.gearHeld).count, resultReads: resultReads,
                                resultHeld: meter.snapshot().total(.resultHeld).count,
                                gearSkipped: Dictionary(uniqueKeysWithValues: PowerMetric.gearSkipped.map {
                                    ($0, meter.snapshot().total($0).count)
                                }))
        }

        /// The hack was followed and its result and drop read, so a
        /// comparison with this run covers every area.
        func expectCoversEveryArea() {
            #expect(snapshots.contains { $0.state == .input && $0.expectedSlotCount != nil })
            #expect(results.contains { $0.hackingBonus != nil })
            #expect(!(logs["tracking"] ?? []).isEmpty && !(logs["gear-drops"] ?? []).isEmpty)
        }
    }

    @Test("The C++ logic set reads a hack, its result and its gear drop exactly as the Swift set does",
          .timeLimit(.minutes(10)))
    func logicArmsAgree() throws {
        // The output's default is the Swift set the Swift choice makes, so
        // the shipped run stands for both; the factory test covers the choice.
        let shipped = try ScriptedHack.run(), cpp = try ScriptedHack.run(logic: .cpp)
        #expect(shipped.logicName == "swift" && cpp.logicName == "cpp")
        shipped.expectCoversEveryArea()
        #expect(cpp.snapshots == shipped.snapshots)
        for (log, rows) in shipped.logs {
            #expect(cpp.logs[log] == rows, "\(log).jsonl")
        }
        #expect(cpp.results == shipped.results)
        #expect(cpp.gear == shipped.gear)
        #expect(cpp.drops == shipped.drops)
    }

    @Test("A settle cut reads the scripted hack, its result and its gear drop as without it, with fewer panel reads",
          .timeLimit(.minutes(10)),
          arguments: [Set<RecognitionCut>([.gearSettle]), [.resultSettle], [.gearSettle, .resultSettle]])
    func settleCutsAgreeWithoutThem(_ cuts: Set<RecognitionCut>) throws {
        let off = try ScriptedHack.run()
        let on = try ScriptedHack.run(cuts: cuts)
        off.expectCoversEveryArea()
        #expect(on.snapshots == off.snapshots)
        // A settled reading issued again is logged as such, with no OCR
        // passes of its own, and the per-frame log counts the lane's OCR,
        // which the cut lowers; everything else in the logs is the same.
        func plain(_ rows: [String]) throws -> [String] {
            try rows.map { line in
                var row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                for key in ["reissued", "passes", "headerSubmitted", "headerCompleted", "resultSubmitted",
                            "resultCompleted"] { row[key] = nil }
                return String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                              as: UTF8.self)
            }
        }
        for (log, rows) in off.logs {
            let settled = try plain(on.logs[log] ?? []), read = try plain(rows)
            let first = zip(read, settled).first { $0 != $1 }.map { "\($0.0)\n  became \($0.1)" } ?? "none"
            #expect(settled == read, "\(log).jsonl: \(read.count) rows off, \(settled.count) on; first difference \(first)")
        }
        #expect(on.results == off.results)
        #expect(on.gear == off.gear)
        #expect(on.drops == off.drops)
        #expect(off.gearHeld == 0 && off.resultHeld == 0)
        if cuts.contains(.gearSettle) {
            #expect(on.gearHeld > 0 && on.gearReads + Int(on.gearHeld) == off.gearReads,
                    "\(on.gearReads) gear reads and \(on.gearHeld) held, against \(off.gearReads)")
        } else {
            #expect(on.gearHeld == 0 && on.gearReads == off.gearReads)
        }
        if cuts.contains(.resultSettle) {
            #expect(on.resultHeld > 0 && on.resultReads + Int(on.resultHeld) == off.resultReads,
                    "\(on.resultReads) result reads and \(on.resultHeld) held, against \(off.resultReads)")
        } else {
            #expect(on.resultHeld == 0 && on.resultReads == off.resultReads)
        }
    }

    @Test("The gear lean read reads the scripted hack, its result and its gear drop as without it, with the passes it left out counted",
          .timeLimit(.minutes(10)))
    func leanGearReadAgreesWithoutIt() throws {
        let off = try ScriptedHack.run()
        let on = try ScriptedHack.run(cuts: [.gearLeanRead])
        off.expectCoversEveryArea()
        #expect(on.snapshots == off.snapshots)
        #expect(on.results == off.results)
        #expect(on.gear == off.gear)
        #expect(on.drops == off.drops)
        #expect(on.gearReads == off.gearReads)
        // Each gear read's passes are logged, and a shorter gear read frees
        // the lane sooner, which the per-frame log's lane counts show; only
        // they may differ.
        func passes(_ rows: [String]) throws -> (count: Int, rest: [String]) {
            var count = 0
            let rest = try rows.map { line in
                var row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                count += (row["passes"] as? [Any])?.count ?? 0
                for key in ["passes", "headerSubmitted", "headerCompleted", "resultSubmitted", "resultCompleted"] {
                    row[key] = nil
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                              as: UTF8.self)
            }
            return (count, rest)
        }
        for (log, rows) in off.logs {
            #expect(try passes(on.logs[log] ?? []).rest == passes(rows).rest, "\(log).jsonl")
        }
        #expect(off.gearSkipped.values.allSatisfy { $0 == 0 })
        // The Bonus panel's three items leave its last row's right half empty;
        // the English game has no numeric pass, and no quantity here is red.
        let skipped = on.gearSkipped
        #expect((skipped[.gearEmptyCellSkipped] ?? 0) > 0 && skipped[.gearRedRowSkipped] == 0
                    && skipped[.gearQuantitySkipped] == 0 && skipped[.gearLanguageSkipped] == 0, "\(skipped)")
        let passesLeft = [PowerMetric.gearRedRowSkipped, .gearEmptyCellSkipped, .gearQuantitySkipped]
            .reduce(UInt64(0)) { $0 + (skipped[$1] ?? 0) }
        // Vision's pass timings reach only the launch meter, so the passes
        // made are counted from the reads' log rows.
        let passesOn = try passes(on.logs["gear-drops"] ?? []).count
        let passesOff = try passes(off.logs["gear-drops"] ?? []).count
        #expect(passesOn < passesOff && UInt64(passesOn) + passesLeft == UInt64(passesOff),
                "\(passesOn) passes on, \(passesOff) off, \(skipped) left out")
    }

    @Test("The defaults read a hack, its result and its gear drop as the Swift pipeline without cuts does",
          .timeLimit(.minutes(10)))
    func defaultsAgreeWithSwift() throws {
        let cuts = AppPreferences.defaultRecognitionCuts
        let setup = makeRecognitionEngine(choice: AppPreferences.defaultRecognitionEngine, table: SetupDemo.builtInTable,
                                          cuts: cuts)
        #expect(setup.fallback == nil && setup.cuts == cuts)
        let swift = try ScriptedHack.run(logic: .swift)
        let defaults = try ScriptedHack.run(logic: AppPreferences.defaultRecognitionLogic, engine: setup.engine,
                                            cuts: setup.cuts)
        #expect(defaults.engineName == "cpp" && defaults.logicName == "swift")
        swift.expectCoversEveryArea()
        #expect(defaults.snapshots == swift.snapshots)
        for (log, rows) in swift.logs where log != "recognition" && log != "gear-drops" {
            #expect(defaults.logs[log] == rows, "\(log).jsonl")
        }
        // The gear lean read, a default, leaves out passes that change no
        // read: each gear read logs its passes, and only they may differ.
        func gearRows(_ run: ScriptedHack) throws -> (rows: [String], passes: Int) {
            var passes = 0
            let rows = try (run.logs["gear-drops"] ?? []).map { line in
                var row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                passes += (row.removeValue(forKey: "passes") as? [Any])?.count ?? 0
                return String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                              as: UTF8.self)
            }
            return (rows, passes)
        }
        let swiftGear = try gearRows(swift), defaultGear = try gearRows(defaults)
        #expect(!swiftGear.rows.isEmpty && defaultGear.rows == swiftGear.rows)
        #expect(defaultGear.passes < swiftGear.passes, "\(defaultGear.passes) passes against \(swiftGear.passes)")
        // The per-frame log also carries what each engine measured on its
        // own pixels (the Y plane against Core Graphics' grey), such as the
        // fit's sub-pixel geometry and ink counts: there only the decisions
        // must agree.
        func rows(_ run: ScriptedHack) throws -> [[String: Any]] {
            try (run.logs["recognition"] ?? []).map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
        let swiftRows = try rows(swift), defaultRows = try rows(defaults)
        #expect(swiftRows.count == defaultRows.count)
        let decisions = ["presentationTime", "state", "phase", "phaseSource", "hackID", "exactMatches", "edges",
                         "extensions", "slotCount", "slotHighlight", "inputTimerVisible", "analysisMode"]
        func decided(_ row: [String: Any]) -> String {
            decisions.map { "\($0)=\(row[$0] ?? "-")" }.joined(separator: "|") + "|fit=\(row["calibration"] != nil)"
        }
        #expect(defaultRows.map(decided) == swiftRows.map(decided))
        let measured = Set(zip(swiftRows, defaultRows).flatMap { pair in
            Set(pair.0.keys).union(pair.1.keys).filter { key in
                let one = pair.0[key].map { "\($0)" }, other = pair.1[key].map { "\($0)" }
                return one != other
            }
        })
        print("DEFAULTS AGAINST SWIFT, recognition.jsonl keys that differ: \(measured.sorted())")
        #expect(defaults.results == swift.results)
        #expect(defaults.gear == swift.gear)
        #expect(defaults.drops == swift.drops)
    }

    @Test("A shape list too large for the C++ engine reads a hack on the Swift engine the defaults fall back to",
          .timeLimit(.minutes(10)))
    func oversizedListFallsBack() throws {
        let table = RecognitionEngineChoiceTests.demoTable(glyphs: 513)
        let setup = makeRecognitionEngine(choice: AppPreferences.defaultRecognitionEngine, table: table,
                                          cuts: AppPreferences.defaultRecognitionCuts)
        #expect(setup.engine is SwiftFrameRecognitionEngine
                && setup.cuts == [.lazyImage, .planeGate, .headerStillSkip, .gearLeanRead])
        #expect(setup.label == "swift (chose cpp: 513 Glyphs, the C++ engine takes at most 512)")
        let hack = try ScriptedHack.run(logic: AppPreferences.defaultRecognitionLogic, engine: setup.engine,
                                        cuts: setup.cuts, table: table)
        #expect(hack.engineName == "swift" && hack.logicName == "swift")
        hack.expectCoversEveryArea()
        // Each update of the one hack is delivered; the last closes it with
        // the fixture's four slots and its 120% hacking bonus.
        #expect(Set(hack.results.map(\.hackID)) == [1])
        let closed = try #require(hack.results.last)
        #expect(closed.isClosed && closed.state == .complete && closed.slots.count == 4)
        #expect(closed.hackingBonus?.percent == 120)
    }

    @Test("Frames arriving after close are ignored")
    func afterClose() throws {
        let harness = try Harness()
        harness.output.close()
        harness.output.process(try harness.frame(try Frames.solid(), at: 0))
        #expect(harness.updates.values.isEmpty)
        #expect(harness.telemetry.values.isEmpty)
    }

    // MARK: The engine

    @Test("The engine is asked for what the settings and the pace want: a quiet screen skips the array search")
    func engineRequestsFollowThePace() throws {
        let engine = RecordingEngine(rendersImage: true)
        let harness = try Harness(keepsLogs: false, readsResults: true, readsGear: true, engine: engine)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        // 30 Hz, as a broadcast delivers: four seconds of map settle the gate.
        for index in 0..<120 { harness.output.process(try harness.frame(map, at: Double(index) / 30)) }
        harness.output.close()
        let requests = engine.requests
        #expect(requests.count == harness.updates.values.count, "one analysis per analysed frame")
        #expect(requests.count > 8)
        #expect(requests.allSatisfy { $0.request.assistsGlyphs && $0.request.checksGear && $0.request.checksPortal
                                      && $0.request.readsStrip })
        // The first looks are at the full pace and search for the array; the
        // settled map is quiet and does not.
        #expect(requests.first?.request.searchesArray == true)
        let quiet = requests.filter { $0.time >= 2.5 }
        #expect(!quiet.isEmpty && quiet.allSatisfy { !$0.request.searchesArray })
        #expect(harness.updates.values.last?.snapshot.state == .inactive)
        // Every frame reached the engine with its planes and the frame's time.
        #expect(requests.allSatisfy { $0.hadPlanes })
        #expect(requests.map(\.time) == requests.map(\.time).sorted())
    }

    @Test("Without power saving every analysed frame searches for the array, and gear-only capture asks for panels alone")
    func engineRequestsWithoutSavingAndGearOnly() throws {
        let engine = RecordingEngine(rendersImage: true)
        let harness = try Harness(keepsLogs: false, powerSaving: false, engine: engine)
        let map = try Frames.recorded("frame-02092", ext: "jpg")
        for index in 0..<90 { harness.output.process(try harness.frame(map, at: Double(index) / 30)) }
        harness.output.close()
        let requests = engine.requests
        // 30-Hz frames through the 20-Hz throttle: every second one.
        #expect(requests.count == 45)
        #expect(requests.allSatisfy { $0.request.searchesArray && !$0.request.checksGear && !$0.request.checksPortal })

        let gearEngine = RecordingEngine(rendersImage: true)
        let gearOnly = try Harness(keepsLogs: false, readsResults: true, readsGear: true, assistsGlyphs: false,
                                   engine: gearEngine)
        gearOnly.output.process(try gearOnly.frame(map, at: 0))
        gearOnly.output.close()
        let request = try #require(gearEngine.requests.first?.request)
        #expect(request == FrameAnalysisRequest(assistsGlyphs: false, searchesArray: true, checksGear: true,
                                                checksPortal: false, readsStrip: false))
    }

    @Test("The engine's step times land in the Power section under the steps' names")
    func engineTimingsReachTheMeter() throws {
        var timings = FrameStepTimings()
        timings.conversion = 1_000_000; timings.decode = 2_000_000; timings.gearCheck = 3_000_000
        timings.portalCheck = 4_000_000; timings.resultCheck = 5_000_000; timings.gridHunt = 6_000_000
        timings.glyphRead = 7_000_000; timings.slotStrip = nil
        var analysis = FrameAnalysis()
        analysis.timings = timings
        // The engine renders the image itself, as the Swift arm does, so the
        // only conversion counted is the one it reports.
        let engine = RecordingEngine(analysis: analysis, rendersImage: true)
        let meter = Self.meter()
        let harness = try Harness(keepsLogs: false, powerSaving: false, engine: engine, meter: meter)
        let dark = try Frames.solid()
        for index in 0..<4 { harness.output.process(try harness.frame(dark, at: Double(index) / 20)) }
        try harness.waitForTextReads()
        harness.output.close()
        let snapshot = meter.snapshot()
        let frames = snapshot.total(.framesAnalysed).count
        #expect(frames == 4)
        let expected: [(PowerMetric, UInt64)] = [(.conversion, 1), (.decode, 2), (.gearCheck, 3), (.portalCheck, 4),
                                                 (.resultCheck, 5), (.gridHunt, 6), (.glyphRead, 7)]
        for (metric, milliseconds) in expected {
            let total = snapshot.total(metric)
            #expect(total.count == frames, "\(metric.label) runs \(total.count)")
            #expect(total.nanoseconds == milliseconds * 1_000_000 * frames, "\(metric.label)")
        }
        #expect(snapshot.total(.slotStrip).count == 0, "a step that did not run is not counted")
    }

    @Test("With the lazy image cut, a frame the text lane does not take is never rendered and a header read renders only its rows; without it every frame is rendered")
    func lazyImageRendersOnlyForAdmittedReads() throws {
        // An engine that leaves the image to the text lane, as one reading
        // the planes does: the only renders are then LiveGlyphOutput's own,
        // whole frames timed as conversion and header rows as headerRender.
        func run(cuts: Set<RecognitionCut>) throws -> (renders: UInt64, headerRenders: UInt64, analysed: UInt64,
                                                       reads: Int) {
            let gate = AsyncHeaderGate()
            defer { gate.signal() }
            let engine = RecordingEngine(analysis: FrameAnalysis())
            let meter = Self.meter()
            let harness = try Harness(keepsLogs: false, powerSaving: false, engine: engine, cuts: cuts, meter: meter,
                                      headerOperation: { _, time in
                await gate.wait()
                return HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
            })
            let dark = try Frames.solid()
            // The first frame's read holds the lane; the next nine are
            // analysed, submitted and dropped as busy.
            for index in 0..<10 { harness.output.process(try harness.frame(dark, at: Double(index) / 20)) }
            let snapshot = meter.snapshot()
            let metrics = harness.output.textReadMetrics
            gate.signal()
            try harness.waitForTextReads()
            harness.output.close()
            #expect(engine.requests.count == 10)
            #expect(metrics.submitted == 1 && metrics.droppedBusy == 9, "\(metrics)")
            return (snapshot.total(.conversion).count, snapshot.total(.headerRender).count,
                    snapshot.total(.framesAnalysed).count, metrics.submitted)
        }
        let lazy = try run(cuts: [.lazyImage])
        #expect(lazy.analysed == 10)
        #expect(lazy.renders == 0 && lazy.headerRenders == UInt64(lazy.reads),
                "the header's rows rendered once, for the one admitted read: \(lazy)")
        let eager = try run(cuts: [])
        #expect(eager.renders == eager.analysed && eager.headerRenders == 0,
                "every analysed frame is rendered for the text lane: \(eager)")
    }

    /// Renders so far: whole frames, the drone footer's label alone, the
    /// command band alone and a header read's rows alone; with the footer
    /// probes and band checks run, the footer and band renders the plane
    /// gate skipped, and the frames analysed.
    struct RenderCounts: Equatable, CustomStringConvertible {
        let full: UInt64, footer: UInt64, band: UInt64, header: UInt64
        let probes: UInt64, bandChecks: UInt64, footerGated: UInt64, bandGated: UInt64, analysed: UInt64

        init(_ meter: PowerMeter) {
            let snapshot = meter.snapshot()
            full = snapshot.total(.conversion).count
            footer = snapshot.total(.footerRender).count
            band = snapshot.total(.bandRender).count
            header = snapshot.total(.headerRender).count
            probes = snapshot.total(.footerProbe).count
            bandChecks = snapshot.total(.commandBand).count
            footerGated = snapshot.total(.footerGated).count
            bandGated = snapshot.total(.bandGated).count
            analysed = snapshot.total(.framesAnalysed).count
        }

        var all: UInt64 { full + footer + band + header }
        var description: String {
            "full \(full), footer \(footer), band \(band), header \(header), probes \(probes), "
                + "band checks \(bandChecks), gated footer \(footerGated) and band \(bandGated), analysed \(analysed)"
        }
    }

    /// `frames` at 20 Hz between hacks, as the C++ arm with `directPlanes` and
    /// `lazyImage` sees them: results read, power saving on, no calibration,
    /// an engine that leaves the image to the text lane unless `rendersImage`,
    /// and a lane held by its first read so that it admits no other.
    static func heldLaneRun(_ frames: [CVPixelBuffer], analysis: FrameAnalysis = FrameAnalysis(),
                            rendersImage: Bool, cuts: Set<RecognitionCut> = [.lazyImage]) throws
        -> (counts: [RenderCounts], admitted: Int, snapshots: [GlyphDisplaySnapshot]) {
        let gate = AsyncHeaderGate()
        defer { gate.signal() }
        let engine = RecordingEngine(analysis: analysis, rendersImage: rendersImage)
        let meter = Self.meter()
        let harness = try Harness(keepsLogs: false, readsResults: true, powerSaving: true, engine: engine,
                                  cuts: cuts, meter: meter, headerOperation: { _, time in
            await gate.wait()
            return HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
        })
        var counts: [RenderCounts] = []
        for (index, frame) in frames.enumerated() {
            harness.output.process(try harness.frame(frame, at: Double(index) / 20))
            counts.append(RenderCounts(meter))
        }
        let admitted = harness.output.textReadMetrics.submitted
        gate.signal()
        try harness.waitForTextReads()
        harness.output.close()
        return (counts, admitted, harness.updates.values.map(\.snapshot))
    }

    @Test("Between hacks the footer probe renders only on frames it probes, and then only the footer's label")
    func footerRendersOnlyWhenDue() throws {
        let drone = try Frames.recorded("field-00666"), dark = try Frames.solid()
        var panel = FrameAnalysis()
        panel.gearBounds = GearDropPanelBounds(top: 0.3, bottom: 0.7)
        let scenarios: [(name: String, frames: [CVPixelBuffer], analysis: FrameAnalysis)] = [
            ("gear panel", Array(repeating: drone, count: 20), panel),
            ("drone footer", Array(repeating: drone, count: 40), FrameAnalysis()),
            ("quiet screen", Array(repeating: dark, count: 40), FrameAnalysis())
        ]
        for scenario in scenarios {
            let run = try Self.heldLaneRun(scenario.frames, analysis: scenario.analysis, rendersImage: false)
            let first = run.counts[0], last = try #require(run.counts.last)
            let lane = UInt64(run.admitted)
            #expect(last.analysed > 4 && last.band == 0, "\(scenario.name): \(last)")
            // With a panel on screen the lane's admitted read is a gear read,
            // which takes the whole frame; otherwise it is a header read,
            // which renders only the header's rows.
            let panelReads = scenario.name == "gear panel"
            #expect(last.full == (panelReads ? lane : 0) && last.header == (panelReads ? 0 : lane),
                    "\(scenario.name): \(last), lane \(lane)")
            switch scenario.name {
            case "gear panel":
                #expect(last.probes == 0 && last.footer == 0, "a panel on screen is no time to probe: \(last)")
            case "drone footer":
                // A candidate at 0 closes the gate until 1: nothing renders
                // on the frames between, then one probe in the next second.
                let gated = run.counts[19]
                #expect(first.probes == 1 && gated.probes == 1 && gated.all == first.all,
                        "inside the gate: \(first) then \(gated)")
                #expect(gated.analysed > first.analysed + 2)
                #expect(last.probes == 2 && last.footer == last.probes, "\(last)")
            default:
                // No candidate leaves the gate open: every analysed frame is
                // probed, each on its label alone.
                #expect(last.probes == last.analysed && last.footer == last.probes, "\(last)")
            }
            // The same frames with an engine that renders them: no region
            // render, and nothing else changes.
            let rendered = try Self.heldLaneRun(scenario.frames, analysis: scenario.analysis, rendersImage: true)
            let renderedLast = try #require(rendered.counts.last)
            #expect(renderedLast.footer == 0 && renderedLast.band == 0 && renderedLast.header == 0
                    && renderedLast.full == 0,
                    "\(scenario.name): the engine's own image is cut: \(renderedLast)")
            #expect(renderedLast.probes == last.probes && renderedLast.analysed == last.analysed
                    && rendered.admitted == run.admitted, "\(scenario.name): \(renderedLast) against \(last)")
            #expect(rendered.snapshots == run.snapshots, "\(scenario.name): the snapshots differ")
        }
    }

    /// `frames` at 20 Hz, each frame's text read held until `process` has
    /// returned and finished before the next frame. A read that could finish
    /// inside the frame that submitted it would reach the tracker one frame
    /// early on some runs and not others.
    private static func processReleasingReads(_ harness: Harness, gates: Collected<AsyncHeaderGate>,
                                              frames: [CVPixelBuffer]) throws {
        for (index, frame) in frames.enumerated() {
            let gate = AsyncHeaderGate()
            gates.append(gate)
            harness.output.process(try harness.frame(frame, at: Double(index) / 20))
            gate.signal()
            try harness.waitForTextReads()
        }
    }

    @Test("A lazy lane renders the whole frame only for a panel read, and only the header's rows for a header read")
    func lazyLaneRendersWhatEachReadTakes() throws {
        var panel = FrameAnalysis()
        panel.gearBounds = GearDropPanelBounds(top: 0.3, bottom: 0.7)
        func run(_ frame: CVPixelBuffer, analysis: FrameAnalysis, rendersImage: Bool) throws
            -> (counts: RenderCounts, whole: Int, header: Int) {
            let meter = Self.meter()
            let harness = try Harness(keepsLogs: false, readsGear: true, powerSaving: true,
                                      engine: RecordingEngine(analysis: analysis, rendersImage: rendersImage),
                                      cuts: [.lazyImage], meter: meter, headerOperation: { _, time in
                HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
            })
            for index in 0..<20 {
                harness.output.process(try harness.frame(frame, at: Double(index) / 20))
                try harness.waitForTextReads()
            }
            let counts = RenderCounts(meter), metrics = harness.output.textReadMetrics
            harness.output.close()
            return (counts, metrics.resultSubmitted + metrics.gearSubmitted + metrics.portalSubmitted,
                    metrics.headerInHackSubmitted + metrics.headerOutsideSubmitted)
        }
        let scenarios = [("headers", try Frames.recorded("field-00443"), FrameAnalysis()),
                         ("gear panel", try Frames.recorded("five-bonus"), panel)]
        for (name, frame, analysis) in scenarios {
            let lazy = try run(frame, analysis: analysis, rendersImage: false)
            #expect(lazy.counts.full == UInt64(lazy.whole) && lazy.counts.header == UInt64(lazy.header),
                    "\(name): \(lazy.counts), \(lazy.whole) panel and \(lazy.header) header reads")
            #expect(name == "headers" ? lazy.header > 0 && lazy.whole == 0 : lazy.whole > 0,
                    "\(name): \(lazy.whole) panel and \(lazy.header) header reads")
            // An engine that renders the frame leaves nothing to render: the
            // header's rows are cut from its image.
            let rendered = try run(frame, analysis: analysis, rendersImage: true)
            #expect(rendered.counts.full == 0 && rendered.counts.header == 0, "\(name): \(rendered.counts)")
        }
    }

    @Test("With portal settle, a portal screen is read until one read settles its levels, then not until another screen shows; without it, for as long as it shows")
    func portalSettleStopsReadingASettledScreen() throws {
        // Resistance 0–2 s, no screen 2–4 s, Enlightened 4–5 s, then
        // Resistance again with no gap: three screens.
        let faction: @Sendable (Double) -> PortalFaction? = { time in
            time < 2 - 1e-9 ? .resistance : time < 4 - 1e-9 ? nil : time < 5 - 1e-9 ? .enlightened : .resistance
        }
        func run(cuts: Set<RecognitionCut>) throws -> (reads: [Double], held: UInt64, frames: Int) {
            let reads = Collected<Double>()
            let meter = Self.meter()
            // Gear, and with it the portal screen, is read alongside results.
            let harness = try Harness(keepsLogs: false, readsResults: true, readsGear: true, powerSaving: false,
                                      engine: PortalScreenEngine(faction: faction), cuts: cuts, meter: meter,
                                      headerOperation: { _, time in
                HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
            }, portalOperation: { _, time in
                reads.append(time)
                // Every label read, none unread, and the L8 badge: one read
                // decides the level.
                return PortalScreenEvidence(sourceTime: time, resonators: Array(repeating: 8, count: 8),
                                            unreadSlots: 0, badgeHue: 259, faction: faction(time))
            })
            let dark = try Frames.solid()
            let frames = 120
            for index in 0..<frames {
                harness.output.process(try harness.frame(dark, at: Double(index) / 20))
                try harness.waitForTextReads()
            }
            let held = meter.snapshot().total(.portalHeld).count
            harness.output.close()
            return (reads.values, held, frames)
        }
        let screens: [Range<Double>] = [0..<2, 4..<5, 5..<6]
        func perScreen(_ reads: [Double]) -> [Int] {
            screens.map { screen in reads.filter { screen.contains($0) }.count }
        }
        let settled = try run(cuts: [.portalSettle])
        #expect(perScreen(settled.reads) == [1, 1, 1], "\(settled.reads)")
        #expect(settled.reads.count == 3, "no read without a screen: \(settled.reads)")
        for (screen, read) in zip(screens, settled.reads) {
            #expect(read - screen.lowerBound < 0.3, "each screen is read on arrival: \(settled.reads)")
        }
        // Each frame with a screen and no read wanted is held.
        let portalFrames = (0..<settled.frames).filter { faction(Double($0) / 20) != nil }.count
        #expect(settled.held > 0 && settled.held <= UInt64(portalFrames - 3), "\(settled.held) of \(portalFrames)")
        let all = try run(cuts: [])
        #expect(perScreen(all.reads).allSatisfy { $0 >= 3 }, "\(all.reads)")
        #expect(all.held == 0)
    }

    @Test("With gear settle, a settled drop panel is answered with its settling read while it stays still, a new panel in its place is read at the next look, and the group closes as without it",
          arguments: [true, false])
    func gearSettleAnswersASettledPanel(assistsGlyphs: Bool) throws {
        // A portal panel 0–3 s, then a Bonus panel in the same place with
        // other pixels 3–5 s, then none: one drop group of two panels.
        let bounds = GearDropPanelBounds(top: 0.30, bottom: 0.50)
        let panelAt: @Sendable (Double) -> GearDropPanelBounds? = { $0 < 5 - 1e-9 ? bounds : nil }
        let portal = [GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 5, quantity: 3),
                      GearDropEntry(column: 1, row: 0, item: "Power Cube", levelState: .known, level: 6, quantity: 1)]
        let bonus = [GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 7, quantity: 2)]
        let frames = (portal: try Frames.panel(luma: 90, bounds: bounds), bonus: try Frames.panel(luma: 170, bounds: bounds),
                      none: try Frames.solid())
        struct Run {
            var reads: [Double]
            var held: UInt64
            var drops: [GearDropSummary]
        }
        func run(cuts: Set<RecognitionCut>) throws -> Run {
            let reads = Collected<Double>()
            let meter = Self.meter()
            // With Glyphs, gear is read alongside results.
            let harness = try Harness(keepsLogs: false, readsResults: assistsGlyphs, readsGear: true,
                                      assistsGlyphs: assistsGlyphs, powerSaving: false,
                                      engine: GearPanelEngine(bounds: panelAt), cuts: cuts,
                                      meter: meter, headerOperation: { _, time in
                HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
            }, gearReadingOperation: { _, bounds, time in
                reads.append(time)
                let isPortal = time < 3 - 1e-9
                return GearPanelReading(evidence: GearDropFrameEvidence(
                    sourceTime: time, stage: isPortal ? .portal : .bonus, bounds: bounds,
                    entries: isPortal ? portal : bonus))
            })
            for index in 0..<160 {
                let time = Double(index) / 20
                let buffer = time < 3 - 1e-9 ? frames.portal : time < 5 - 1e-9 ? frames.bonus : frames.none
                harness.output.process(try harness.frame(buffer, at: time))
                try harness.waitForTextReads()
            }
            harness.output.close()
            return Run(reads: reads.values, held: meter.snapshot().total(.gearHeld).count,
                       drops: harness.drops.values.map(\.summary))
        }
        let off = try run(cuts: [])
        let on = try run(cuts: [.gearSettle])
        func reads(_ run: Run, in range: Range<Double>) -> [Double] { run.reads.filter { range.contains($0) } }

        // Without the cut, a panel is read at every gear look while it shows.
        #expect(off.held == 0)
        let offPortal = reads(off, in: 0..<3)
        #expect(offPortal.count >= 12, "\(off.reads)")
        #expect(zip(offPortal, offPortal.dropFirst()).allSatisfy { $1 - $0 < 0.26 }, "\(off.reads)")

        // With it, the portal panel settles on two agreeing reads and is
        // then read for real only once its settling read is a second old.
        let onPortal = reads(on, in: 0..<3)
        #expect(onPortal.count >= 2 && onPortal.count <= 5, "\(on.reads)")
        #expect(zip(onPortal, onPortal.dropFirst()).allSatisfy { $1 - $0 <= GearSettleLimiter.refreshAfter + 0.26 },
                "\(on.reads)")
        // Every due look is answered: held ones stand for reads one for one.
        #expect(on.held > 0 && UInt64(on.reads.count) + on.held == UInt64(off.reads.count),
                "\(on.reads.count) reads and \(on.held) held, against \(off.reads.count) reads")

        // The Bonus panel in the same place has other pixels: it is read at
        // the first gear look after it shows, with the cut as without it.
        let firstBonus = try #require(reads(on, in: 3..<5).first)
        #expect(firstBonus == reads(off, in: 3..<5).first && firstBonus - 3 < 0.26, "\(on.reads)")
        #expect(reads(on, in: 3..<5).count >= 2)
        #expect(reads(on, in: 5..<8).isEmpty && reads(off, in: 5..<8).isEmpty)

        // The same group, closed at the same time, with both panels' rows.
        #expect(off.drops.count == 1 && off.drops.first?.panels.map(\.entries) == [portal, bonus], "\(off.drops)")
        #expect(on.drops == off.drops)
    }

    /// `commands.jsonl`'s rows of one kind, without the fields that name
    /// files.
    static func commandRows(_ directory: URL, kind: String) throws -> [[String: String]] {
        let text = try String(contentsOf: directory.appendingPathComponent("commands.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line -> [String: String]? in
            let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard row["kind"] as? String == kind else { return nil }
            return row.filter { $0.key != "image" && $0.key != "imageStatus" }.mapValues { "\($0)" }
        }
    }

    /// What a run left: its notice rows, renders and snapshots.
    struct CommandRun {
        let rows: [[String: String]]
        let counts: RenderCounts
        let snapshots: [GlyphDisplaySnapshot]
    }

    /// `frames` between hacks with results read and power saving on, each
    /// frame's header read finished before the next.
    static func footerRun(_ frames: [CVPixelBuffer], rendersImage: Bool,
                          cuts: Set<RecognitionCut> = [.lazyImage]) throws -> CommandRun {
        let meter = Self.meter()
        let engine = RecordingEngine(rendersImage: rendersImage)
        let gates = Collected<AsyncHeaderGate>()
        let harness = try Harness(readsResults: true, powerSaving: true, engine: engine, cuts: cuts,
                                  meter: meter, headerOperation: { _, time in
            await gates.values.last?.wait()
            return HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
        })
        try Self.processReleasingReads(harness, gates: gates, frames: frames)
        let counts = RenderCounts(meter)
        _ = try harness.finish()
        let directory = try #require(harness.directory).url
        return CommandRun(rows: try Self.commandRows(directory, kind: "notice"), counts: counts,
                          snapshots: harness.updates.values.map(\.snapshot))
    }

    /// A fitted empty array from the real Swift engine, which the test
    /// engine then reports on every frame: the cached fit and a command
    /// header keep the command screen watched.
    static func fittedEmptyArray() throws -> FrameAnalysis {
        let source = try #require(CGImageSourceCreateWithURL(try TestFixtures.url("field-00381", "png") as CFURL, nil))
        let fitted = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var analysis = try SwiftFrameRecognitionEngine(table: SetupDemo.builtInTable).analyze(
            FrameInput(planes: nil, time: 0) { fitted },
            request: FrameAnalysisRequest(assistsGlyphs: true, searchesArray: true, checksGear: false,
                                          checksPortal: false, readsStrip: true))
        #expect(analysis.observation?.calibration != nil)
        analysis.image = nil
        analysis.timings = FrameStepTimings()
        return analysis
    }

    /// `frames` on a watched command screen (`fittedEmptyArray` and command
    /// headers), each frame's header read finished before the next.
    static func commandRun(_ frames: [CVPixelBuffer], analysis: FrameAnalysis, rendersImage: Bool,
                           cuts: Set<RecognitionCut> = [.lazyImage]) throws -> CommandRun {
        let meter = Self.meter()
        let engine = RecordingEngine(analysis: analysis, rendersImage: rendersImage)
        let gates = Collected<AsyncHeaderGate>()
        let harness = try Harness(readsResults: true, powerSaving: true, engine: engine, cuts: cuts,
                                  meter: meter, headerOperation: { _, time in
            await gates.values.last?.wait()
            return WatchReproductionHarness.header(.command, at: time)
        })
        try Self.processReleasingReads(harness, gates: gates, frames: frames)
        let counts = RenderCounts(meter)
        _ = try harness.finish()
        let directory = try #require(harness.directory).url
        return CommandRun(rows: try Self.commandRows(directory, kind: "notice"), counts: counts,
                          snapshots: harness.updates.values.map(\.snapshot))
    }

    @Test("The footer's label rendered alone is read as the whole frame's crop is: the same drone reads")
    func footerRegionReadsTheSameFooter() throws {
        let frames = Array(repeating: try Frames.recorded("field-00666"), count: 60)
        let region = try Self.footerRun(frames, rendersImage: false)
        let whole = try Self.footerRun(frames, rendersImage: true)
        #expect(region.counts.footer > 0 && whole.counts.footer == 0, "\(region.counts); \(whole.counts)")
        #expect(region.rows.contains { $0["notice"] == "drone" }, "the footer is read: \(region.rows)")
        #expect(region.rows == whole.rows)
        #expect(region.counts.probes == whole.counts.probes)
        #expect(region.snapshots == whole.snapshots)
    }

    @Test("The command band rendered alone gives the same notices as the band cut from the whole frame")
    func bandRegionReadsTheSameNotices() throws {
        let analysis = try Self.fittedEmptyArray()
        let frames = Array(repeating: try NoticeDrawingFrame.make("simple"), count: 30)
        let region = try Self.commandRun(frames, analysis: analysis, rendersImage: false)
        let whole = try Self.commandRun(frames, analysis: analysis, rendersImage: true)
        #expect(region.counts.bandChecks > 10, "the command screen is watched: \(region.counts)")
        #expect(region.counts.band == region.counts.bandChecks && whole.counts.band == 0,
                "\(region.counts); \(whole.counts)")
        #expect(region.counts.bandChecks == whole.counts.bandChecks, "\(region.counts); \(whole.counts)")
        #expect(region.rows.contains { $0["notice"] == "simple" }, "the notice is read: \(region.rows)")
        #expect(region.rows == whole.rows, "\(region.rows) against \(whole.rows)")
        #expect(region.snapshots == whole.snapshots)
    }

    @Test("With the plane gate a quiet dark screen renders nothing once the lane is held, and a dark command band is not rendered")
    func planeGateSkipsDarkRegions() throws {
        let cuts: Set<RecognitionCut> = [.lazyImage, .planeGate]
        let quiet = Array(repeating: try Frames.solid(), count: 40)
        let gated = try Self.heldLaneRun(quiet, rendersImage: false, cuts: cuts)
        let first = gated.counts[0], last = try #require(gated.counts.last)
        // The first frame's admitted read renders the header's rows; after
        // it, nothing at all.
        #expect(gated.admitted == 1 && first.all == first.header && first.header == 1, "\(first)")
        #expect(last.all == first.all && last.analysed > 4, "\(last)")
        #expect(last.probes == 0 && last.footerGated == last.analysed, "every due probe is gated: \(last)")
        let ungated = try Self.heldLaneRun(quiet, rendersImage: false)
        #expect(ungated.snapshots == gated.snapshots)
        #expect(try #require(ungated.counts.last).footer == last.footerGated)

        let analysis = try Self.fittedEmptyArray()
        let blank = Array(repeating: try CommandDrawingFrame.make(), count: 30)
        let command = try Self.commandRun(blank, analysis: analysis, rendersImage: false, cuts: cuts)
        #expect(command.counts.bandChecks > 10 && command.counts.band == 0
                && command.counts.bandGated == command.counts.bandChecks, "\(command.counts)")
        let rendered = try Self.commandRun(blank, analysis: analysis, rendersImage: false)
        #expect(rendered.counts.band == command.counts.bandGated && rendered.snapshots == command.snapshots,
                "\(rendered.counts) against \(command.counts)")
    }

    @Test("The plane gate changes no output: drone footers and notices that come and go on a dark screen read the same with it on and off")
    func planeGateKeepsOutputs() throws {
        let cuts: Set<RecognitionCut> = [.lazyImage, .planeGate]
        let drone = try Frames.recorded("field-00666"), dark = try Frames.solid()
        let droneFrames = Array(repeating: drone, count: 25) + Array(repeating: dark, count: 30)
            + Array(repeating: drone, count: 25)
        let footerOn = try Self.footerRun(droneFrames, rendersImage: false, cuts: cuts)
        let footerOff = try Self.footerRun(droneFrames, rendersImage: false)
        // The pace slows on the still dark stretch, so only some of its
        // frames are analysed and due a probe.
        #expect(footerOn.counts.footerGated > 4 && footerOff.counts.footerGated == 0, "\(footerOn.counts)")
        // A gated probe is one that would have found no candidate: the gate
        // only moves probes from rendered to skipped.
        #expect(footerOn.counts.probes + footerOn.counts.footerGated == footerOff.counts.probes
                && footerOn.counts.footer == footerOn.counts.probes,
                "\(footerOn.counts) against \(footerOff.counts)")
        #expect(footerOn.rows.contains { $0["notice"] == "drone" }, "the footer is read: \(footerOn.rows)")
        #expect(footerOn.rows == footerOff.rows, "\(footerOn.rows) against \(footerOff.rows)")
        #expect(footerOn.snapshots == footerOff.snapshots)

        let analysis = try Self.fittedEmptyArray()
        let notice = try NoticeDrawingFrame.make("simple"), blank = try CommandDrawingFrame.make()
        let noticeFrames = Array(repeating: notice, count: 10) + Array(repeating: blank, count: 10)
            + Array(repeating: notice, count: 10) + Array(repeating: blank, count: 5)
        let bandOn = try Self.commandRun(noticeFrames, analysis: analysis, rendersImage: false, cuts: cuts)
        let bandOff = try Self.commandRun(noticeFrames, analysis: analysis, rendersImage: false)
        #expect(bandOn.counts.bandGated > 5 && bandOff.counts.bandGated == 0, "\(bandOn.counts)")
        #expect(bandOn.counts.band + bandOn.counts.bandGated == bandOff.counts.band
                && bandOn.counts.bandChecks == bandOff.counts.bandChecks,
                "\(bandOn.counts) against \(bandOff.counts)")
        #expect(bandOn.rows.contains { $0["notice"] == "simple" }, "the notice is read: \(bandOn.rows)")
        #expect(bandOn.rows == bandOff.rows, "\(bandOn.rows) against \(bandOff.rows)")
        #expect(bandOn.snapshots == bandOff.snapshots)
    }
}

/// A `FrameRecognitionEngine` that records what it is asked and answers with
/// a fixed analysis. Its gate is the real luma gate, so the pace settles as
/// it does live.
private final class RecordingEngine: FrameRecognitionEngine, @unchecked Sendable {
    struct Call: Sendable {
        let request: FrameAnalysisRequest
        let time: Double
        let hadPlanes: Bool
    }

    let name = "recording"
    private let lock = NSLock()
    private var calls: [Call] = []
    private let analysis: FrameAnalysis
    /// Whether the engine renders the frame's image itself, as the Swift arm
    /// does; off, it leaves the image to the text lane, as one reading the
    /// planes does.
    private let rendersImage: Bool
    private let gateReader = SwiftFrameRecognitionEngine(table: nil)

    init(analysis: FrameAnalysis = FrameAnalysis(), rendersImage: Bool = false) {
        self.analysis = analysis
        self.rendersImage = rendersImage
    }

    var requests: [Call] { lock.withLock { calls } }

    func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading? { gateReader.gate(planes, step: step) }

    func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        lock.withLock { calls.append(Call(request: request, time: input.time, hadPlanes: input.planes != nil)) }
        var analysis = analysis
        if rendersImage { analysis.image = try input.image() }
        return analysis
    }

    func resetSession() {}
    var sessionValidatedAt: Double? { nil }
    var sessionCalibration: NodeArrayDetection? { nil }
}

/// An engine that sees a portal screen of `faction(time)`'s colour, and
/// nothing else.
private final class PortalScreenEngine: FrameRecognitionEngine {
    let name = "portal"
    private let faction: @Sendable (Double) -> PortalFaction?
    private let gateReader = SwiftFrameRecognitionEngine(table: nil)

    init(faction: @escaping @Sendable (Double) -> PortalFaction?) { self.faction = faction }

    func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading? { gateReader.gate(planes, step: step) }

    func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        var analysis = FrameAnalysis()
        if request.checksPortal { analysis.portalFaction = faction(input.time) }
        return analysis
    }

    func resetSession() {}
    var sessionValidatedAt: Double? { nil }
    var sessionCalibration: NodeArrayDetection? { nil }
}

/// An engine that sees a gear drop panel at `bounds(time)`, and nothing
/// else.
private final class GearPanelEngine: FrameRecognitionEngine {
    let name = "gear"
    private let bounds: @Sendable (Double) -> GearDropPanelBounds?
    private let gateReader = SwiftFrameRecognitionEngine(table: nil)

    init(bounds: @escaping @Sendable (Double) -> GearDropPanelBounds?) { self.bounds = bounds }

    func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading? { gateReader.gate(planes, step: step) }

    func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        var analysis = FrameAnalysis()
        if request.checksGear { analysis.gearBounds = bounds(input.time) }
        return analysis
    }

    func resetSession() {}
    var sessionValidatedAt: Double? { nil }
    var sessionCalibration: NodeArrayDetection? { nil }
}

@Suite("Header startup cue")
struct HeaderStartupCueTests {
    @Test("An unchanged waiting header skips intermediate reads but refreshes once a second")
    func headerBetweenHacks() throws {
        let harness = try Harness()
        let buffer = try Frames.solid()
        for index in 0..<40 {
            harness.output.process(try harness.frame(buffer, at: Double(index) * 0.05 + 0.0001))
            try harness.waitForTextReads()
        }
        let rows = try harness.finish()
        #expect(rows.count == 40, "the first two seconds keep 20 Hz, before the pace settles")
        let submitted = try #require(rows.last?["headerSubmitted"] as? Int)
        let metrics = harness.output.textReadMetrics
        #expect(submitted == 2, "Unchanged pixels read initially and refresh once within these two seconds")
        #expect(metrics.headerOutsideSubmitted == 2 && metrics.headerInHackSubmitted == 0)
        #expect(metrics.headerSkippedUnchanged > 0, "The reduced count must come from unchanged suppression")
        var previousSubmitted = 0
        let readTimes = rows.compactMap { row -> Double? in
            guard let count = row["headerSubmitted"] as? Int, count > previousSubmitted else { return nil }
            previousSubmitted = count
            return row["presentationTime"] as? Double
        }
        #expect(readTimes.count == 2)
        #expect(zip(readTimes, readTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.998 && $1 - $0 <= 1.051 },
                "Refresh cannot stall: allow only one 50ms eligible-frame rounding step")
    }

    @Test("Current hack geometry bypasses unchanged startup OCR without inventing a known phase",
          arguments: [false, true])
    func currentHackCueRefreshesUnchangedHeader(_ becomesKnown: Bool) throws {
        let crops = Collected<[UInt8]>(), gate = AsyncHeaderGate()
        defer { gate.signal() }
        let harness = try Harness(readsResults: false, readsGear: false, headerOperation: { image, time in
            if time > 0 { await gate.wait() }
            guard case .frame(let frame) = image else {
                throw Frames.Failure(description: "a lane without lazyImage reads the whole frame")
            }
            let crop = try #require(HeaderTextRecognizer().headerCrop(of: frame))
            let pixels = try ImageDecoder.decodeColor(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            crops.append(pixels.pixels)
            let phase: GamePhase = time > 0 && becomesKnown ? .presenting : .unknown
            return .init(phase: phase, matchedText: phase == .unknown ? "" : phase.rawValue,
                         confidence: phase == .unknown ? 0 : 1, sourceTime: time)
        })
        let map = try Frames.identicalHeader(Frames.nightMap(phase: 0))
        let hack = try Frames.identicalHeader(Frames.recorded("field-00456"))
        #expect(CVPixelBufferGetWidth(map) == 603 && CVPixelBufferGetHeight(map) == 1311)
        #expect(CVPixelBufferGetWidth(hack) == 603 && CVPixelBufferGetHeight(hack) == 1311)
        harness.output.process(try harness.frame(map, at: 0))
        try harness.waitForTextReads()
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 1)
        harness.output.process(try harness.frame(hack, at: 0.5))
        // Hold the new OCR completion until the source frame is fully logged:
        // its phase must not depend on detached-task scheduling speed.
        gate.signal()
        try harness.waitForTextReads()
        #expect(harness.output.textReadMetrics.headerOutsideSubmitted == 2,
                "Current consistent array/slots must bypass content suppression while the prior tracker is inactive")
        #expect(harness.output.textReadMetrics.headerInHackSubmitted == 0,
                "A geometric candidate is not falsely classified as an in-hack OCR submission")
        let readCrops = crops.values
        #expect(readCrops.count == 2)
        if readCrops.count == 2 { #expect(readCrops[0] == readCrops[1], "This reproduces an unchanged actual OCR crop") }
        harness.output.process(try harness.frame(hack, at: 0.55))
        try harness.waitForTextReads()
        let rows = try harness.finish()
        let first = try #require(rows.first)
        let cue = try #require(rows.first { $0["presentationTime"] as? Double == 0.5 })
        let applied = try #require(rows.last)
        #expect(first["phase"] as? String == "inactive" && first["hackID"] as? Int == 0)
        #expect(cue["calibration"] != nil && cue["slotCount"] as? Int == 4)
        #expect(cue["phase"] as? String == "inactive", "Async OCR has not established a phase on its source frame")
        #expect(applied["headerSourceTime"] as? Double == 0.5)
        if becomesKnown {
            #expect(applied["phase"] as? String == "presenting")
            #expect(applied["phaseSource"] as? String == "headerText" && applied["hackID"] as? Int == 1)
        } else {
            #expect(applied["phase"] as? String == "inactive" && applied["hackID"] as? Int == 0,
                    "A selected slot alone has no unselected prelude: unknown OCR must remain unknown")
            #expect(applied["phaseSource"] as? String == "none")
        }
    }
}

// MARK: - Harness

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}

private struct Harness {
    let directory: TemporaryDirectory?
    let output: LiveGlyphOutput
    let updates = Collected<LiveGlyphUpdate>()
    let telemetry = Collected<FrameTelemetry>()
    let results = Collected<HackResultSummary>()
    let drops = Collected<GearDrop>()
    let gear = Collected<HackGearAttachment>()

    /// Unconstrained unless asked: the test machine's own thermal state must
    /// not change the sampling rate under test.
    init(keepsLogs: Bool = true, readsResults: Bool = false, readsGear: Bool = false,
         assistsGlyphs: Bool = true, table: GlyphTable = SetupDemo.builtInTable,
         power: PowerConditions.State = .init(), powerSaving: Bool = true,
         engine: FrameRecognitionEngine? = nil, cuts: Set<RecognitionCut> = [],
         logic: RecognitionLogicChoice? = nil,
         readingMode: ReadingModeSignal? = nil, meter: PowerMeter = .shared,
         headerOperation: GameHeaderReader.HeaderOperation? = nil,
         portalOperation: GameHeaderReader.PortalOperation? = nil,
         gearReadingOperation: GameHeaderReader.GearReadingOperation? = nil) throws {
        let directory = keepsLogs ? try TemporaryDirectory("recognition") : nil
        self.directory = directory
        let updates = updates, telemetry = telemetry, results = results, drops = drops, gear = gear
        let table = assistsGlyphs ? table : nil
        // Nil leaves LiveGlyphOutput to make its own Swift set, as shipped.
        let logicSet = logic.map {
            makeRecognitionLogic(choice: $0, table: table, sequenceTable: nil, sessionID: CaptureSessionID(rawValue: 1),
                                 language: .english, automaticLanguage: false)
        }
        output = try LiveGlyphOutput(
            table: table, sequenceTable: nil,
            sessionID: CaptureSessionID(rawValue: 1),
            directory: directory?.url, readsResults: readsResults, readsGear: readsGear,
            power: PowerConditions(center: NotificationCenter(), read: { power }), powerSaving: powerSaving,
            engine: engine, cuts: cuts, logic: logicSet,
            meter: meter, readingMode: readingMode, headerOperation: headerOperation, portalOperation: portalOperation,
            gearReadingOperation: gearReadingOperation, telemetry: { telemetry.append($0) }, deliverResult: { results.append($0) },
            deliverGear: { gear.append($0) }, deliverDrop: { drops.append($0) }) { updates.append($0) }
    }

    func frame(_ buffer: CVPixelBuffer, status: CaptureFrameStatus = .complete, orientation: UInt32? = nil,
               at time: Double, arrival: Double = 0, gap: Double? = nil, broken: Bool = false) throws -> CapturedFrame {
        var metadata = CaptureFrameMetadata(status: status)
        metadata.orientation = orientation
        return CapturedFrame(sampleBuffer: try Frames.sample(buffer, at: time), metadata: metadata,
                             arrivalUptime: arrival, deliveryGapMilliseconds: gap, continuityBroken: broken)
    }

    /// Waits until the output's text read finishes; fails after `timeout`.
    func waitForTextReads(timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while output.isReadingText {
            guard Date() < deadline else { throw Frames.Failure(description: "A text read took over \(timeout) s") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Closes the output, which flushes its logs, and returns `recognition.jsonl`.
    func finish() throws -> [[String: Any]] {
        output.close()
        let url = try #require(directory).url.appendingPathComponent("recognition.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}

/// Synthetic and recorded frames, shared by the capture tests.
enum Frames {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A recorded Ingress frame of the incoming sequence, with its violet and
    /// gold slot indicators, in the biplanar full-range format iOS captures in.
    /// `field-00443` shows a Glyph mid-presentation; `field-00456` the empty
    /// array between two.
    /// `size` scales the picture to another capture size, as the same screen
    /// on a phone with that one; nil keeps the fixture's own.
    static func recorded(_ name: String = "field-00443", ext: String = "png",
                         size: (width: Int, height: Int)? = nil) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(try TestFixtures.url(name, ext) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "could not decode \(name).png")
        }
        let width = size?.width ?? image.width, height = size?.height ?? image.height
        let bgra = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, [])
        guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(bgra), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(bgra, [])
            throw Failure(description: "could not draw into a BGRA buffer")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(bgra, [])

        let yuv = try pixelBuffer(width: width, height: height,
                                  format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { throw Failure(description: "could not create a pixel transfer session") }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: bgra, to: yuv) == noErr else {
            throw Failure(description: "could not convert the frame to 420f")
        }
        return yuv
    }

    /// Existing redacted map with a synthetic white overlay covering the
    /// strip. It supplies no exit evidence, unlike noMarkers; array-area luma
    /// remains map-like. The mutation is test-only and never saved to disk.
    static func coveredMap() throws -> CVPixelBuffer {
        let buffer = try recorded("frame-02092", ext: "jpg")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let layout = GameUILayout(), height = CVPixelBufferGetHeight(buffer)
        let top = Int(layout.slotStripTop * Double(height)) - 2
        let bottom = Int(ceil(layout.slotStripBottom * Double(height))) + 2
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        for y in max(0, top)..<min(height, bottom) {
            memset(luma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), 220, CVPixelBufferGetWidth(buffer))
        }
        for y in max(0, top / 2)..<min(CVPixelBufferGetHeightOfPlane(buffer, 1), (bottom + 1) / 2) {
            memset(chroma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        }
        return buffer
    }

    /// The redacted map panned sideways: the same kind of screen with
    /// different pixels, as when the player drags the map. Test-only.
    static func shiftedMap(by shift: Int = 120) throws -> CVPixelBuffer {
        let buffer = try recorded("frame-02092", ext: "jpg")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let offset = plane == 0 ? shift : shift & ~1
            var row = [UInt8](repeating: 0, count: rowBytes)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let line = base + y * stride
                for x in 0..<rowBytes { row[x] = line[(x + offset) % rowBytes] }
                row.withUnsafeBufferPointer { line.update(from: $0.baseAddress!, count: rowBytes) }
            }
        }
        return buffer
    }

    /// A synthetic map at night: a dim background just above the gate's dark
    /// level crossed by dim vertical roads that move with `phase`, so the
    /// gate's cells change from one phase to another while the frame stays a
    /// (dim) candidate. Neutral grey: no array, slot strip, timer or text.
    static func nightMap(phase: Int, width: Int = 603, height: Int = 1311) throws -> CVPixelBuffer {
        let buffer = try solid(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            let line = base + y * stride
            for x in 0..<width { line[x] = (x + phase * 24) % 96 < 24 ? 56 : 24 }
        }
        return buffer
    }

    /// The recorded item panel with its title painted over in the panel's own
    /// colour: the detector still finds the panel's frame, but every read
    /// finds no title and reports no panel, as the field's false candidate
    /// did. Test-only; nothing is saved.
    static func untitledPanel() throws -> CVPixelBuffer {
        let buffer = try recorded("five-base")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Between the top border (rows 379-380) and the first item row (440).
        let rows = 386..<434, columns = 20..<542
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in rows { for x in columns { luma[y * lumaStride + x] = 24 } }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in (rows.lowerBound / 2)..<(rows.upperBound / 2) {
            for x in (columns.lowerBound / 2)..<(columns.upperBound / 2) {
                chroma[y * chromaStride + x * 2] = 138      // Cb: the panel's navy
                chroma[y * chromaStride + x * 2 + 1] = 126  // Cr
            }
        }
        return buffer
    }

    /// Test-only neutral paint of the existing full header crop, with a two-row
    /// guard for chroma interpolation. Leaves the recorded indicators/array
    /// intact; no images or synthetic OCR evidence are saved to fixtures.
    static func identicalHeader(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
        let layout = GameUILayout()
        let top = max(0, Int(floor(layout.headerTextTop * Double(height))) - 2)
        let bottom = min(height, Int(ceil(layout.headerTextBottom * Double(height))) + 2)
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        for y in top..<bottom { memset(luma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), 24, width) }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in max(0, top / 2 - 1)..<min(CVPixelBufferGetHeightOfPlane(buffer, 1), (bottom + 1) / 2 + 1) {
            memset(chroma + y * chromaStride, 128, chromaStride)
        }
        return buffer
    }

    /// A black 420f frame: nothing for any reader to find.
    static func solid(width: Int = 603, height: Int = 1311) throws -> CVPixelBuffer {
        let buffer = try pixelBuffer(width: width, height: height,
                                     format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, Int32(0)), (1, Int32(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            memset(base, value, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                                * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }

    /// A black 420f frame whose rows inside `bounds` are grey `luma`: where
    /// a test engine reports a drop panel, painted so that two panels differ.
    static func panel(luma: UInt8, bounds: GearDropPanelBounds, width: Int = 603,
                      height: Int = 1311) throws -> CVPixelBuffer {
        let buffer = try solid(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw Failure(description: "no luma plane")
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in Int(bounds.top * Double(height))..<Int(bounds.bottom * Double(height)) {
            memset(base + y * stride, Int32(luma), width)
        }
        return buffer
    }

    static func sample(_ buffer: CVPixelBuffer, at seconds: Double) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { throw Failure(description: "could not describe the frame") }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { throw Failure(description: "could not wrap the frame") }
        return sample
    }

    private static func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw Failure(description: "could not allocate a \(width)x\(height) pixel buffer")
        }
        return buffer
    }
}

/// Links the meter's measured whole-second count to replay source time. No
/// wall-time sleeps are needed to test the actual rate beside the tint.
private final class ReplayMeterClock: @unchecked Sendable {
    var now: UInt64 = 0
    func set(_ seconds: Double) { now = UInt64((seconds * 1e9).rounded()) }
}
