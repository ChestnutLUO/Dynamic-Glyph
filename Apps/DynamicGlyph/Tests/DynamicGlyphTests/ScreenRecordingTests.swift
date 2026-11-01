import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

/// The debug recorder's pure admission policy. No encoder involved.
@Suite("Debug recording admission")
struct DebugRecordingGateTests {
    private var limits: DebugRecordingLimits {
        var limits = DebugRecordingLimits.standard
        limits.maximumFrameRate = 20
        limits.maximumDuration = 1.0
        limits.maximumBytes = 1_000
        return limits
    }

    private func admit(_ gate: inout DebugRecordingGate, at time: Double,
                       status: CaptureFrameStatus = .complete, byteCount: Int = 0,
                       freeBytes: Int = .max) -> DebugRecordingGate.Decision {
        gate.admit(at: time, status: status, byteCount: byteCount, freeBytes: freeBytes)
    }

    @Test("Offered at 60 Hz, admitted at 20: exactly one frame in three")
    func frameRateCap() {
        var gate = DebugRecordingGate(limits: limits)
        let admitted = (0..<60).filter { admit(&gate, at: Double($0) / 60) == .accept }.count
        #expect(admitted == 20)
    }

    @Test("Jitter a hair under the interval does not halve the recorded rate")
    func frameRateEpsilon() {
        var gate = DebugRecordingGate(limits: limits)
        let admitted = (0..<20).filter { admit(&gate, at: Double($0) * 0.0499) == .accept }.count
        #expect(admitted == 20)
    }

    @Test("Only frames with new pixels are recorded")
    func statusFilter() {
        var gate = DebugRecordingGate(limits: limits)
        for ignored in [CaptureFrameStatus.idle, .blank, .suspended, .stopped, .unknown] {
            #expect(admit(&gate, at: 0, status: ignored) == .skipStatus)
        }
        #expect(gate.acceptedCount == 0)
    }

    @Test("A repeated timestamp is dropped; a restarted timeline stops the run")
    func ordering() {
        var gate = DebugRecordingGate(limits: limits)
        #expect(admit(&gate, at: 10) == .accept)
        #expect(admit(&gate, at: 10) == .skipOutOfOrder)
        #expect(admit(&gate, at: 9.9) == .skipOutOfOrder)
        #expect(admit(&gate, at: 5) == .stop(.timelineWentBackwards))
    }

    @Test("The duration cap is measured from the first admitted frame")
    func durationCap() {
        var gate = DebugRecordingGate(limits: limits)
        #expect(admit(&gate, at: 100) == .accept)
        #expect(admit(&gate, at: 100.9) == .accept)
        #expect(admit(&gate, at: 101.0) == .stop(.durationCap))
    }

    // Kept inside the duration cap on purpose: the duration check runs first,
    // so testing the byte cap at the duration boundary would measure the wrong
    // thing.
    @Test("The byte and free-space caps fire at their boundaries")
    func sizeCaps() {
        var bytes = DebugRecordingGate(limits: limits)
        #expect(admit(&bytes, at: 0, byteCount: 999) == .accept)
        #expect(admit(&bytes, at: 0.5, byteCount: 1_000) == .stop(.byteCap))

        var disk = DebugRecordingGate(limits: limits)
        #expect(admit(&disk, at: 0, freeBytes: limits.freeSpaceToContinue - 1) == .stop(.diskSpace))
    }
}

/// The real AVAssetWriter path, driven with synthetic 4:2:0 frames.
///
/// Serialized because these measure timing — a producer cadence, a finish
/// deadline, a wall-time cap — and sharing the encoder hardware with a
/// neighbouring test is what would make them flaky.
@Suite("Debug screen recorder", .serialized)
struct DebugScreenRecorderTests {
    private typealias Frames = SyntheticFrames

    private func receipt(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("recording.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func receiptState(_ directory: URL) -> String? {
        (try? receipt(in: directory))?["state"] as? String
    }

    /// `waitForFinish` gives up one second past the deadline, and on a loaded
    /// CI runner the watchdog can land after that. The terminal receipt is the
    /// evidence it fired at all, so wait for that rather than for the wait.
    private func terminalReceipt(in directory: URL, within seconds: Double = 15) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let row = try? receipt(in: directory), row["state"] as? String != "recording" { return row }
            usleep(10_000)
        }
        throw SyntheticFrames.Failure("the receipt was still \"recording\" after \(seconds) seconds")
    }

    @Test("One second of 20 Hz video is playable and matches its receipt")
    func recordsAPlayableMovie() async throws {
        try Frames.warmEncoderHardware()
        let directory = try TemporaryDirectory("recording")
        var limits = DebugRecordingLimits.standard
        limits.maximumFrameRate = 20
        let recorder = try DebugScreenRecorder(directory: directory.url, limits: limits) { _ in }

        // A receipt exists before a single frame arrives, so an interrupted
        // recording is identifiable rather than merely absent.
        let initial = try receipt(in: directory.url)
        #expect(initial["state"] as? String == "recording")
        #expect(initial["firstPresentationTime"] == nil, "anchor written before any frame")

        // A deliberately odd origin, so a recorder that assumed a zero-based
        // timeline would be caught.
        let origin = 41_273.418
        let count = 20
        try Frames.offerAtCadence(to: recorder, count: count, origin: origin)
        // Idle frames carry no new pixels and must not extend the movie.
        let description = try Frames.formatDescription()
        for index in 0..<5 {
            let time = origin + 2.0 + Double(index) / 20
            recorder.offer(try Frames.sample(index: index, at: time, description: description),
                           at: time, status: .idle)
        }

        recorder.requestFinish(.sessionStopped)
        try #require(recorder.waitForFinish(), "finalization did not complete inside its deadline")

        let final = try receipt(in: directory.url)
        #expect(final["state"] as? String == "finished")
        #expect(final["stopReason"] as? String == "sessionStopped")
        #expect(final["finishTimedOut"] as? Bool == false)
        // A real-time encoder may refuse frames when the host cannot keep up,
        // and Xcode Cloud's simulators sometimes cannot; on a phone that rate is
        // a field check (`framesDroppedNotReady` in FIELD_TESTING.md). What
        // holds on any host is that every offered frame is accounted for, and
        // only pressure — never finalization — may cost one.
        let appended = try #require(final["framesAppended"] as? Int)
        let pressure = (final["framesDroppedPoolFull"] as? Int ?? -1)
            + (final["framesDroppedNotReady"] as? Int ?? -1)
        #expect(appended >= 2, "only \(appended) of \(count) frames were written")
        #expect(appended + pressure == count, "\(count - appended - pressure) frames unaccounted for")
        #expect(final["framesDroppedFinalization"] as? Int == 0)
        #expect(final["framesDroppedStatus"] as? Int == 5, "idle frames should be counted as skipped")
        #expect(final["width"] as? Int == Frames.width && final["height"] as? Int == Frames.height)

        // The anchor the whole log/video correlation rests on.
        let first = try #require(final["firstPresentationTime"] as? Double)
        let last = try #require(final["lastPresentationTime"] as? Double)
        #expect(abs(first - origin) < 1e-6, "anchor is \(first), expected \(origin)")
        let span = last - first
        let lastIndex = (span * 20).rounded()
        #expect(abs(span * 20 - lastIndex) < 1e-6, "last frame at \(span)s is not on the 20 Hz grid")
        #expect(lastIndex >= Double(appended - 1) && lastIndex <= Double(count - 1),
                "\(appended) frames cannot end at frame \(Int(lastIndex))")
        if pressure == 0 { #expect(lastIndex == Double(count - 1)) }

        let movie = directory.url.appendingPathComponent("screen-recording.mp4")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int)
        #expect(size > 0, "the movie is empty")

        // Frame by frame rather than by overall duration: a movie's duration
        // includes a last-frame length inferred from the gap before it, which
        // stops meaning anything once frames have been dropped.
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var times: [Double] = []
        while let sample = try await provider.next() {
            if sample.withUnsafeSampleBuffer({ CMSampleBufferGetNumSamples($0) }) > 0 {
                times.append(sample.presentationTimeStamp.seconds)
            }
        }
        #expect(times.count == appended, "movie holds \(times.count) frames, receipt says \(appended)")
        // The movie's own timeline starts at zero; the 1/600 s timescale of the
        // source timestamps bounds the rounding.
        if let movieFirst = times.first, let movieLast = times.last {
            #expect(abs((movieLast - movieFirst) - span) < 0.002,
                    "movie spans \(movieLast - movieFirst)s, receipt covers \(span)s")
        }

        // Finishing twice must be harmless.
        recorder.requestFinish(.userStopped)
        #expect(recorder.waitForFinish(), "a second wait consumed the completion signal")
        #expect(!recorder.snapshotStatus().isRecording)
        #expect(recorder.snapshotStatus().outcome == .finished)
        #expect(try receipt(in: directory.url)["stopReason"] as? String == "sessionStopped",
                "a second finish rewrote the receipt")
    }

    @Test("Stop keeps frames already queued behind a blocked encoder")
    func queuedStop() throws {
        let (recorder, directory) = try Frames.makeRecorder("queued-stop")
        try Frames.warm(recorder)
        let release = recorder.blockEncoderForTesting()
        try Frames.offer(recorder, 2)
        try Frames.offer(recorder, 3)
        recorder.requestFinish(.userStopped)
        try Frames.offer(recorder, 4) // admission is closed
        release.signal()
        #expect(recorder.waitForFinish())
        #expect(recorder.snapshotStatus().framesAppended == 4, "Stop discarded accepted frames")
        #expect(recorder.snapshotStatus().totalDropped == 0)
        #expect(receiptState(directory.url) == "finished")
    }

    @Test("Stop before writer setup still drains the first accepted frame")
    func stopBeforeSetup() throws {
        // Bound, not discarded: releasing it deletes the directory the writer
        // is about to create its file in.
        let (recorder, directory) = try Frames.makeRecorder("stop-before-setup")
        let release = recorder.blockEncoderForTesting()
        try Frames.offer(recorder, 0)
        recorder.requestFinish(.sessionStopped)
        release.signal()
        #expect(recorder.waitForFinish())
        #expect(recorder.snapshotStatus().framesAppended == 1)
        #expect(receiptState(directory.url) == "finished")
    }

    @Test("A cancelled writer is reported as a failure, not a success")
    func cancelledWriter() throws {
        let (recorder, directory) = try Frames.makeRecorder("cancelled")
        try Frames.warm(recorder)
        recorder.cancelWriterForTesting()
        recorder.requestFinish(.userStopped)
        #expect(!recorder.waitForFinish(), "a cancelled writer reported success")
        let failed = try receipt(in: directory.url)
        #expect(failed["state"] as? String == "failed")
        #expect(failed["error"] as? String != nil)
        #expect(recorder.snapshotStatus().outcome == .failed)
        #expect(!recorder.snapshotStatus().isRecording)
    }

    @Test("Writer creation failure is a failure, not notStarted")
    func creationFailure() throws {
        let (recorder, directory) = try Frames.makeRecorder("creation-failure")
        try Data([0]).write(to: recorder.movieURL) // AVAssetWriter refuses existing output
        try Frames.offer(recorder, 0)
        recorder.requestFinish(.sessionStopped)
        #expect(!recorder.waitForFinish())
        #expect(receiptState(directory.url) == "failed")
        #expect(recorder.snapshotStatus().framesDroppedFinalization == 1)
    }

    @Test("The watchdog fires behind a wedged encoder, and late work cannot rewrite the receipt")
    func finishDeadline() throws {
        let (recorder, directory) = try Frames.makeRecorder("timeout", deadline: 0.1)
        try Frames.warm(recorder)
        let release = recorder.blockEncoderForTesting()
        try Frames.offer(recorder, 2)
        recorder.requestFinish(.userStopped)
        #expect(!recorder.waitForFinish(), "watchdog completion is not successful finalization")
        #expect(!recorder.waitForFinish(), "repeated waits must preserve timeout")
        let timedOut = try terminalReceipt(in: directory.url)
        #expect(timedOut["state"] as? String == "timedOut")
        #expect(timedOut["finishTimedOut"] as? Bool == true)
        #expect(timedOut["stopReason"] as? String == "userStopped")
        #expect(timedOut["framesDroppedFinalization"] as? Int == 1)

        let receiptURL = directory.url.appendingPathComponent("recording.json")
        let frozen = try Data(contentsOf: receiptURL)
        release.signal()
        recorder.drainEncoderForTesting()
        #expect(try Data(contentsOf: receiptURL) == frozen, "late encoder work overwrote the terminal receipt")
    }

    @Test("The wall clock caps a run with no frames at all")
    func emptyRunCap() throws {
        let (recorder, directory) = try Frames.makeRecorder("empty", duration: 0.1)
        #expect(recorder.waitForFinish())
        #expect(recorder.snapshotStatus().stopReason == .durationCap)
        #expect(receiptState(directory.url) == "notStarted")
    }

    @Test("The wall clock caps a run that turns idle")
    func idleRunCap() throws {
        // The cap runs from creation, so a first encoder session's setup must
        // not fall inside it -- whichever order the suite happens to run in.
        try Frames.warmEncoderHardware()
        let (recorder, directory) = try Frames.makeRecorder("idle", duration: 1)
        // Back to back rather than drained: admission is only a copy, so both
        // are accepted well inside the cap on any host, and the finish the cap
        // triggers still drains what was accepted. Draining between them put
        // the encoder's own latency inside a 0.4 s budget.
        try Frames.offer(recorder, 0)
        try Frames.offer(recorder, 1)
        try Frames.offer(recorder, 2, status: .idle)
        #expect(recorder.waitForFinish())
        #expect(recorder.snapshotStatus().stopReason == .durationCap)
        #expect(recorder.snapshotStatus().framesAppended == 2)
        #expect(abs(recorder.snapshotStatus().coveredDuration - 0.05) < 0.001)
        #expect(receiptState(directory.url) == "finished")
    }
}

/// Synthetic frames in the format iOS actually delivers for screen capture.
enum SyntheticFrames {
    // The phone delivers 603×1311, and the Mac and device encoders accept it.
    // The simulator's H.264 encoder refuses odd dimensions outright
    // (startWriting fails with -12143), so there the frames are one pixel
    // larger; everything else under test is size-independent.
    #if targetEnvironment(simulator)
    static let width = 604, height = 1312
    #else
    static let width = 603, height = 1311
    #endif

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func makeRecorder(_ name: String, duration: Double = 600,
                             deadline: Double = 5) throws -> (DebugScreenRecorder, TemporaryDirectory) {
        let directory = try TemporaryDirectory("recording-\(name)")
        var limits = DebugRecordingLimits.standard
        limits.maximumDuration = duration
        limits.finishDeadline = deadline
        return (try DebugScreenRecorder(directory: directory.url, limits: limits) { _ in }, directory)
    }

    /// The first video encoder session in a process — on a freshly booted
    /// simulator especially — takes long enough to set up that a 20 Hz
    /// real-time producer overruns it, and the measured run then drops frames
    /// for reasons that belong to the host rather than the recorder. One
    /// throwaway recording pays that cost up front, so the measured run can
    /// keep its strict "every frame, nothing dropped" assertions without
    /// draining between offers.
    ///
    /// Measured on a freshly booted iOS 27 simulator: the first session took
    /// about forty seconds to append its first frame, and every later session
    /// in the same process a few milliseconds. The patience here is for that
    /// one-off setup only; the measured runs keep their own tight bounds.
    static func warmEncoderHardware() throws {
        let patience = 120.0
        let (recorder, directory) = try makeRecorder("warm-up", deadline: patience)
        try offer(recorder, 0)
        try drain(recorder, until: 1, within: patience)
        recorder.requestFinish(.sessionStopped)
        guard recorder.waitForFinish() else {
            throw Failure("the warm-up recording in \(directory.url.lastPathComponent) did not finish")
        }
    }

    static func offer(_ recorder: DebugScreenRecorder, _ index: Int,
                      status: CaptureFrameStatus = .complete) throws {
        let time = 100 + Double(index) / 20
        recorder.offer(try sample(index: index, at: time, description: formatDescription()),
                       at: time, status: status)
    }

    static func warm(_ recorder: DebugScreenRecorder) throws {
        try offer(recorder, 0)
        try drain(recorder, until: 1)
        try offer(recorder, 1)
        try drain(recorder, until: 2)
    }

    /// Producer cadence is independent of encoder progress. Never drain between
    /// offers: doing that concealed queued-stop and backlog bugs.
    static func offerAtCadence(to recorder: DebugScreenRecorder, count: Int, origin: Double) throws {
        let description = try formatDescription()
        let frames = try (0..<count).map {
            try sample(index: $0, at: origin + Double($0) / 20, description: description)
        }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            let delay = start + Double(index) / 20 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            recorder.offer(frames[index], at: origin + Double(index) / 20, status: .complete)
        }
    }

    /// Blocks until the encoder has caught up, or fails loudly. A rising
    /// `droppedUnderPressure` here would mean the pool bound is too tight for
    /// the offered cadence.
    static func drain(_ recorder: DebugScreenRecorder, until appended: Int,
                      within seconds: Double = 10) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let status = recorder.snapshotStatus()
            if status.framesAppended >= appended { return }
            if status.droppedUnderPressure > 0 {
                throw Failure("dropped \(status.droppedUnderPressure) frames under pressure at frame \(appended)")
            }
            usleep(500)
        }
        throw Failure("the encoder did not reach frame \(appended) within \(seconds) seconds")
    }

    static func formatDescription() throws -> CMVideoFormatDescription {
        let buffer = try pixelBuffer(index: 0)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescriptionOut: &description) == noErr, let description else {
            throw Failure("could not describe the synthetic format")
        }
        return description
    }

    static func pixelBuffer(index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw Failure("could not allocate a synthetic pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Content that changes per frame, so an encoder that silently wrote the
        // same picture repeatedly would not produce a plausible file size.
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
                memset(luma.advanced(by: row * stride), Int32((row &+ index &* 7) % 255), stride)
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            memset(chroma, 128, stride * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }

    static func sample(index: Int, at seconds: Double,
                       description: CMVideoFormatDescription) throws -> CMSampleBuffer {
        let buffer = try pixelBuffer(index: index)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else {
            throw Failure("could not wrap a synthetic frame")
        }
        return sample
    }
}
