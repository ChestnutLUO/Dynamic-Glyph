import Foundation

/// Decides, frame by frame, whether a ReplayKit capture may have lost
/// something since its previous frame.
///
/// Unlike ScreenCaptureKit, a broadcast is not known to keep delivering while
/// the screen is still, so a pause between frames is never a break by itself:
/// only an explicit signal is. Frames missed, torn or rejected in the ring; a
/// frame the app had to drop; the broadcast pausing; a stale heartbeat; or a
/// new session.
struct BroadcastContinuity: Sendable {
    /// A heartbeat older than this means the extension stalled.
    static let stallAfter = 1.5
    /// And older than this, that it is gone.
    static let deadAfter = 3.0

    /// Silence is evidence of a still screen only while the producer is live.
    /// A pause, stop, unknown state or stale heartbeat must not settle the gate.
    static func canAdvanceStill(state: FrameRingProducerState?, heartbeatAge: Double) -> Bool {
        state == .running && heartbeatAge >= 0 && heartbeatAge < stallAfter
    }

    private var lastArrival: Double?
    private var lastLosses: UInt64 = 0
    private var interrupted = false
    private var hasStillBaseline = false

    /// A heartbeat alone cannot restore pixels made uncertain by a loss.
    func mayAdvanceStill(state: FrameRingProducerState?, heartbeatAge: Double) -> Bool {
        hasStillBaseline && Self.canAdvanceStill(state: state, heartbeatAge: heartbeatAge)
    }

    mutating func interrupt() {
        interrupted = true
        hasStillBaseline = false
    }

    /// Called after a valid image is admitted to the recognition queue.
    mutating func deliveredFrame() { hasStillBaseline = true }

    /// Ring reads can reject or tear a slot without delivering any frame.
    mutating func noteLosses(_ losses: UInt64) {
        if losses != lastLosses {
            interrupt()
            lastLosses = losses
        }
    }

    /// `losses` is the reader's running total of frames missed, torn or rejected.
    mutating func frame(arrival: Double, losses: UInt64) -> CallbackGapMonitor.Arrival {
        noteLosses(losses)
        defer {
            lastArrival = arrival
            interrupted = false
        }
        return CallbackGapMonitor.Arrival(gapMilliseconds: lastArrival.map { (arrival - $0) * 1000 },
                                          continuityBroken: interrupted)
    }
}
