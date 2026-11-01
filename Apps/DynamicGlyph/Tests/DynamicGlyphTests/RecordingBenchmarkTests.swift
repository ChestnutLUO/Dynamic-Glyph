import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import GlyphRecognition

@Suite("Recording benchmark")
struct RecordingBenchmarkTests {
    private func hack(_ shown: Double, recognised: Double? = nil, phase: TrackingState = .command,
                      id: Int? = 1, glyphs: [String] = []) -> BenchmarkHack {
        BenchmarkHack(firstPhase: phase, shownAt: shown, recognisedAt: recognised ?? shown + 0.2,
                      hackID: id, glyphs: glyphs)
    }

    // MARK: Comparison

    @Test("Hacks pair by time; the same Glyphs both ways are identical")
    func identical() {
        let off = [hack(10, glyphs: ["see", "truth"]), hack(60, glyphs: ["past", "?", "future"])]
        let on = [hack(10.4, recognised: 10.9, glyphs: ["see", "truth"]),
                  hack(60.1, recognised: 61.0, glyphs: ["past", "?", "future"])]
        let comparison = BenchmarkComparison(off: off, on: on)
        #expect(comparison.pairs.count == 2)
        #expect(comparison.pairs.allSatisfy { $0.off != nil && $0.on != nil })
        #expect(comparison.sequencesIdentical)
        #expect(comparison.missedWithPowerSaving.isEmpty)
        // Timed against the Off run's sighting, not the On run's own.
        let first = comparison.pairs[0]
        #expect(abs(BenchmarkComparison.delay(of: first.on!, reference: first.off!) - 0.9) < 1e-9)
    }

    @Test("A hack only the Off run caught is missed with power saving; a different Glyph is a difference")
    func missedAndDifferent() {
        let off = [hack(10, glyphs: ["see"]), hack(40, glyphs: ["a", "b"]), hack(80, glyphs: ["c"])]
        let on = [hack(10.5, glyphs: ["see"]), hack(81, glyphs: ["d"]), hack(200, glyphs: ["e"])]
        let comparison = BenchmarkComparison(off: off, on: on)
        #expect(comparison.pairs.count == 4)
        #expect(comparison.missedWithPowerSaving == [off[1]])
        #expect(!comparison.sequencesIdentical)
        #expect(comparison.pairs[2].off == off[2] && comparison.pairs[2].on == on[1])
        #expect(comparison.pairs[3].off == nil && comparison.pairs[3].on == on[2])

        var offRun = BenchmarkRunResult(powerSaving: false), onRun = BenchmarkRunResult(powerSaving: true)
        offRun.hacks = off
        onRun.hacks = on
        let lines = BenchmarkReport.comparisonLines(off: offRun, on: onRun)
        #expect(lines.contains("identical Glyph sequences: NO"))
        #expect(lines.contains("   MISSED WITH POWER SAVING"))
        #expect(lines.contains("1 hack(s) MISSED WITH POWER SAVING"))
        #expect(lines.contains("   off: c") && lines.contains("   on: d"))
        #expect(lines.contains("   only with power saving"))
        #expect(lines.allSatisfy { $0.count <= BenchmarkReport.width })
    }

    @Test("A late On hack is not paired with an earlier Off one past the next hack")
    func pairingWindow() {
        let off = [hack(10), hack(25)]
        let on = [hack(26, recognised: 26.3)]
        let comparison = BenchmarkComparison(off: off, on: on)
        #expect(comparison.pairs.map { $0.on } == [nil, on[0]])
        // Too early: more than two seconds before the Off sighting.
        #expect(BenchmarkComparison(off: [hack(10)], on: [hack(7, recognised: 7.5)]).missedWithPowerSaving.count == 1)
    }

    // MARK: Hacks from the tracker

    @Test("The recorder times a hack from the header's own frame and keeps its last Glyphs")
    func recorder() {
        var recorder = BenchmarkHackRecorder()
        func trace(_ time: Double, _ state: TrackingState, source: PhaseSource = .headerText, phaseTime: Double? = nil,
                   hackID: Int = 0, events: [TrackingEvent.Kind] = [.phaseChanged],
                   slots: [String?] = []) -> LiveGlyphTrace {
            LiveGlyphTrace(time: time, events: events.map { TrackingEvent(kind: $0, time: time, hackID: hackID, reason: "") },
                           state: state, phaseSource: source, phaseTime: phaseTime ?? time, hackID: hackID,
                           slots: slots.enumerated().map { SlotObservation(index: $0.offset, status: .confirmed,
                                                                           glyph: $0.element.map(GlyphID.init)) })
        }
        recorder.accept(trace(5.4, .command, phaseTime: 5.05))
        recorder.accept(trace(6, .interrupted, source: .none))
        recorder.accept(trace(6.5, .command, phaseTime: 6.4))   // the same screen again
        recorder.accept(trace(8, .presenting, phaseTime: 7.9, hackID: 1, events: [.hackStarted, .phaseChanged]))
        recorder.accept(trace(9, .presenting, hackID: 1, events: [.slotCommitted], slots: ["see", nil]))
        recorder.accept(trace(10, .input, hackID: 1, slots: ["see", "truth"]))
        recorder.accept(trace(40, .command, phaseTime: 39.9, hackID: 1, events: [.evidenceInvalidated, .phaseChanged]))
        recorder.accept(trace(70, .presenting, source: .indicatorTransition, hackID: 2,
                              events: [.hackStarted, .phaseChanged], slots: ["past"]))
        let hacks = recorder.hacks
        #expect(hacks.count == 3)
        #expect(hacks[0] == BenchmarkHack(firstPhase: .command, shownAt: 5.05, recognisedAt: 5.4, hackID: 1,
                                          glyphs: ["see", "truth"]))
        #expect(abs(hacks[0].ownDelay - 0.35) < 1e-9)
        // Left without a presentation: the next one began with no command screen.
        #expect(hacks[1].hackID == nil && hacks[1].shownAt == 39.9)
        #expect(hacks[2] == BenchmarkHack(firstPhase: .presenting, shownAt: 70, recognisedAt: 70, hackID: 2,
                                          glyphs: ["past"]))
    }

    // MARK: Time split

    @Test("Each look's pace holds until the next; gaps are capped and a restarted clock adds nothing")
    func modeClock() {
        var clock = AnalysisModeClock()
        #expect(clock.percent(.active) == nil)
        clock.note(.active, at: 0)
        clock.note(.active, at: 1)       // 1 s active
        clock.note(.resting, at: 1.5)    // 0.5 s active
        clock.note(.quiet, at: 2)        // 0.5 s resting
        clock.note(.quiet, at: 12)       // 10 s quiet, capped at 2
        clock.note(.active, at: 3)       // back in time: nothing counted
        clock.note(.active, at: 3.5)     // 0.5 s active
        #expect(clock.seconds(.active) == 2)
        #expect(clock.seconds(.resting) == 0.5)
        #expect(clock.seconds(.quiet) == 2)
        #expect(clock.total == 4.5)
        #expect(abs((clock.percent(.quiet) ?? 0) - 44.444) < 0.01)
        let lines = PowerReport.modeLines(clock)
        #expect(lines.count == 4 && lines.allSatisfy { $0.count <= 42 })
        #expect(lines[1].hasPrefix("quiet") && lines[1].hasSuffix("44"))
    }

    @Test("The meter keeps the time split for a session only, and shows it in the Power section")
    func meterModes() {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.noteAnalysisMode(.quiet, at: 0)
        meter.noteAnalysisMode(.quiet, at: 1)
        #expect(meter.snapshot().modes.total == 0)
        meter.reset()
        for index in 0...20 { meter.noteAnalysisMode(index < 10 ? .active : .resting, at: 100 + Double(index) * 0.05) }
        let snapshot = meter.snapshot()
        #expect(abs(snapshot.modes.seconds(.active) - 0.5) < 1e-9)
        #expect(abs(snapshot.modes.seconds(.resting) - 0.5) < 1e-9)
        #expect(PowerReport.lines(snapshot).contains { $0.hasPrefix("gate time") })
        meter.end()
        meter.noteAnalysisMode(.active, at: 200)
        #expect(meter.snapshot().modes == snapshot.modes)
    }

    @Test("The newest-only queue counts replaced frames as dropped and shows a depth of one")
    func supersededCount() {
        let meter = PowerMeter(clock: { 5_000_000_000 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let slot = LatestFrameSlot<Int>(observe: { waiting, replaced in
            if replaced { meter.count(.backlogDropped) }
            meter.setQueueDepth(waiting, capacity: 1)
        })
        #expect(slot.put(1))
        #expect(!slot.put(2) && !slot.put(3))
        #expect(meter.snapshot().queueDepth == 1)
        #expect(slot.take() == 3)
        let snapshot = meter.snapshot()
        #expect(snapshot.total(.backlogDropped).count == 2 && snapshot.queueDepth == 0 && snapshot.maxQueueDepth == 1)
        let lines = PowerReport.lines(snapshot)
        #expect(lines.contains { $0.hasPrefix("superseded") })
        #expect(lines.contains("queue now 0 · max 1 of 1"))
    }

    // MARK: Report

    @Test("Every report line fits a phone at 11 pt, long Glyph lists included")
    func reportWidth() {
        var run = BenchmarkRunResult(powerSaving: true)
        run.error = "The file could not be read: a very long reason that needs more than one line to show"
        run.sourceSize = (1206, 2622); run.scaledSize = (603, 1311)
        run.movieDuration = 754.2; run.covered = 754.2; run.wallSeconds = 755
        run.hacks = [hack(612.34, glyphs: ["clear-all", "open-all", "discover", "harmony", "aggressive-x"]),
                     hack(700, id: nil)]
        let lines = BenchmarkReport.lines(run, reference: [hack(612.3)])
        #expect(lines.allSatisfy { $0.count <= BenchmarkReport.width }, "\(lines.filter { $0.count > 42 })")
        #expect(lines.contains("#1 cmd 10:12.3 start +0.24 s"))
        #expect(lines.contains("   no presentation followed"))
        #expect(BenchmarkReport.wrap(String(repeating: "x", count: 100)).allSatisfy { $0.count <= 42 })
        #expect(BenchmarkReport.clock(61.25, tenths: true) == "1:01.2" || BenchmarkReport.clock(61.25, tenths: true) == "1:01.3")
    }

    @Test("The full report compares Glyphs at the accuracy pace and power at the real pace")
    func fullReport() {
        func run(_ powerSaving: Bool, _ pace: BenchmarkPace, hacks: [BenchmarkHack]) -> BenchmarkRunResult {
            var run = BenchmarkRunResult(powerSaving: powerSaving, pace: pace)
            run.sourceSize = (1206, 2622); run.scaledSize = (603, 1311)
            run.movieDuration = 600; run.covered = 600; run.wallSeconds = pace == .accuracy ? 900 : 601
            run.framesDecoded = 36_000; run.framesFed = 12_000
            run.hacks = hacks
            return run
        }
        let full = [hack(10, glyphs: ["a", "b"]), hack(100, glyphs: ["c"])]
        let results = [run(false, .accuracy, hacks: full), run(true, .accuracy, hacks: full),
                       run(false, .realTime, hacks: full), run(true, .realTime, hacks: [full[0]])]
        let lines = BenchmarkReport.report(results)
        #expect(lines.allSatisfy { $0.count <= BenchmarkReport.width }, "\(lines.filter { $0.count > 42 })")
        #expect(lines.filter { $0.hasPrefix("fed/delivered/analysed: 12000/") }.count == 4)
        #expect(lines.contains("== power saving OFF · accuracy =="))
        #expect(lines.contains("== power saving ON · real pace =="))
        // The Glyphs are compared once, from the accuracy pass, where nothing was missed.
        let accuracy = lines.firstIndex(of: "== accuracy: Off vs On ==")
        let realPace = lines.firstIndex(of: "== real pace: Off vs On ==")
        #expect(accuracy != nil && realPace != nil && accuracy! < realPace!)
        #expect(lines.filter { $0.hasPrefix("identical Glyph sequences") } == ["identical Glyph sequences: yes"])
        #expect(!lines.contains { $0.contains("MISSED WITH POWER SAVING") })
        // The real pace still says that it lost one.
        #expect(lines.contains("hacks off 2 · on 1 · 1 MISSED"))
        #expect(lines.contains { $0.hasPrefix("app CPU ") && $0.contains(" -> ") })
        // Without an accuracy pass, the real pace compares the Glyphs itself.
        let realOnly = BenchmarkReport.report(Array(results[2...]))
        #expect(realOnly.contains("1 hack(s) MISSED WITH POWER SAVING"))
    }

    // MARK: The driver on a movie

    /// The fixture hack: map, command channel, the presentation, input, completion.
    private static let script: [(String, String, Double)] = [
        ("frame-02092", "jpg", 1.0), ("field-00381", "png", 3.0), ("field-00443", "png", 1.0),
        ("field-00456", "png", 0.6), ("field-00472", "png", 0.6), ("field-00492", "png", 1.0),
        ("field-00615", "png", 1.0)
    ]

    private static let configuration = BenchmarkConfiguration(
        table: SetupDemo.builtInTable, sequenceTable: nil, readsResults: true, readsGear: false,
        language: .english, automaticLanguage: false)

    /// One run on a thread of its own, as in the app.
    private static func run(_ movie: URL, powerSaving: Bool, pace: BenchmarkPace) async throws -> BenchmarkRunResult {
        let source = try await BenchmarkFrameSource(url: movie)
        let runner = BenchmarkRunner(configuration: configuration, powerSaving: powerSaving, pace: pace,
                                     cancellation: BenchmarkCancellation())
        let box = SourceBox(source: source)
        return await withCheckedContinuation { done in
            Thread { done.resume(returning: runner.run(box.source)) }.start()
        }
    }

    @Test("The accuracy pass drops no frame and repeats exactly", .timeLimit(.minutes(5)))
    func accuracy() async throws {
        let directory = try TemporaryDirectory("benchmark-accuracy")
        let movie = directory.url.appendingPathComponent("hack.mov")
        let frames = try MovieMaker.write(Self.script, to: movie, scale: 2, framesPerSecond: 20)
        let first = try await Self.run(movie, powerSaving: false, pace: .accuracy)
        let second = try await Self.run(movie, powerSaving: false, pace: .accuracy)
        let on = try await Self.run(movie, powerSaving: true, pace: .accuracy)
        for result in [first, second, on] {
            #expect(result.error == nil && !result.cancelled && result.pace == .accuracy)
            #expect(result.framesDecoded == frames && result.framesFed == frames)
            let counts = BenchmarkReport.frameCounts(result)
            #expect(counts.delivered == UInt64(frames), "every fed frame reaches the pipeline")
            #expect(result.power.total(.backlogDropped).count == 0)
            #expect(counts.analysed > 0)
        }
        // Twice the same: what was read, when, and how much work it took.
        #expect(!first.hacks.isEmpty)
        #expect(first.hacks == second.hacks)
        #expect(BenchmarkReport.frameCounts(first) == BenchmarkReport.frameCounts(second))
        for metric in PowerMetric.textReads {
            #expect(first.power.total(metric).count == second.power.total(metric).count, "\(metric.label)")
        }
        #expect(first.power.modes == second.power.modes)
        // Without power saving every 20-Hz frame is analysed.
        #expect(BenchmarkReport.frameCounts(first).analysed == UInt64(frames))
        let lines = BenchmarkReport.report([first, on])
        print("ACCURACY REPORT\n" + lines.joined(separator: "\n") + "\nEND ACCURACY REPORT")
        #expect(lines.allSatisfy { $0.count <= BenchmarkReport.width }, "\(lines.filter { $0.count > 42 })")
        #expect(lines.contains("== accuracy: Off vs On =="))
        #expect(lines.contains { $0.hasPrefix("identical Glyph sequences") })
    }

    @Test("A movie made from fixtures runs through the pipeline in real time, off then on", .timeLimit(.minutes(2)))
    func driver() async throws {
        let directory = try TemporaryDirectory("benchmark")
        let movie = directory.url.appendingPathComponent("hack.mov")
        let frames = try MovieMaker.write(Self.script, to: movie, scale: 2, framesPerSecond: 20)
        let source = try await BenchmarkFrameSource(url: movie)
        #expect(source.sourceSize == (1206, 2622) && source.scaledSize == (603, 1311))
        var results: [BenchmarkRunResult] = []
        for powerSaving in BenchmarkMode.both.runs {
            results.append(try await Self.run(movie, powerSaving: powerSaving, pace: .realTime))
        }
        let duration = Self.script.map(\.2).reduce(0, +)
        for result in results {
            #expect(result.error == nil && !result.cancelled && result.pace == .realTime)
            #expect(result.framesDecoded == frames)
            #expect(abs(result.framesFed - frames) <= 1, "\(result.framesFed) of \(frames) frames fed")
            // Real time: never faster than the movie.
            #expect(result.wallSeconds >= result.covered - 0.05 && result.covered > duration - 0.2)
            let power = result.power
            #expect(power.total(.framesDelivered).count + power.total(.backlogDropped).count == UInt64(result.framesFed))
            #expect(power.total(.framesAnalysed).count > 0)
            // The split runs from the first frame the gate looked at to the
            // last: a few frames short of the movie when power saving skips them.
            #expect(power.modes.total <= result.covered + 0.05 && power.modes.total > result.covered - 0.5,
                    "\(power.modes.total) s split of \(result.covered)")
            #expect(BenchmarkReport.lines(result).allSatisfy { $0.count <= BenchmarkReport.width })
        }
        let off = results[0], on = results[1]
        #expect(off.power.modes.seconds(.active) == off.power.modes.total)
        #expect(!off.hacks.isEmpty, "the command channel or the presentation starts a hack")
        let lines = BenchmarkReport.report([off, on])
        // In the test log, as a sample of the report.
        print("BENCHMARK REPORT\n" + lines.joined(separator: "\n") + "\nEND BENCHMARK REPORT")
        #expect(lines.allSatisfy { $0.count <= BenchmarkReport.width })
        #expect(lines.contains("== real pace: Off vs On =="))
        #expect(lines.contains { $0.hasPrefix("identical Glyph sequences") })
        #expect(lines.contains { $0.hasPrefix("app CPU ") && $0.contains(" -> ") })
    }
}

private struct SourceBox: @unchecked Sendable {
    let source: BenchmarkFrameSource
}

/// Writes fixture frames into an H.264 movie, as a screen recording would
/// hold them: scaled up by `scale`, each held for its seconds.
private enum MovieMaker {
    static func write(_ script: [(String, String, Double)], to url: URL, scale: Int,
                      framesPerSecond: Int) throws -> Int {
        let images = try script.map { name, ext, _ -> CGImage in
            guard let source = CGImageSourceCreateWithURL(try TestFixtures.url(name, ext) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Frames.Failure(description: "could not decode \(name).\(ext)")
            }
            return image
        }
        let width = images[0].width * scale, height = images[0].height * scale
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Frames.Failure(description: "writer did not start") }
        writer.startSession(atSourceTime: .zero)
        var frame = 0
        for (index, image) in images.enumerated() {
            let buffer = try draw(image, width: width, height: height)
            for _ in 0..<Int((script[index].2 * Double(framesPerSecond)).rounded()) {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                          timescale: CMTimeScale(framesPerSecond))) else {
                    throw writer.error ?? Frames.Failure(description: "frame \(frame) was not written")
                }
                frame += 1
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? Frames.Failure(description: "movie not finished") }
        return frame
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw Frames.Failure(description: "could not allocate a frame")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Frames.Failure(description: "could not draw a frame") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
