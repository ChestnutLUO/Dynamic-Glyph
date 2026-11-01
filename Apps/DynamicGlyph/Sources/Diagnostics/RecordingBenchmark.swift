import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import GlyphRecognition

// The recording benchmark: a screen recording from Files, fed through the
// capture pipeline (`LiveGlyphOutput`) at the pace live capture feeds it, with
// power saving off, on, or both one after the other. A tester tool for
// TestFlight builds; nothing it reads reaches the results, the statistics,
// the Live Activity, the floating window or the Power section's live figures.

/// Which pipeline the benchmark runs.
enum BenchmarkMode: String, CaseIterable, Sendable {
    case off, on, both

    /// The runs, in order: Both runs the old pipeline first, so the new one
    /// can be compared with it.
    var runs: [Bool] {
        switch self {
        case .off: return [false]
        case .on: return [true]
        case .both: return [false, true]
        }
    }
}

/// How a run feeds the pipeline.
enum BenchmarkPace: String, Sendable {
    /// Every admitted frame, each finished (text reads included) before the
    /// next; as fast as the phone goes. Deterministic, for what is read.
    case accuracy
    /// At the movie's pace, dropping what live capture would drop. For power.
    case realTime

    var label: String { self == .accuracy ? "accuracy" : "real pace" }
}

/// Which passes the benchmark runs; each with the power saving runs chosen.
enum BenchmarkPasses: String, CaseIterable, Sendable {
    case accuracy, realTime, both

    /// Accuracy first: its hacks are the reference for the comparison.
    var paces: [BenchmarkPace] {
        switch self {
        case .accuracy: return [.accuracy]
        case .realTime: return [.realTime]
        case .both: return [.accuracy, .realTime]
        }
    }
}

/// What a run reads with: the capture settings at the time the run started.
struct BenchmarkConfiguration: @unchecked Sendable {
    // Unchecked for the tables, immutable values shared read-only.
    var table: GlyphTable?
    var sequenceTable: SequenceTable?
    var readsResults: Bool
    var readsGear: Bool
    var language: GameLanguage
    var automaticLanguage: Bool
}

/// Set from any thread to stop a run at its next frame.
final class BenchmarkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum BenchmarkError: Error, CustomStringConvertible {
    case noVideoTrack
    case rotated
    case unreadable(String)
    case stalled

    var description: String {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .rotated: return "The recording is landscape; Ingress is portrait."
        case .unreadable(let reason): return "The file could not be read: \(reason)"
        case .stalled: return "A text read did not finish within a minute."
        }
    }
}

// MARK: - Frames from a movie

/// Decodes a movie into the frames live capture hands recognition: full-range
/// 4:2:0, scaled to `BroadcastChannel.targetWidth` wide in proportion and
/// never up, which is what the broadcast extension publishes on iOS 18-26 and
/// what ScreenCaptureKit's half-size stream gives on a 1206-pixel iPhone, at
/// most 20 per second by presentation time, as the extension admits them.
final class BenchmarkFrameSource {
    let duration: Double
    let sourceSize: (width: Int, height: Int)
    let scaledSize: (width: Int, height: Int)
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastAdmitted = -Double.infinity
    private var firstTime: Double?
    /// Frames decoded so far, admitted or not.
    private(set) var decoded = 0

    /// The extension's 20-Hz admission, less a millisecond of jitter.
    static let minimumInterval = 0.049

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BenchmarkError.noVideoTrack
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        // A quarter turn either way swaps the axes: such a file plays landscape.
        if abs(transform.b) > 0.5, abs(transform.c) > 0.5 { throw BenchmarkError.rotated }
        duration = try await asset.load(.duration).seconds
        sourceSize = (Int(natural.width.rounded()), Int(natural.height.rounded()))
        scaledSize = BroadcastChannel.scaledSize(width: sourceSize.width, height: sourceSize.height)
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw BenchmarkError.unreadable(error.localizedDescription)
        }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BenchmarkError.unreadable("no decodable video") }
        reader.add(output)
        guard reader.startReading() else {
            throw BenchmarkError.unreadable(reader.error?.localizedDescription ?? "reading did not start")
        }
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        transfer = session
    }

    deinit {
        reader.cancelReading()
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    /// The next admitted frame and its time from the movie's first frame;
    /// nil at the end. Frames closer than 20 Hz to the last one are skipped
    /// before scaling.
    func next() throws -> (pixels: CVPixelBuffer, time: Double)? {
        while let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard presentation.isFinite, let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            decoded += 1
            guard presentation < lastAdmitted || presentation - lastAdmitted >= Self.minimumInterval else { continue }
            lastAdmitted = presentation
            if firstTime == nil { firstTime = presentation }
            guard let scaled = scale(source) else { throw BenchmarkError.unreadable("a frame could not be scaled") }
            return (scaled, presentation - (firstTime ?? presentation))
        }
        if reader.status == .failed {
            throw BenchmarkError.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        return nil
    }

    func cancel() { reader.cancelReading() }

    private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = scaledSize
        guard size.width > 0, size.height > 0, let transfer else { return nil }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        var scaled: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaled) == kCVReturnSuccess,
              let scaled, VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr
        else { return nil }
        return scaled
    }
}

// MARK: - Hacks as the tracker saw them

/// One hack as the presentation tracker saw it begin, and the Glyphs it read.
struct BenchmarkHack: Equatable, Sendable {
    /// The phase the hack was first recognised in: the command channel, or
    /// the presentation when no command screen was recognised before it.
    var firstPhase: TrackingState
    /// When the pipeline first saw that phase: the source time of the frame
    /// whose header read established it, or the frame's own time when the
    /// slot strip did. Seconds from the movie's first frame.
    var shownAt: Double
    /// The frame at which the tracker changed to that phase.
    var recognisedAt: Double
    /// Nil when the command screen was left without a presentation.
    var hackID: Int?
    /// One entry per slot: the Glyph's name, or "?" for a missed one.
    var glyphs: [String] = []

    /// How long the pipeline took against its own first sighting.
    var ownDelay: Double { recognisedAt - shownAt }
}

/// Turns the tracker's events into hacks. Fed on the recognition queue only.
struct BenchmarkHackRecorder: Sendable {
    /// A command screen recognised again within this time is the same one.
    static let commandRepeat = 30.0
    /// A presentation this soon after a command screen is that hack's.
    static let commandToPresentation = 20.0
    private(set) var hacks: [BenchmarkHack] = []
    private var previousState: TrackingState = .inactive
    /// Index of a command-channel hack still waiting for its presentation.
    private var open: Int?

    mutating func accept(_ trace: LiveGlyphTrace) {
        let byHeader = trace.phaseSource == .headerText
        let shown = byHeader ? min(trace.phaseTime ?? trace.time, trace.time) : trace.time
        if trace.state == .command, previousState != .command {
            if let open, trace.time - hacks[open].recognisedAt < Self.commandRepeat {
                // The same command screen, recognised again after a gap.
            } else {
                hacks.append(BenchmarkHack(firstPhase: .command, shownAt: shown, recognisedAt: trace.time))
                open = hacks.count - 1
            }
        }
        for event in trace.events where event.kind == .hackStarted {
            if let index = open, event.time - hacks[index].recognisedAt <= Self.commandToPresentation {
                hacks[index].hackID = event.hackID
            } else {
                hacks.append(BenchmarkHack(firstPhase: .presenting, shownAt: min(shown, event.time),
                                           recognisedAt: event.time, hackID: event.hackID))
            }
            open = nil
        }
        // The slots as they stand; a hack keeps the last non-empty list, as
        // the next command screen empties the tracker's.
        if !trace.slots.isEmpty, let index = hacks.lastIndex(where: { $0.hackID == trace.hackID }) {
            hacks[index].glyphs = trace.slots.map { $0.glyph?.name ?? "?" }
        }
        previousState = trace.state
    }
}

// MARK: - One run

struct BenchmarkRunResult: Sendable {
    var powerSaving: Bool
    var pace: BenchmarkPace = .realTime
    var cancelled = false
    var error: String?
    var sourceSize: (width: Int, height: Int) = (0, 0)
    var scaledSize: (width: Int, height: Int) = (0, 0)
    var movieDuration = 0.0
    /// Seconds of the movie fed, by presentation time.
    var covered = 0.0
    var wallSeconds = 0.0
    var framesFed = 0
    /// Frames in the movie up to where the run stopped; `framesFed` of them
    /// passed the 20-Hz admission.
    var framesDecoded = 0
    /// Producer thread CPU: decoding hand-off and scaling, within the app's CPU.
    var decodeCPUSeconds = 0.0
    var thermalAtStart = 0
    var lowPowerAtStart = false
    var power = PowerSnapshot()
    var hacks: [BenchmarkHack] = []
}

/// Feeds one movie through a fresh `LiveGlyphOutput`, in real time or, for
/// accuracy, frame by frame.
///
/// Like the broadcast link: a producer thread (this one) hands frames to one
/// serial recognition queue, as many as 40 queued with power saving off and
/// only the newest waiting with it on. Each frame is handed over when its
/// presentation time comes, measured from the first, so recognition, the
/// text reads behind it and the gate see the timing a live capture has.
///
/// The accuracy pace drops nothing: each admitted frame is processed and its
/// text read, if one started, finished before the next is handed over. The
/// pipeline only ever sees the movie's presentation times, so its 20-Hz
/// throttle, the gate and the header cadence act as they would live; only
/// the race between frames and text reads is taken out, which makes a run
/// repeatable.
final class BenchmarkRunner: @unchecked Sendable {
    private let configuration: BenchmarkConfiguration
    private let powerSaving: Bool
    private let pace: BenchmarkPace
    private let cancellation: BenchmarkCancellation
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var pending = 0

    init(configuration: BenchmarkConfiguration, powerSaving: Bool, pace: BenchmarkPace = .realTime,
         cancellation: BenchmarkCancellation, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.configuration = configuration
        self.powerSaving = powerSaving
        self.pace = pace
        self.cancellation = cancellation
        self.progress = progress
    }

    /// Blocks for the movie's length, or as long as the accuracy pace takes.
    /// Call on a thread of its own.
    func run(_ source: BenchmarkFrameSource) -> BenchmarkRunResult {
        var result = BenchmarkRunResult(powerSaving: powerSaving, pace: pace)
        result.sourceSize = source.sourceSize
        result.scaledSize = source.scaledSize
        result.movieDuration = source.duration
        result.thermalAtStart = ProcessInfo.processInfo.thermalState.rawValue
        result.lowPowerAtStart = ProcessInfo.processInfo.isLowPowerModeEnabled

        let meter = PowerMeter()
        // Fresh: nothing learned in capture or in an earlier run carries over,
        // and what this run finds is not remembered for the next capture.
        let languages = GameLanguageMemory(language: configuration.language,
                                           isAutomatic: configuration.automaticLanguage)
        let recorder = Locked(BenchmarkHackRecorder())
        let queue = DispatchQueue(label: "org.szres.DynamicGlyph.benchmark.recognition", qos: .userInitiated)
        let output: LiveGlyphOutput
        do {
            output = try LiveGlyphOutput(
                table: configuration.table, sequenceTable: configuration.sequenceTable,
                sessionID: CaptureSessionID(rawValue: UInt64.random(in: 1..<UInt64.max)),
                directory: nil, readsResults: configuration.readsResults, readsGear: configuration.readsGear,
                languages: languages,
                // Pinned: Low Power Mode or heat during one run and not the
                // other would make the two incomparable.
                power: PowerConditions(center: NotificationCenter(), read: { .init() }),
                powerSaving: powerSaving, meter: meter,
                trace: { trace in recorder.withLock { $0.accept(trace) } },
                telemetry: { _ in }, deliverResult: { _ in }) { _ in }
        } catch {
            result.error = String(describing: error)
            return result
        }
        let latest = LatestFrameSlot<CapturedFrame>(merge: CapturedFrame.superseding) { waiting, replaced in
            if replaced { meter.count(.backlogDropped) }
            meter.setQueueDepth(waiting, capacity: 1)
        }

        // Vision's reads are timed through one process-wide hook: pointed at
        // this run's meter while it runs, and back at the live one after.
        meter.reset(languages: languages)
        meter.observeTextReads()
        defer { PowerMeter.shared.observeTextReads() }

        let threadCPU = { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
        let cpuStarted = threadCPU()
        var wallStart: Double?
        var lastArrival: Double?
        do {
            while !cancellation.isCancelled, let next = try source.next() {
                let (pixels, time) = next
                let start = wallStart ?? ProcessInfo.processInfo.systemUptime
                wallStart = start
                if pace == .accuracy {
                    // Movie time throughout: the arrival is the frame's own.
                    let frame = CapturedFrame(
                        sampleBuffer: try Self.sample(pixels, at: time),
                        metadata: CaptureFrameMetadata(status: .complete),
                        arrivalUptime: time,
                        deliveryGapMilliseconds: lastArrival.map { (time - $0) * 1000 },
                        continuityBroken: false)
                    lastArrival = time
                    queue.sync { output.process(frame) }
                    try waitForTextRead(output)
                    result.framesFed += 1
                    result.covered = time
                    if source.duration > 0 { progress(min(1, time / source.duration)) }
                    continue
                }
                // Waits in short steps, so Cancel is prompt.
                while !cancellation.isCancelled {
                    let wait = start + time - ProcessInfo.processInfo.systemUptime
                    guard wait > 0 else { break }
                    Thread.sleep(forTimeInterval: min(wait, 0.05))
                }
                guard !cancellation.isCancelled else { break }
                let arrival = ProcessInfo.processInfo.systemUptime
                let frame = CapturedFrame(
                    sampleBuffer: try Self.sample(pixels, at: time),
                    metadata: CaptureFrameMetadata(status: .complete),
                    arrivalUptime: arrival,
                    deliveryGapMilliseconds: lastArrival.map { (arrival - $0) * 1000 },
                    continuityBroken: false)
                lastArrival = arrival
                deliver(frame, to: output, on: queue, newestOnly: powerSaving, latest: latest, meter: meter)
                result.framesFed += 1
                result.covered = time
                if source.duration > 0 { progress(min(1, time / source.duration)) }
            }
        } catch {
            result.error = String(describing: error)
        }
        result.framesDecoded = source.decoded
        result.decodeCPUSeconds = Double(threadCPU() &- cpuStarted) / 1e9
        result.cancelled = cancellation.isCancelled
        source.cancel()
        // What was handed over is finished, then the output closed on its queue.
        queue.sync {}
        queue.sync { output.close() }
        meter.end()
        result.wallSeconds = wallStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        result.power = meter.snapshot()
        result.hacks = recorder.withLock { $0.hacks }
        return result
    }

    /// Until the text read the last frame started has finished, so the next
    /// frame finds its result, as a live frame does when reads keep up.
    private func waitForTextRead(_ output: LiveGlyphOutput) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while output.isReadingText, !cancellation.isCancelled {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw BenchmarkError.stalled }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func deliver(_ frame: CapturedFrame, to output: LiveGlyphOutput, on queue: DispatchQueue,
                         newestOnly: Bool, latest: LatestFrameSlot<CapturedFrame>, meter: PowerMeter) {
        if newestOnly {
            guard latest.put(frame) else { return }
            queue.async {
                guard let frame = latest.take() else { return }
                output.process(frame)
            }
            return
        }
        let admitted = lock.withLock { () -> Bool in
            guard pending < BenchmarkRunner.maximumPending else { return false }
            pending += 1
            meter.setQueueDepth(pending, capacity: BenchmarkRunner.maximumPending)
            return true
        }
        guard admitted else { meter.count(.backlogDropped); return }
        queue.async { [self] in
            output.process(frame)
            lock.withLock {
                pending -= 1
                meter.setQueueDepth(pending, capacity: BenchmarkRunner.maximumPending)
            }
        }
    }

    /// The broadcast link's backlog without power saving.
    static let maximumPending = 40

    static func sample(_ buffer: CVPixelBuffer, at seconds: Double) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { throw BenchmarkError.unreadable("a frame could not be described") }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { throw BenchmarkError.unreadable("a frame could not be wrapped") }
        return sample
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

// MARK: - Comparison

/// Off and On hacks paired by time, and what differs between them.
struct BenchmarkComparison: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        var off: BenchmarkHack?
        var on: BenchmarkHack?
    }

    /// In the order the hacks happened; an unpaired side is nil.
    let pairs: [Pair]

    /// An On hack belongs to an Off hack when it was recognised from
    /// `early` seconds before that hack was shown to `late` seconds after,
    /// and before the next Off hack was shown.
    static let early = 2.0
    static let late = 20.0

    init(off: [BenchmarkHack], on: [BenchmarkHack]) {
        let offs = off.sorted { $0.shownAt < $1.shownAt }
        let ons = on.sorted { $0.recognisedAt < $1.recognisedAt }
        var used = Set<Int>()
        var pairs: [Pair] = []
        for (index, hack) in offs.enumerated() {
            var end = hack.shownAt + Self.late
            if index + 1 < offs.count { end = min(end, offs[index + 1].shownAt) }
            let match = ons.indices.first {
                !used.contains($0) && ons[$0].recognisedAt >= hack.shownAt - Self.early && ons[$0].recognisedAt < end
            }
            if let match { used.insert(match) }
            pairs.append(Pair(off: hack, on: match.map { ons[$0] }))
        }
        for index in ons.indices where !used.contains(index) {
            pairs.append(Pair(off: nil, on: ons[index]))
        }
        self.pairs = pairs.sorted { ($0.off?.shownAt ?? $0.on!.recognisedAt) < ($1.off?.shownAt ?? $1.on!.recognisedAt) }
    }

    /// The Glyphs read, hack by hack, are the same both ways.
    var sequencesIdentical: Bool {
        pairs.allSatisfy { ($0.off?.glyphs ?? []) == ($0.on?.glyphs ?? []) }
    }

    /// Off hacks with no On counterpart.
    var missedWithPowerSaving: [BenchmarkHack] { pairs.compactMap { $0.on == nil ? $0.off : nil } }

    /// How much later power saving recognised the hack, against the Off
    /// run's sighting of it.
    static func delay(of on: BenchmarkHack, reference off: BenchmarkHack) -> Double {
        on.recognisedAt - off.shownAt
    }
}

// MARK: - Report

/// The benchmark's text: short monospaced lines, not localized, like the
/// Power section's.
enum BenchmarkReport {
    static let width = 42

    /// Each run, then Off against On at each pace. The accuracy pass, when
    /// run, compares the Glyphs and hack starts; the real pace the power.
    static func report(_ results: [BenchmarkRunResult]) -> [String] {
        var lines: [String] = []
        func off(_ pace: BenchmarkPace) -> BenchmarkRunResult? {
            results.first { !$0.powerSaving && $0.pace == pace }
        }
        func on(_ pace: BenchmarkPace) -> BenchmarkRunResult? {
            results.first { $0.powerSaving && $0.pace == pace }
        }
        for result in results {
            if !lines.isEmpty { lines.append("") }
            // In Both, the On run's hack starts are timed against the Off run's.
            let reference = result.powerSaving ? off(result.pace)?.hacks : nil
            lines += BenchmarkReport.lines(result, reference: reference)
        }
        let accuracyCompared = off(.accuracy) != nil && on(.accuracy) != nil
        for pace in [BenchmarkPace.accuracy, .realTime] {
            guard let off = off(pace), let on = on(pace) else { continue }
            lines.append("")
            lines += BenchmarkReport.comparisonLines(off: off, on: on,
                                                     hacks: pace == .accuracy || !accuracyCompared)
        }
        return lines
    }

    /// The frames a run fed, the pipeline received and analysed.
    static func frameCounts(_ run: BenchmarkRunResult) -> (fed: UInt64, delivered: UInt64, analysed: UInt64) {
        (UInt64(run.framesFed), run.power.total(.framesDelivered).count, run.power.total(.framesAnalysed).count)
    }

    /// One run. `reference` is the Off run's hacks, which time the On run's
    /// hack starts in Both; alone, a run is timed against its own sightings.
    static func lines(_ run: BenchmarkRunResult, reference: [BenchmarkHack]? = nil) -> [String] {
        var lines: [String] = []
        lines.append("== power saving \(run.powerSaving ? "ON" : "OFF") · \(run.pace.label) ==")
        let counts = frameCounts(run)
        lines.append("fed/delivered/analysed: \(counts.fed)/\(counts.delivered)/\(counts.analysed)")
        if run.cancelled { lines.append("CANCELLED") }
        if let error = run.error { lines += wrap("error: " + error) }
        lines.append(String(format: "movie %@ of %@ · ran %@", clock(run.covered), clock(run.movieDuration),
                            clock(run.wallSeconds)))
        if run.pace == .accuracy { lines.append("  frame by frame, not real time") }
        lines.append("decoded \(run.framesDecoded) · 20 Hz admitted \(run.framesFed)")
        lines.append(String(format: "%dx%d -> %dx%d 420f", run.sourceSize.width, run.sourceSize.height,
                            run.scaledSize.width, run.scaledSize.height))
        let s = run.power
        if run.pace == .accuracy {
            // Nothing dropped and no clock: only what decides the reading.
            lines += PowerReport.modeLines(s.modes)
            lines.append(PowerReport.row("text read", "n"))
            for metric in PowerMetric.textReads where s.total(metric).count > 0 {
                lines.append(PowerReport.row(metric.label, "\(s.total(metric).count)"))
            }
            lines += hackLines(run, reference: reference)
            return lines
        }
        let cpuPercent = run.wallSeconds > 0 ? s.cpuSeconds / run.wallSeconds * 100 : 0
        lines.append(String(format: "app CPU %.1f s · %.0f%% of a core", s.cpuSeconds, cpuPercent))
        if run.covered >= 1 {
            lines.append(String(format: "  %.1f s per movie minute", s.cpuSeconds / run.covered * 60))
        }
        lines.append(String(format: "  incl. decode+scale %.1f s", run.decodeCPUSeconds))
        lines.append(String(format: "thermal %@->%@, worst %@", PowerReport.thermalName(run.thermalAtStart),
                            PowerReport.thermalName(s.thermal), PowerReport.thermalName(s.worstThermal)))
        if run.lowPowerAtStart { lines.append("Low Power Mode on (not applied)") }

        // Frames
        let delivered = s.total(.framesDelivered).count, analysed = s.total(.framesAnalysed).count
        lines.append(PowerReport.row("frames", "n", "/s"))
        func perSecond(_ count: UInt64) -> String {
            run.covered > 0 ? String(format: "%.1f", Double(count) / run.covered) : "-"
        }
        lines.append(PowerReport.row("fed", "\(run.framesFed)", perSecond(UInt64(run.framesFed))))
        lines.append(PowerReport.row("delivered", "\(delivered)", perSecond(delivered)))
        lines.append(PowerReport.row("analysed", "\(analysed)", perSecond(analysed)))
        let dropped = s.total(.backlogDropped).count
        lines.append(PowerReport.row(run.powerSaving ? "superseded" : "backlog drop", "\(dropped)",
                                     perSecond(dropped)))
        lines.append(String(format: "queue max %d of %d", s.maxQueueDepth,
                            run.powerSaving ? 1 : BenchmarkRunner.maximumPending))
        lines += PowerReport.modeLines(s.modes)

        // Text reads
        lines.append(PowerReport.row("text read", "n", "/min", "avg ms", "max ms"))
        for metric in PowerMetric.textReads {
            let total = s.total(metric)
            let rate = run.covered >= 1 ? Double(total.count) * 60 / run.covered : nil
            lines.append(PowerReport.row(metric.label, "\(total.count)", PowerReport.rate(rate),
                                         PowerReport.milliseconds(total.averageMilliseconds),
                                         PowerReport.milliseconds(total.maxMilliseconds)))
        }

        // Steps
        lines.append(PowerReport.row("step", "runs", "ms/run", "ms/frm", "max"))
        for metric in PowerMetric.steps where metric == .frameWork || s.total(metric).count > 0 {
            let total = s.total(metric)
            lines.append(PowerReport.row(metric.label, "\(total.count)",
                                         PowerReport.milliseconds(total.averageMilliseconds),
                                         PowerReport.milliseconds(PowerReport.perFrame(total.nanoseconds, analysed)),
                                         PowerReport.milliseconds(total.maxMilliseconds)))
        }

        lines += hackLines(run, reference: reference)
        return lines
    }

    /// The run's hacks, each with its start delay in movie seconds.
    static func hackLines(_ run: BenchmarkRunResult, reference: [BenchmarkHack]?) -> [String] {
        var lines = [reference == nil ? "hacks: start after first sighting"
                                      : "hacks: start after Off run's sighting"]
        if run.hacks.isEmpty { lines.append("  none recognised") }
        let pairs = reference.map { BenchmarkComparison(off: $0, on: run.hacks) }
        for (number, hack) in run.hacks.enumerated() {
            let ref = pairs?.pairs.first { $0.on == hack }?.off
            lines += hackLines(number + 1, hack, delay: ref.map { BenchmarkComparison.delay(of: hack, reference: $0) }
                                                      ?? (reference == nil ? hack.ownDelay : nil))
        }
        return lines
    }

    static func hackLines(_ number: Int, _ hack: BenchmarkHack, delay: Double?) -> [String] {
        let via = hack.firstPhase == .command ? "cmd" : "pres"
        var lines = [String(format: "#%d %@ %@ start %@", number, via, clock(hack.shownAt, tenths: true),
                            delay.map { String(format: "%+.2f s", $0) } ?? "(no ref)")]
        if hack.hackID == nil { lines.append("   no presentation followed") }
        else if hack.glyphs.isEmpty { lines.append("   no Glyphs read") }
        else { lines += wrap(hack.glyphs.joined(separator: " "), first: "   ", rest: "   ") }
        return lines
    }

    /// Off then On at one pace: what changed with power saving. `hacks`
    /// compares the Glyphs and hack starts in full; the accuracy pass does,
    /// and the real pace when there is no accuracy pass to do it.
    static func comparisonLines(off: BenchmarkRunResult, on: BenchmarkRunResult,
                                hacks: Bool = true) -> [String] {
        let comparison = BenchmarkComparison(off: off.hacks, on: on.hacks)
        var lines = ["== \(off.pace.label): Off vs On =="]
        let a = frameCounts(off), b = frameCounts(on)
        lines.append(PowerReport.row("frames", "off", "on"))
        lines.append(PowerReport.row("fed", "\(a.fed)", "\(b.fed)"))
        lines.append(PowerReport.row("delivered", "\(a.delivered)", "\(b.delivered)"))
        lines.append(PowerReport.row("analysed", "\(a.analysed)", "\(b.analysed)"))
        if off.pace == .realTime {
            lines.append(PowerReport.row("dropped", "\(off.power.total(.backlogDropped).count)",
                                         "\(on.power.total(.backlogDropped).count)"))
        }
        if hacks {
            lines += hackComparisonLines(comparison)
        } else {
            let missed = comparison.missedWithPowerSaving.count
            lines.append("hacks off \(off.hacks.count) · on \(on.hacks.count)"
                         + (missed > 0 ? " · \(missed) MISSED" : ""))
        }
        guard off.pace == .realTime else { return lines }
        // CPU seconds, not % of a core: a run that falls behind runs on
        // after the movie, which spreads the same work over a longer time.
        let offCPU = off.power.cpuSeconds, onCPU = on.power.cpuSeconds
        let change = offCPU > 0 ? String(format: " (%+.0f%%)", (onCPU - offCPU) / offCPU * 100) : ""
        lines.append(String(format: "app CPU %.1f s -> %.1f s", offCPU, onCPU) + change)
        let late = off.wallSeconds - on.wallSeconds
        if late >= 1 { lines.append("Off ran \(clock(late)) longer: backlog") }
        for metric in [PowerMetric.headerFast, .headerAccurate] {
            let a = off.power.total(metric).count, b = on.power.total(metric).count
            if a + b > 0 { lines.append(String(format: "%@ reads %llu -> %llu", metric.label, a, b)) }
        }
        return lines
    }

    private static func hackComparisonLines(_ comparison: BenchmarkComparison) -> [String] {
        var lines: [String] = []
        let identical = comparison.sequencesIdentical
        lines.append("identical Glyph sequences: " + (identical ? "yes" : "NO"))
        lines.append(PowerReport.row("hack", "off s", "on s", "diff"))
        for (number, pair) in comparison.pairs.enumerated() {
            let label = "#\(number + 1) " + clock(pair.off?.shownAt ?? pair.on?.recognisedAt ?? 0)
            let offDelay = pair.off?.ownDelay
            let onDelay = pair.on.flatMap { on in pair.off.map { BenchmarkComparison.delay(of: on, reference: $0) } }
            func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
            let diff = onDelay.flatMap { on in offDelay.map { on - $0 } }
            lines.append(PowerReport.row(label, seconds(offDelay), pair.on == nil ? "-" : seconds(onDelay),
                                         diff.map { String(format: "%+.2f", $0) } ?? "-"))
            if pair.on == nil, pair.off != nil { lines.append("   MISSED WITH POWER SAVING") }
            if pair.off == nil { lines.append("   only with power saving") }
            if (pair.off?.glyphs ?? []) != (pair.on?.glyphs ?? []) {
                lines += wrap("off: " + glyphText(pair.off), first: "   ", rest: "        ")
                lines += wrap("on: " + glyphText(pair.on), first: "   ", rest: "        ")
            }
        }
        if comparison.pairs.isEmpty { lines.append("  no hacks in either run") }
        let missed = comparison.missedWithPowerSaving.count
        if missed > 0 { lines.append("\(missed) hack(s) MISSED WITH POWER SAVING") }
        return lines
    }

    private static func glyphText(_ hack: BenchmarkHack?) -> String {
        guard let hack else { return "(not recognised)" }
        return hack.glyphs.isEmpty ? "(none)" : hack.glyphs.joined(separator: " ")
    }

    /// m:ss, or m:ss.s with tenths.
    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(value) / 60
        return tenths ? String(format: "%d:%04.1f", minutes, value - Double(minutes * 60))
                      : String(format: "%d:%02d", minutes, Int(value) % 60)
    }

    /// Words wrapped to `width`: the first line after `first`, the others
    /// after `rest`. A word longer than a line is cut.
    static func wrap(_ text: String, first: String = "", rest: String = "  ") -> [String] {
        var lines: [String] = []
        var line = ""
        func prefix() -> String { lines.isEmpty ? first : rest }
        func flush() {
            if !line.isEmpty { lines.append(prefix() + line) }
            line = ""
        }
        for piece in text.split(separator: " ") {
            var word = String(piece)
            if !line.isEmpty, prefix().count + line.count + 1 + word.count <= width {
                line += " " + word
                continue
            }
            flush()
            while prefix().count + word.count > width {
                let room = max(1, width - prefix().count)
                lines.append(prefix() + String(word.prefix(room)))
                word = String(word.dropFirst(room))
            }
            line = word
        }
        flush()
        return lines
    }
}
