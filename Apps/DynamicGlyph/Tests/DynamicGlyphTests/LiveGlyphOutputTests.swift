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

    @Test("Without a shape list only gear is read, whatever the result switches say")
    func gearOnlySwitches() throws {
        let harness = try Harness(keepsLogs: false, assistsGlyphs: false)
        #expect(!harness.output.assistsGlyphs && harness.output.readsGear)
        // A Glyph on screen is not looked for: the display only watches for gear.
        harness.output.process(try harness.frame(try Frames.recorded(), at: 0))
        harness.output.close()
        let snapshot = try #require(harness.updates.values.last?.snapshot)
        #expect(snapshot.slots.isEmpty && snapshot.provisionalGlyph == nil)
        #expect(snapshot.gear == GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
    }

    @Test("Gear-only capture saves a drop group with what its panel showed")
    func gearOnlyDrop() throws {
        let harness = try Harness(keepsLogs: true, assistsGlyphs: false)
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

    @Test("Frames arriving after close are ignored")
    func afterClose() throws {
        let harness = try Harness()
        harness.output.close()
        harness.output.process(try harness.frame(try Frames.solid(), at: 0))
        #expect(harness.updates.values.isEmpty)
        #expect(harness.telemetry.values.isEmpty)
    }
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
            let crop = try #require(HeaderTextRecognizer().headerCrop(of: image))
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
         assistsGlyphs: Bool = true, power: PowerConditions.State = .init(), powerSaving: Bool = true,
         readingMode: ReadingModeSignal? = nil, meter: PowerMeter = .shared,
         headerOperation: GameHeaderReader.HeaderOperation? = nil) throws {
        let directory = keepsLogs ? try TemporaryDirectory("recognition") : nil
        self.directory = directory
        let updates = updates, telemetry = telemetry, results = results, drops = drops, gear = gear
        output = try LiveGlyphOutput(
            table: assistsGlyphs ? SetupDemo.builtInTable : nil, sequenceTable: nil,
            sessionID: CaptureSessionID(rawValue: 1),
            directory: directory?.url, readsResults: readsResults, readsGear: readsGear,
            power: PowerConditions(center: NotificationCenter(), read: { power }), powerSaving: powerSaving,
            meter: meter, readingMode: readingMode, headerOperation: headerOperation, telemetry: { telemetry.append($0) }, deliverResult: { results.append($0) },
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
