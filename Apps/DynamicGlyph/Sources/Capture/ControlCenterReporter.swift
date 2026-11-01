import Foundation

/// Keeps the Control Center switch truthful about the app's capture, and
/// hears the switch's Stop.
///
/// While a capture the app runs itself is going (ScreenCaptureKit, iOS 27),
/// a report in the App Group is renewed every second; when it ends, the
/// report says so at once. A broadcast (iOS 18-26) is reported by its
/// extension through the frame ring instead, since the app may be suspended
/// while it goes on. Either way the switch is reloaded at every start and end.
// Sendability: everything but `queue` is confined to `queue`.
final class ControlCenterReporter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.szres.DynamicGlyph.control-center", qos: .utility)
    private let store = ControlCaptureStore.appGroup
    private var session: UUID?
    private var timer: DispatchSourceTimer?
    private var observer: DarwinObserver?
    private var onStop: (@Sendable () -> Void)?

    /// `onStop` runs, on a queue of the system's choosing, while the switch
    /// asks the reported capture to stop; possibly more than once.
    func start(onStop: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onStop = onStop
            observer = DarwinObserver(ControlChannel.stopRequested) { [weak self] in
                self?.queue.async { self?.checkForStop() }
            }
            // A new process captures nothing yet, whatever an earlier one left.
            store?.write(ControlCaptureBeacon(session: nil, heartbeat: FrameRingClock.uptimeNanoseconds()))
            ControlChannel.reload()
        }
    }

    /// `reportsHeartbeat` is for a capture in this process; a broadcast
    /// reports its own.
    func captureStarted(reportsHeartbeat: Bool) {
        queue.async { [self] in
            stopTimer()
            guard reportsHeartbeat else {
                session = nil
                ControlChannel.reload()
                return
            }
            session = UUID()
            beat()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.beat()
                self?.checkForStop()
            }
            timer.resume()
            self.timer = timer
            ControlChannel.reload()
        }
    }

    /// Ended by the player, iOS, an interruption or a failed start.
    func captureEnded() {
        queue.async { [self] in
            stopTimer()
            session = nil
            store?.write(ControlCaptureBeacon(session: nil, heartbeat: FrameRingClock.uptimeNanoseconds()))
            ControlChannel.reload()
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func beat() {
        guard let session else { return }
        store?.write(ControlCaptureBeacon(session: session, heartbeat: FrameRingClock.uptimeNanoseconds()))
    }

    private func checkForStop() {
        guard ControlCaptureState.answers(store?.readStopRequest(), session: session) else { return }
        onStop?()
    }
}
