import Foundation

/// Why a recording ended. Recorded in the receipt so a short or missing video
/// is explained rather than merely observed.
enum DebugRecordingStopReason: String, Sendable, Equatable {
    /// The capture session ended normally.
    case sessionStopped
    /// The tester pressed Stop recording while capture continued.
    case userStopped
    case durationCap
    case byteCap
    case diskSpace
    /// The delivered frame size changed; the encoder cannot continue.
    case dimensionsChanged
    /// Source timestamps jumped backwards, which an asset writer cannot accept.
    case timelineWentBackwards
    case writerFailed
    /// Finalization did not complete within its deadline.
    case finishTimedOut
    /// Recording was requested but no usable frame ever arrived.
    case notStarted
}

/// The bounds a debug recording runs under, in one place.
struct DebugRecordingLimits: Sendable, Equatable {
    /// Ten minutes. Long enough for several hacks; short enough that the file
    /// stays attachable. A full 15-20 minute field run outlasts it on purpose,
    /// which is why the panel has a Stop recording button.
    var maximumDuration = 600.0
    /// 300 MB. At the bitrate below this lands at roughly the same moment as
    /// the duration cap, so neither is a surprise truncation of the other.
    var maximumBytes = 300 * 1024 * 1024
    /// Matches the recognition sampling grid rather than running on a clock of
    /// its own. The promise this feature makes is that the video contains the
    /// frames the recognizer actually analyzed; an independent 30 Hz clock
    /// would break that for the sake of frames nothing else ever saw.
    var maximumFrameRate = 20.0
    /// Refuse to start below this, so recording cannot be what fills the phone.
    var freeSpaceToStart = 800 * 1024 * 1024
    /// Stop if the volume falls below this during a run. The pre-flight check
    /// is a snapshot of a resource other apps are also consuming.
    var freeSpaceToContinue = 200 * 1024 * 1024
    /// The whole of finalization, not one step of it.
    var finishDeadline = 5.0
    /// How many frames the recorder may hold in its own pool.
    ///
    /// This has to cover the encoder's pipeline depth, not just the frames in
    /// flight on our side: `AVAssetWriterInput` retains a buffer past `append`
    /// returning, and measurement showed four exhausting the pool within seven
    /// frames even when each append had already completed. Twelve frames of
    /// 603x1311 4:2:0 is about 14 MB.
    ///
    /// Exhausting it drops a frame and counts it, which is the point: the bound
    /// is on a pool we own, so back pressure degrades the recording instead of
    /// starving the capture stream and, through it, recognition.
    var maximumPooledBuffers = 12
    var averageBitRate = 4_000_000
    /// Sound buffers waiting for the encoder. A wedged encoder drops sound
    /// rather than holding it without bound.
    var maximumPendingAudioBuffers = 64
    /// What the capture stream is asked for when sound is recorded, and what
    /// the AAC track is set up to take.
    static let audioSampleRate = 48_000
    static let audioChannelCount = 2
    /// A backwards jump larger than this is a restarted timeline rather than
    /// jitter. Mirrors the recognition session's own gap policy.
    var backwardsJumpTolerance = 1.0

    static let standard = DebugRecordingLimits()

    var frameInterval: Double { maximumFrameRate > 0 ? 1 / maximumFrameRate : 0 }
}

/// Decides, frame by frame, what the recorder does. Pure and value-typed, so
/// every boundary below can be checked without an encoder, a disk or a device.
struct DebugRecordingGate: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case accept
        /// Above the frame-rate cap.
        case skipRate
        /// Not a frame with new pixels.
        case skipStatus
        /// Same timestamp as one already written, or a small backwards step.
        case skipOutOfOrder
        case stop(DebugRecordingStopReason)
    }

    let limits: DebugRecordingLimits
    private(set) var firstAcceptedTime: Double?
    private(set) var lastAcceptedTime: Double?
    private(set) var acceptedCount = 0

    init(limits: DebugRecordingLimits = .standard) {
        self.limits = limits
    }

    /// `byteCount` and `freeBytes` are sampled on a slower schedule than the
    /// frame rate; they are passed in rather than read here so that this stays
    /// a pure function of its inputs.
    mutating func admit(at time: Double, status: CaptureFrameStatus,
                        byteCount: Int, freeBytes: Int) -> Decision {
        guard time.isFinite else { return .skipOutOfOrder }
        guard status == .complete else { return .skipStatus }

        if let last = lastAcceptedTime {
            if time <= last {
                // A restarted capture timeline cannot be represented in one
                // movie; small jitter is merely dropped.
                if last - time > limits.backwardsJumpTolerance {
                    return .stop(.timelineWentBackwards)
                }
                return .skipOutOfOrder
            }
            // The epsilon mirrors the recognition throttle's: without it,
            // floating-point jitter around an exact interval drops every other
            // frame and halves the recorded rate.
            if time - last < limits.frameInterval - 0.002 { return .skipRate }
        }
        if let first = firstAcceptedTime, time - first >= limits.maximumDuration {
            return .stop(.durationCap)
        }
        if byteCount >= limits.maximumBytes { return .stop(.byteCap) }
        if freeBytes > 0, freeBytes < limits.freeSpaceToContinue { return .stop(.diskSpace) }

        if firstAcceptedTime == nil { firstAcceptedTime = time }
        lastAcceptedTime = time
        acceptedCount += 1
        return .accept
    }

    /// Seconds of source time between the first and last accepted frames. The
    /// movie ends at the last frame with usable pixels, which can be shorter
    /// than the capture session if the screen went static before Stop.
    var coveredDuration: Double {
        guard let first = firstAcceptedTime, let last = lastAcceptedTime else { return 0 }
        return last - first
    }
}

/// Finalization result, separate from the event that requested Stop.
enum DebugRecordingOutcome: String, Sendable, Equatable {
    case finished, notStarted, failed, timedOut
}

/// What the debug panel shows. Every drop is counted by cause, because "the
/// video is missing frames" has several very different explanations.
struct DebugRecordingStatus: Sendable, Equatable {
    var isRecording = false
    var framesAppended = 0
    var framesDroppedRate = 0
    var framesDroppedStatus = 0
    var framesDroppedOutOfOrder = 0
    var framesDroppedPoolFull = 0
    var framesDroppedNotReady = 0
    var framesDroppedFinalization = 0
    /// Only when sound is recorded. Not frames, so not in `totalDropped`.
    var audioSamplesAppended = 0
    var audioSamplesDropped = 0
    var outcome: DebugRecordingOutcome?
    var byteCount = 0
    var coveredDuration = 0.0
    var stopReason: DebugRecordingStopReason?
    /// A line for `events.log` when something happened worth recording.
    var message: String?

    var totalDropped: Int {
        framesDroppedRate + framesDroppedStatus + framesDroppedOutOfOrder
            + framesDroppedPoolFull + framesDroppedNotReady + framesDroppedFinalization
    }

    /// Drops that indicate the recorder could not keep up, as opposed to the
    /// ones it makes on purpose to hold the frame rate.
    var droppedUnderPressure: Int { framesDroppedPoolFull + framesDroppedNotReady }
}
