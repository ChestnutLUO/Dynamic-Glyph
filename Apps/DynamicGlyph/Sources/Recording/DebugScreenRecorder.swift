import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes the frames the recognizer analyzed to an mp4, for bug reports.
///
/// Three properties are load-bearing, and each one is a constraint rather than
/// a preference:
///
/// **It records the analyzed frames, not a stream of its own.** It is fed from
/// the recognition callback *after* the sampling throttle, so each recorded frame can be correlated with recognition by source time.
/// Under pressure some analyzed frames are dropped and counted in the receipt. A
/// recorder on an independent clock would capture frames nothing else ever
/// looked at, and the logs would describe a different set of pixels.
///
/// **It copies each frame before handing it on.** `AVAssetWriterInput` retains
/// a sample buffer past `append` returning — the SDK says so in as many words —
/// so passing ScreenCaptureKit's buffers straight through would leave its
/// surface pool held for an unbounded time. Starving the capture stream would
/// degrade *recognition*, which is the one thing a debug feature must never do.
/// The copy costs about a megabyte at 20 fps and buys a bound we own.
///
/// **It never blocks the recognition queue.** Admission is a lock, a pool
/// allocation and a memcpy. Everything else happens on the encoder queue, and
/// finalization is bounded by a deadline rather than by three waits in a row
/// that each hope the encoder is healthy.
///
/// Deliberately free of ScreenCaptureKit and UIKit, so `DynamicGlyphTests` can
/// compile it directly and drive it with synthetic frames on a simulator.
///
/// iOS 27 deprecates the writer input and pixel-buffer adaptor used here in
/// favour of `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`
/// and its async append. The deprecated calls are deliberate and their warnings
/// are left visible, for the same reason as in `GlyphPiPRenderLoop`: the
/// replacement changes the back-pressure model from "ask whether it is ready"
/// to "await the append", and a debug feature is the wrong place to take that
/// risk. Migrating is follow-up work with its own device test.
final class DebugScreenRecorder: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case insufficientFreeSpace(available: Int, required: Int)

        var description: String {
            switch self {
            case .insufficientFreeSpace(let available, let required):
                return "needs \(required / 1_048_576) MB free, \(available / 1_048_576) MB available"
            }
        }
    }

    private enum State { case accepting, finishing, terminal }

    let movieURL: URL
    private let receiptURL: URL
    private let limits: DebugRecordingLimits
    /// Adds an AAC track fed by `offerAudio`. Off for bug reports, which stay
    /// video-only; the player can ask for sound in a recording they keep.
    let recordsAudio: Bool
    private let onStatus: @Sendable (DebugRecordingStatus) -> Void

    private let queue = DispatchQueue(label: "spikeB.recording", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Separate from the encoder queue on purpose: the watchdog has to be able
    /// to fire while that queue is wedged, which is the case it exists for.
    /// Separate from the resource poll too, whose free-space query can take
    /// seconds, and above utility so a busy CPU cannot starve a deadline that
    /// does almost no work: on a loaded Xcode Cloud runner a 0.1 s deadline
    /// sharing the poll's queue had not fired after two seconds.
    private let watchdogQueue = DispatchQueue(label: "spikeB.recording.watchdog", qos: .userInitiated)
    private let pollQueue = DispatchQueue(label: "spikeB.recording.poll", qos: .utility)
    private let finished = DispatchGroup()
    // Serialize admission through enqueue with Stop; accepted copies must be
    // ahead of the finish block. Recursive because admission can hit a cap.
    private let admissionLock = NSRecursiveLock()
    private let receiptLock = NSLock()
    private var pool: CVPixelBufferPool? // admissionLock only
    private var pendingFrames = 0 // lock
    private var pendingAudio = 0 // lock
    private var finishOutcome: DebugRecordingOutcome?
    private var resourceTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var state: State = .accepting
    private var gate: DebugRecordingGate
    private var status = DebugRecordingStatus()
    private var stopReason: DebugRecordingStopReason?
    /// Distinct from `stopReason`: a run can stop at its duration cap *and*
    /// have finalization run out of time, and a reader needs to know both.
    private var finishTimedOut = false
    private var writerError: String?

    // Confined to `queue` once created, except `dimensions`, which admission
    // reads under the lock to detect a size change.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    /// The movie's first video timestamp. Sound from before it is dropped.
    private var sessionStart: CMTime?

    private var dimensions: (width: Int, height: Int)?
    private var firstPresentationTime: Double?
    private var lastPresentationTime: Double?
    private var observedByteCount = 0
    private var observedFreeBytes = 0
    private var lastPollUptime = -Double.infinity
    private var lastStatusUptime = -Double.infinity
    private let startedWallClock = Date()

    /// Throws before any file is created if the volume is already too full.
    init(directory: URL, limits: DebugRecordingLimits = .standard, recordsAudio: Bool = false,
         onStatus: @escaping @Sendable (DebugRecordingStatus) -> Void) throws {
        self.movieURL = directory.appendingPathComponent("screen-recording.mp4")
        self.receiptURL = directory.appendingPathComponent("recording.json")
        self.limits = limits
        self.recordsAudio = recordsAudio
        self.gate = DebugRecordingGate(limits: limits)
        self.onStatus = onStatus

        let free = Self.freeBytes(at: directory)
        guard free >= limits.freeSpaceToStart else {
            throw Failure.insufficientFreeSpace(available: free, required: limits.freeSpaceToStart)
        }
        observedFreeBytes = free
        status.isRecording = true
        finished.enter()
        // A receipt exists from the first moment, so a recording interrupted by
        // a crash is identifiable as interrupted rather than as absent.
        writeReceipt(state: "recording")
        // Wall time is bounded even if no complete frame ever arrives.
        watchdogQueue.asyncAfter(deadline: .now() + limits.maximumDuration) { [weak self] in
            self?.requestFinish(.durationCap)
        }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.poll() }
        resourceTimer = timer
        timer.resume()
    }

    deinit { resourceTimer?.cancel() }

    // MARK: - Admission

    /// Offers one captured frame without waiting for the encoder. Only the
    /// bounded owned-buffer allocation and copy run on the caller's queue.
    func offer(_ sampleBuffer: CMSampleBuffer, at time: Double, status frameStatus: CaptureFrameStatus) {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        lock.lock()
        guard state == .accepting else { lock.unlock(); return }
        let decision = gate.admit(at: time, status: frameStatus,
                                  byteCount: observedByteCount, freeBytes: observedFreeBytes)
        switch decision {
        case .skipRate: status.framesDroppedRate += 1; lock.unlock(); return
        case .skipStatus: status.framesDroppedStatus += 1; lock.unlock(); return
        case .skipOutOfOrder: status.framesDroppedOutOfOrder += 1; lock.unlock(); return
        case .stop(let reason): lock.unlock(); requestFinish(reason); return
        case .accept: break
        }
        lock.unlock()

        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock(); status.framesDroppedStatus += 1; lock.unlock()
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)

        lock.lock()
        if let existing = dimensions, existing != (width, height) {
            lock.unlock()
            // A rotation or layout change mid-recording: the encoder is
            // configured for one size and cannot be reconfigured in place.
            requestFinish(.dimensionsChanged)
            return
        }
        dimensions = (width, height)
        lock.unlock()

        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary,
                                          &pool) == kCVReturnSuccess else {
                fail("could not create the recording buffer pool")
                return
            }
        }
        guard let pool else { return }
        // A bounded pool that refuses rather than grows: the allocation
        // threshold is what actually caps how much the recorder holds.
        var destination: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String:
                            limits.maximumPooledBuffers] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pool, auxiliary, &destination) == kCVReturnSuccess,
              let destination else {
            lock.lock(); status.framesDroppedPoolFull += 1; lock.unlock()
            return
        }
        Self.copy(source, into: destination)
        lock.lock()
        pendingFrames += 1
        lock.unlock()

        queue.async { [weak self] in
            self?.append(destination, at: presentationTime, sourceSeconds: time)
        }
    }

    /// Offers one captured sound buffer. Like a frame it never waits for the
    /// encoder: it is dropped and counted if the movie has not started, the
    /// encoder cannot take it now, or too many are already waiting.
    func offerAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recordsAudio else { return }
        // Serialized with Stop, as frames are: once finalization is queued, no
        // sound may be queued behind it and appended to a finished input.
        admissionLock.lock()
        defer { admissionLock.unlock() }
        lock.lock()
        guard state == .accepting else { lock.unlock(); return }
        guard pendingAudio < limits.maximumPendingAudioBuffers else {
            status.audioSamplesDropped += 1
            lock.unlock()
            return
        }
        pendingAudio += 1
        lock.unlock()
        queue.async { [weak self] in self?.appendAudio(sampleBuffer) }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        var appended = false
        defer {
            lock.lock()
            pendingAudio -= 1
            if state != .terminal {
                if appended { status.audioSamplesAppended += 1 } else { status.audioSamplesDropped += 1 }
            }
            lock.unlock()
        }
        lock.lock()
        let active = state != .terminal && writerError == nil
        lock.unlock()
        guard active, let writer, writer.status == .writing, let audioInput, let sessionStart,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), sessionStart) >= 0,
              audioInput.isReadyForMoreMediaData else { return }
        appended = audioInput.append(sampleBuffer)
    }

    // MARK: - Writing

    private func prepareWriter(width: Int, height: Int, source: CVPixelBuffer,
                               startingAt presentationTime: CMTime, sourceSeconds: Double) -> Bool {
        do {
            let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
            // Fragments are what make a recording survive the app being killed
            // mid-session -- which may be the very bug being reported. Without
            // them an interrupted file has no moov atom and will not open at
            // all. The initial interval is short so that even an early crash
            // leaves something playable; later fragments can be less frequent.
            writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: limits.averageBitRate,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    // No B-frames: presentation order equals decode order, so
                    // seeking to a timestamp from the logs lands where the
                    // arithmetic says it should.
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                fail("asset writer refused the video input")
                return false
            }
            writer.add(input)

            // Explicit, and matching what the capture stream is asked for, so
            // the track does not depend on sound arriving before the first frame.
            var audioInput: AVAssetWriterInput?
            if recordsAudio {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: DebugRecordingLimits.audioSampleRate,
                    AVNumberOfChannelsKey: DebugRecordingLimits.audioChannelCount,
                    AVEncoderBitRateKey: 128_000
                ])
                audio.expectsMediaDataInRealTime = true
                guard writer.canAdd(audio) else {
                    fail("asset writer refused the audio input")
                    return false
                }
                writer.add(audio)
                audioInput = audio
            }

            // The pool's format is discovered from the delivered frame. On iOS
            // the capture pixel format cannot be requested, so it is the only
            // honest source for this.
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
                ])

            guard writer.startWriting() else {
                fail("startWriting failed: \(writer.error.map(String.init(describing:)) ?? "unknown")")
                return false
            }
            writer.startSession(atSourceTime: presentationTime)

            lock.lock()
            guard state != .terminal else {
                lock.unlock()
                writer.cancelWriting()
                return false
            }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.audioInput = audioInput
            self.sessionStart = presentationTime
            self.dimensions = (width, height)
            self.firstPresentationTime = sourceSeconds
            lock.unlock()
            // The anchor the whole log/video correlation rests on, persisted as
            // soon as it exists rather than at the end.
            writeReceipt(state: "recording")
            return true
        } catch {
            fail("could not create the asset writer: \(error.localizedDescription)")
            return false
        }
    }

    private func append(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime, sourceSeconds: Double) {
        lock.lock()
        guard state != .terminal else { lock.unlock(); return }
        let canWrite = writerError == nil
        lock.unlock()
        var accounted = false
        defer {
            lock.lock()
            if state != .terminal {
                pendingFrames -= 1
                if !accounted { status.framesDroppedFinalization += 1 }
            }
            lock.unlock()
        }
        guard canWrite else { return }
        // Stop closes admission, but these already accepted frames still drain.
        if writer == nil {
            guard prepareWriter(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer), source: pixelBuffer,
                                startingAt: presentationTime, sourceSeconds: sourceSeconds) else { return }
        }
        lock.lock()
        let active = state != .terminal
        lock.unlock()
        guard active, let adaptor, let input else { return }
        guard writer?.status == .writing else {
            fail("writer stopped before append: \(writer?.error.map(String.init(describing:)) ?? "not writing")")
            return
        }
        guard input.isReadyForMoreMediaData else {
            lock.lock()
            if state != .terminal { status.framesDroppedNotReady += 1 }
            lock.unlock()
            accounted = true
            return
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            fail("append failed: \(writer?.error.map(String.init(describing:)) ?? "append returned false")")
            return
        }
        lock.lock()
        if state != .terminal {
            status.framesAppended += 1
            lastPresentationTime = sourceSeconds
            status.coveredDuration = sourceSeconds - (firstPresentationTime ?? sourceSeconds)
        }
        lock.unlock()
        accounted = true
    }

    /// File size, free space and the status callback, on a slower schedule than
    /// the frame rate so that a per-frame syscall is not added to the encoder.
    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard state == .accepting else { lock.unlock(); return }
        let shouldPoll = now - lastPollUptime >= 1
        if shouldPoll { lastPollUptime = now }
        let shouldReport = now - lastStatusUptime >= 1
        if shouldReport { lastStatusUptime = now }
        lock.unlock()
        guard shouldPoll || shouldReport else { return }

        if shouldPoll {
            let size = (try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? Int) ?? nil
            let free = Self.freeBytes(at: movieURL.deletingLastPathComponent())
            lock.lock()
            guard state == .accepting else { lock.unlock(); return }
            observedByteCount = size ?? observedByteCount
            observedFreeBytes = free
            status.byteCount = observedByteCount
            lock.unlock()
            writeReceipt(state: "recording")
            if let size, size >= limits.maximumBytes { requestFinish(.byteCap) }
            if free > 0, free < limits.freeSpaceToContinue { requestFinish(.diskSpace) }
        }
        if shouldReport { onStatus(snapshotStatus()) }
    }

    // MARK: - Finishing

    /// Closes admission, then drains accepted frames. Safe from any queue and
    /// idempotent. Waits only for a copy already in flight, never for encoding.
    func requestFinish(_ reason: DebugRecordingStopReason) {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        lock.lock()
        guard state == .accepting else { lock.unlock(); return }
        state = .finishing
        stopReason = reason
        // A resource poll can report while finalization is still pending.
        // Do not describe that recording as active or send a near-limit alert.
        status.isRecording = false
        status.stopReason = reason
        lock.unlock()

        watchdogQueue.asyncAfter(deadline: .now() + limits.finishDeadline) { [weak self] in
            self?.complete(.timedOut, error: "finalization exceeded its deadline")
        }
        // Always queue finalization: the first accepted frame may still be
        // waiting to create the writer. Admission and enqueue are serialized.
        queue.async { [self] in
            lock.lock()
            let terminal = state == .terminal
            let error = writerError
            lock.unlock()
            if terminal {
                if writer?.status == .writing { writer?.cancelWriting() }
                return
            }
            guard let writer else {
                complete(error == nil ? .notStarted : .failed, error: error)
                return
            }
            guard writer.status == .writing else {
                complete(.failed, error: writer.error.map(String.init(describing:))
                         ?? "writer ended with status \(writer.status.rawValue)")
                return
            }
            input?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                if writer.status == .completed, error == nil {
                    complete(snapshotStatus().framesAppended > 0 ? .finished : .notStarted)
                } else {
                    complete(.failed, error: writer.error.map(String.init(describing:))
                             ?? error ?? "writer did not complete (status \(writer.status.rawValue))")
                }
            }
        }
    }

    /// Reusable bounded wait. A timeout or writer failure is never success.
    @discardableResult
    func waitForFinish() -> Bool {
        guard finished.wait(timeout: .now() + limits.finishDeadline + 1) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return finishOutcome == .finished || finishOutcome == .notStarted
    }

    private func complete(_ outcome: DebugRecordingOutcome, error: String? = nil) {
        let size = (try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? Int) ?? nil
        lock.lock()
        guard state != .terminal else { lock.unlock(); return }
        state = .terminal
        finishOutcome = outcome
        finishTimedOut = outcome == .timedOut
        if let error { writerError = error }
        status.framesDroppedFinalization += pendingFrames
        pendingFrames = 0
        if stopReason == nil { stopReason = .sessionStopped }
        if outcome == .notStarted, stopReason == .sessionStopped { stopReason = .notStarted }
        observedByteCount = size ?? observedByteCount
        status.byteCount = observedByteCount
        status.isRecording = false
        status.outcome = outcome
        status.stopReason = stopReason
        status.message = "recording \(outcome.rawValue): \(stopReason?.rawValue ?? "unknown")"
            + (writerError.map { " (\($0))" } ?? "")
        let reported = status
        lock.unlock()
        resourceTimer?.cancel()
        if outcome == .timedOut {
            // Cancellation stays on the encoder queue. If it was wedged this
            // runs when it recovers; a pending finish callback remains harmless.
            queue.async { [self] in
                if writer?.status == .writing { writer?.cancelWriting() }
            }
        }
        writeReceipt(state: outcome.rawValue)
        watchdogQueue.async { [onStatus] in onStatus(reported) }
        finished.leave()
    }

    private func fail(_ message: String) {
        lock.lock()
        guard state != .terminal else { lock.unlock(); return }
        writerError = message
        lock.unlock()
        requestFinish(.writerFailed)
    }

    func snapshotStatus() -> DebugRecordingStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    // MARK: - Receipt

    /// Written at start, again when the timestamp anchor first exists, on every
    /// poll, and at completion. Replaced atomically so a crash mid-write cannot
    /// leave an unreadable receipt.
    private func writeReceipt(state fileState: String) {
        receiptLock.lock()
        defer { receiptLock.unlock() }
        lock.lock()
        // A checkpoint that raced finalization must never overwrite its result.
        if state == .terminal, fileState == "recording" { lock.unlock(); return }
        var row: [String: Any] = [
            "schemaVersion": 1,
            "file": movieURL.lastPathComponent,
            "state": fileState,
            "framesAppended": status.framesAppended,
            "framesDroppedRate": status.framesDroppedRate,
            "framesDroppedStatus": status.framesDroppedStatus,
            "framesDroppedOutOfOrder": status.framesDroppedOutOfOrder,
            "framesDroppedPoolFull": status.framesDroppedPoolFull,
            "framesDroppedNotReady": status.framesDroppedNotReady,
            "framesDroppedFinalization": status.framesDroppedFinalization,
            "byteCount": observedByteCount,
            "frameRateCap": limits.maximumFrameRate,
            "averageBitRate": limits.averageBitRate,
            "recordsAudio": recordsAudio,
            "audioSamplesAppended": status.audioSamplesAppended,
            "audioSamplesDropped": status.audioSamplesDropped,
            "limitDurationSeconds": limits.maximumDuration,
            "limitByteCount": limits.maximumBytes,
            "startedWallClock": ISO8601DateFormatter().string(from: startedWallClock)
        ]
        if let firstPresentationTime { row["firstPresentationTime"] = firstPresentationTime }
        if let lastPresentationTime { row["lastPresentationTime"] = lastPresentationTime }
        if let first = firstPresentationTime, let last = lastPresentationTime {
            row["durationSeconds"] = last - first
        }
        if let dimensions {
            row["width"] = dimensions.width
            row["height"] = dimensions.height
            row["codec"] = "h264"
            row["container"] = "mp4"
        }
        if let stopReason { row["stopReason"] = stopReason.rawValue }
        row["finishTimedOut"] = finishTimedOut
        if let writerError { row["error"] = writerError }
        if fileState != "recording" {
            row["finishedWallClock"] = ISO8601DateFormatter().string(from: Date())
        }
        lock.unlock()

        guard let data = try? JSONSerialization.data(withJSONObject: row,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: receiptURL, options: .atomic)
    }

    // MARK: - Pixels

    /// Row-by-row so that a differing bytes-per-row between the capture buffer
    /// and the pool's does not shear the image.
    static func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            let planes = min(CVPixelBufferGetPlaneCount(source), CVPixelBufferGetPlaneCount(destination))
            for plane in 0..<planes {
                copyPlane(from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                          sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                          to: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                          destinationStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                          rows: min(CVPixelBufferGetHeightOfPlane(source, plane),
                                    CVPixelBufferGetHeightOfPlane(destination, plane)))
            }
        } else {
            copyPlane(from: CVPixelBufferGetBaseAddress(source),
                      sourceStride: CVPixelBufferGetBytesPerRow(source),
                      to: CVPixelBufferGetBaseAddress(destination),
                      destinationStride: CVPixelBufferGetBytesPerRow(destination),
                      rows: min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination)))
        }
    }

    private static func copyPlane(from source: UnsafeMutableRawPointer?, sourceStride: Int,
                                  to destination: UnsafeMutableRawPointer?, destinationStride: Int,
                                  rows: Int) {
        guard let source, let destination, rows > 0 else { return }
        let width = min(sourceStride, destinationStride)
        if sourceStride == destinationStride {
            destination.copyMemory(from: source, byteCount: width * rows)
            return
        }
        for row in 0..<rows {
            destination.advanced(by: row * destinationStride)
                .copyMemory(from: source.advanced(by: row * sourceStride), byteCount: width)
        }
    }

    static func freeBytes(at directory: URL) -> Int {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

#if DEBUG_RECORDING_TESTING
// Fault injection is compiled only into DynamicGlyphTests, never into the app.
extension DebugScreenRecorder {
    func blockEncoderForTesting() -> DispatchSemaphore {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); release.wait() }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        return release
    }

    func cancelWriterForTesting() { queue.sync { writer?.cancelWriting() } }
    func drainEncoderForTesting() { queue.sync {} }
}
#endif
