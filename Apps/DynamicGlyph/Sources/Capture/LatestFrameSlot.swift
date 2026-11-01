import Foundation

/// Hands frames from a producer to a slower consumer queue, keeping only the
/// newest one waiting.
///
/// A frame that waits behind a busy consumer is replaced by the next one rather
/// than queued after it: analysis looks at the screen as it is now, never
/// works through a backlog of stale frames. `merge` lets the replacement carry
/// what must not be lost with the frame it replaces, such as a continuity break.
final class LatestFrameSlot<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Frame?
    private var scheduled = false
    private var supersededCount: UInt64 = 0
    private let merge: (_ older: Frame, _ newer: Frame) -> Frame
    /// Told, under the slot's lock so calls arrive in order, how many frames
    /// wait (0 or 1) after each change, and whether a waiting frame was just
    /// replaced. For the Power section; must be cheap and take no other lock
    /// that could wait on this one.
    private let observe: ((_ waiting: Int, _ replaced: Bool) -> Void)?

    init(merge: @escaping (_ older: Frame, _ newer: Frame) -> Frame = { _, newer in newer },
         observe: ((_ waiting: Int, _ replaced: Bool) -> Void)? = nil) {
        self.merge = merge
        self.observe = observe
    }

    /// Frames replaced before the consumer took them.
    var superseded: UInt64 { lock.withLock { supersededCount } }

    /// Stores `frame` as the one waiting. True when the caller must schedule a
    /// `take()` on the consumer: none is pending yet.
    func put(_ frame: Frame) -> Bool {
        lock.withLock {
            let replaced = waiting != nil
            if let older = waiting {
                supersededCount += 1
                waiting = merge(older, frame)
            } else {
                waiting = frame
            }
            observe?(1, replaced)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }

    /// The newest frame, on the consumer. A frame put after this schedules
    /// another take.
    func take() -> Frame? {
        lock.withLock {
            let frame = waiting
            waiting = nil
            scheduled = false
            if frame != nil { observe?(0, false) }
            return frame
        }
    }

    /// Drops the waiting frame. A pending take then finds nothing.
    func clear() {
        lock.withLock {
            if waiting != nil { observe?(0, false) }
            waiting = nil
        }
    }
}

extension CapturedFrame {
    /// The newer frame, still marked broken when the frame it replaces was.
    static func superseding(_ older: CapturedFrame, with newer: CapturedFrame) -> CapturedFrame {
        guard older.continuityBroken, !newer.continuityBroken else { return newer }
        return CapturedFrame(sampleBuffer: newer.sampleBuffer, metadata: newer.metadata,
                             arrivalUptime: newer.arrivalUptime,
                             deliveryGapMilliseconds: newer.deliveryGapMilliseconds, continuityBroken: true)
    }
}
