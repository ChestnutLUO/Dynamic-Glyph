import Foundation
import Vision

/// Stops one gear read early: the OCR lane asks for it when a new panel
/// replaces the one the read is reading (`GameTextSchedule.observeGearPanel`).
///
/// `cancel()` cancels the Vision request running now, and the read throws
/// `CancellationError` before it starts another pass. The read still owns the
/// lane until it returns, so the lane never runs two Vision requests at once.
/// A read whose last pass finished before `cancel()` returns its evidence as
/// usual. Owned by one read; `cancel()` may come from any thread.
public final class GearReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running: VNRequest?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let request: VNRequest? = lock.withLock {
            cancelled = true
            return running
        }
        // Outside the lock: Vision may call back into a finishing request.
        request?.cancel()
    }

    /// Throws if the read was asked to stop.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Before a Vision request starts: throws instead if already cancelled.
    func begin(_ request: VNRequest) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            running = request
        }
    }

    func end() {
        lock.withLock { running = nil }
    }
}
