/// Frame counts for the Diagnostics page.
///
/// Kept on the recognition queue and published with recognition updates, on
/// their throttle. Counting on the main actor meant a hop and a view rebuild
/// for every captured frame, idle ones included, whether or not anyone was
/// looking at the numbers.
struct CaptureCounters: Sendable, Equatable {
    private(set) var frames = 0
    private(set) var completeFrames = 0
    private(set) var idleFrames = 0
    /// Frames whose coarse picture hash differs from the one before: live
    /// content rather than the same frame over and over.
    private(set) var changedFrames = 0
    private var lastHash: UInt64 = 0

    /// Returns whether this frame's picture changed; a zero hash is unknown.
    @discardableResult
    mutating func count(_ status: CaptureFrameStatus, hash: UInt64) -> Bool {
        frames += 1
        if status == .complete { completeFrames += 1 }
        if status == .idle { idleFrames += 1 }
        let changed = hash != lastHash && hash != 0
        if changed { changedFrames += 1 }
        lastHash = hash
        return changed
    }
}
