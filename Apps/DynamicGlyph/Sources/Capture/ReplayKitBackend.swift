import CoreMedia
import Foundation
import ReplayKit
import UIKit

/// Capture through a ReplayKit broadcast, for iOS 18-26 where ScreenCaptureKit
/// is unavailable.
///
/// The broadcast extension is a separate process that only publishes frames;
/// recognition stays in the app. The app keeps executing in the background
/// only while the floating window is open, so this backend requires it.
@MainActor
final class ReplayKitBackend: CaptureBackend {
    weak var delegate: CaptureBackendDelegate?
    let requiresFloatingWindow = true

    private var request: CaptureRequest?
    private var link: BroadcastLink?
    private var picker: RPSystemBroadcastPickerView?
    private var consentTimeout: Task<Void, Never>?
    private var isAttached = false
    /// The link of an abandoned start, still ending any broadcast it began.
    private var lateWatch: BroadcastLink?
    /// The sheet reports nothing when the player dismisses it, so a request
    /// with no broadcast after this long is taken as cancelled.
    private static let consentPatience: Duration = .seconds(30)
    /// After a start is abandoned, the broadcast the sheet was asked for can
    /// still begin: its countdown alone is three seconds.
    private static let lateBroadcastWindow = 10.0

    var isAvailable: Bool { BroadcastChannel.ringURL != nil }
    var hasSession: Bool { request != nil }

    func requestConsent() {
        guard request == nil else { return }
        // The broadcast this start asks for is wanted.
        lateWatch?.stopWatchingForLateBroadcast()
        lateWatch = nil
        let request = CaptureRequest(delegate: delegate)
        self.request = request
        let link = BroadcastLink { [weak self] event in
            Task { @MainActor in self?.handle(event, for: request) }
        }
        self.link = link
        link.start()
        guard presentPicker() else {
            request.fail(.consentFailed, message: "broadcast picker offered no button",
                         status: "broadcast picker unavailable")
            return
        }
        delegate?.captureBackendNote("broadcast picker presented", status: "picker presented -- start the broadcast")
        consentTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.consentPatience)
            guard !Task.isCancelled, let self, self.request === request, !self.isAttached else { return }
            request.fail(.consentCancelled, message: "no broadcast within 30 s", status: "picker cancelled")
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        let stopping = link, attached = isAttached
        detach(requestingStop: true)
        guard attached else {
            // Nothing is delivering: the engine need not wait for the watch.
            watchForLateBroadcast(on: stopping)
            return Task {}
        }
        return Task { await stopping?.finish() }
    }

    func reset() {
        let stopping = link, attached = isAttached
        detach(requestingStop: true)
        if attached { Task { await stopping?.finish() } }
        else { watchForLateBroadcast(on: stopping) }
    }

    private func watchForLateBroadcast(on link: BroadcastLink?) {
        guard let link else { return }
        lateWatch = link
        link.beginWatchingForLateBroadcast()
        Task {
            await link.endLateBroadcast(within: Self.lateBroadcastWindow)
            if lateWatch === link { lateWatch = nil }
        }
    }

    private func detach(requestingStop: Bool) {
        request?.invalidate()
        request = nil
        consentTimeout?.cancel()
        consentTimeout = nil
        dismissPicker()
        link?.detach(requestingStop: requestingStop && isAttached)
        link = nil
        isAttached = false
    }

    private func handle(_ event: BroadcastLink.Event, for request: CaptureRequest) {
        guard request.isActive, self.request === request, let link else { return }
        switch event {
        case .started(let session):
            guard !isAttached else { return }
            dismissPicker()
            consentTimeout?.cancel()
            delegate?.captureBackendNote("broadcast session \(String(session, radix: 16)) started", status: nil)
            guard let sinks = delegate?.captureBackendWillStart() else { return }
            // The engine may have abandoned the start while preparing sinks.
            guard self.request === request else { return }
            isAttached = true
            link.attach(sinks)
            request.didStart()
        case .ended(let reason, let failure):
            guard isAttached else { return }
            request.fail(failure, message: "broadcast ended: \(reason)", status: "broadcast ended")
        }
    }

    // MARK: - Picker

    /// RPSystemBroadcastPickerView opens its sheet only from its own button.
    /// This path runs only on iOS 18-26, whose picker is fixed and keeps that
    /// button as an ordinary UIButton subview.
    private func presentPicker() -> Bool {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return false }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastChannel.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.alpha = 0
        window.addSubview(picker)
        guard let button = Self.button(in: picker) else {
            picker.removeFromSuperview()
            return false
        }
        self.picker = picker
        button.sendActions(for: .touchUpInside)
        return true
    }

    private func dismissPicker() {
        picker?.removeFromSuperview()
        picker = nil
    }

    private static func button(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = button(in: subview) { return nested }
        }
        return nil
    }
}

/// The app's end of the frame ring. It copies frames out on a queue of its own
/// as soon as the extension announces them, so the ring only has to cover this
/// queue's latency, and hands them to recognition on the recognition queue.
/// Only the newest frame waits there: one recognition has not started on yet
/// is replaced, not queued behind, so a slow frame never leaves a backlog.
// Sendability: `sinks`, `latest`, `isDelivering`, `pending` and
// `watchingForLate` are guarded by `lock`; the slot `latest` holds locks
// itself; everything else is confined to `queue`.
final class BroadcastLink: @unchecked Sendable {
    enum Event: Sendable {
        /// A running broadcast with a fresh heartbeat appeared.
        case started(session: UInt64)
        /// The broadcast finished, failed, or its extension stopped responding.
        case ended(String, CaptureBackendFailure)
    }

    private let queue = DispatchQueue(label: "org.szres.DynamicGlyph.broadcast.copier", qos: .userInitiated)
    private let lock = NSLock()
    private var sinks: CaptureSinks?
    private var isDelivering = false
    /// A replaced frame is like one the 20-Hz sampler skips, not a loss: the
    /// replacement keeps any continuity break the replaced frame carried.
    /// A new one for each attach, so a take still queued for the previous
    /// capture finds its own, cleared slot and never a new capture's frame.
    private var latest = BroadcastLink.makeSlot()
    /// Without power saving, as before: frames queue for recognition up to
    /// this many, and one dropped past it breaks continuity like any loss.
    static let maximumPending = 40
    private var pending = 0
    private var watchingForLate = false

    /// The newest-frame slot, reporting to the Power section: its depth (one
    /// frame at most) and each replaced frame as a backlog drop, the
    /// newest-only counterpart of a frame turned away from a full queue.
    private static func makeSlot() -> LatestFrameSlot<CapturedFrame> {
        LatestFrameSlot(merge: CapturedFrame.superseding) { waiting, replaced in
            // Under the slot's lock, so depths reach the meter in order.
            // The meter's lock never takes another.
            if replaced { PowerMeter.shared.count(.backlogDropped) }
            PowerMeter.shared.setQueueDepth(waiting, capacity: 1)
        }
    }

    private let onEvent: @Sendable (Event) -> Void
    private var reader: FrameRingReader?
    private var continuity = BroadcastContinuity()
    private var timer: DispatchSourceTimer?
    private var observer: DarwinObserver?
    private var announced: UInt64 = 0
    /// When the newest frame handed to recognition arrived, on the uptime clock.
    private var lastFrameArrival = -Double.infinity
    private var endReported = false
    private var format: (key: String, description: CMVideoFormatDescription)?

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            observer = DarwinObserver(BroadcastChannel.framesPublished) { [weak self] in
                self?.queue.async { self?.drain() }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func attach(_ sinks: CaptureSinks) {
        lock.withLock {
            self.sinks = sinks
            latest = Self.makeSlot()
            isDelivering = true
        }
        queue.async { [self] in drain() }
    }

    /// Stops delivering at once; asks the extension to end the broadcast if
    /// this link was attached to one.
    func detach(requestingStop: Bool) {
        lock.withLock {
            isDelivering = false
            sinks = nil
            latest.clear()
        }
        guard requestingStop else { return }
        queue.async { [self] in
            reader?.requestStop()
            BroadcastChannel.post(BroadcastChannel.stopRequested)
        }
    }

    /// Returns once the extension reports the broadcast over, or after two
    /// seconds, then stops watching.
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in wait(until: ProcessInfo.processInfo.systemUptime + 2, then: done) }
        }
    }

    /// For a start given up on before its broadcast arrived. Ends a broadcast
    /// that is live now or starts within `window` seconds, so nothing goes on
    /// sharing the screen unwatched, then stops watching.
    /// Call `beginWatchingForLateBroadcast` first, synchronously, so a later
    /// `stopWatchingForLateBroadcast` wins however the tasks are scheduled.
    func endLateBroadcast(within window: Double) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in watchForLateBroadcast(until: ProcessInfo.processInfo.systemUptime + window, then: done) }
        }
    }

    func beginWatchingForLateBroadcast() { lock.withLock { watchingForLate = true } }

    /// A new start owns any broadcast from here on.
    func stopWatchingForLateBroadcast() { lock.withLock { watchingForLate = false } }

    private func watchForLateBroadcast(until deadline: Double, then done: CheckedContinuation<Void, Never>) {
        openRing()
        let now = ProcessInfo.processInfo.systemUptime
        // Checked and asked under the lock, so a new start that takes over
        // the broadcast in between never has its own broadcast ended, which
        // it would take for the Control Center switch's stop.
        let watch = lock.withLock { () -> LateWatch in
            guard watchingForLate else { return .over }
            guard let reader, reader.stopLiveSession(freshness: BroadcastContinuity.stallAfter) else { return .waiting }
            watchingForLate = false
            return .asked
        }
        if watch == .over {
            wait(until: now, then: done)
        } else if watch == .asked {
            BroadcastChannel.post(BroadcastChannel.stopRequested)
            wait(until: now + 2, then: done)
        } else if now >= deadline {
            wait(until: now, then: done)
        } else {
            queue.asyncAfter(deadline: .now() + 0.25) { [self] in watchForLateBroadcast(until: deadline, then: done) }
        }
    }

    private enum LateWatch { case over, asked, waiting }

    private func wait(until deadline: Double, then done: CheckedContinuation<Void, Never>) {
        let state = reader?.producerState
        if state != .running && state != .paused || ProcessInfo.processInfo.systemUptime >= deadline {
            timer?.cancel()
            timer = nil
            observer = nil
            reader = nil
            done.resume()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in wait(until: deadline, then: done) }
    }

    // MARK: On `queue`

    private func poll() {
        openRing()
        guard let reader else { return }
        let state = reader.producerState
        let age = reader.producerHeartbeatAge()
        let session = reader.producerSession
        if state == .running, age < BroadcastContinuity.stallAfter, session != 0, session != announced {
            announced = session
            endReported = false
            onEvent(.started(session: session))
        }
        guard announced != 0, lock.withLock({ isDelivering }) else { return }
        // Four times a second, for the Diagnostics page's Power section.
        PowerMeter.shared.noteExtension(published: reader.published, dropped: reader.producerDropped,
                                        overwritten: reader.overwrittenUnread,
                                        lost: reader.counters.missed + reader.counters.torn + reader.counters.rejected)
        if !BroadcastContinuity.canAdvanceStill(state: state, heartbeatAge: age) { continuity.interrupt() }
        let over = state == .finished || state == .failed
        if !endReported, over || age > BroadcastContinuity.deadAfter {
            endReported = true
            // A killed extension leaves no reason, only a stale heartbeat: its
            // last peak footprint is then the best clue to a memory limit.
            let cause = over ? "\(state.map { "\($0)" } ?? "?") (\(reader.producerEndReason.map { "\($0)" } ?? "?"))"
                             : String(format: "heartbeat %.1f s old", age)
            let peak = Double(reader.producerPeakFootprint) / 1_048_576
            let failure = over ? CaptureBackendFailure.broadcastEnded(reader.producerEndReason) : .interrupted
            onEvent(.ended(String(format: "%@; extension peak %.1f MB; %llu overwritten, %llu dropped, "
                                  + "%llu missed, %llu torn, %llu rejected, %llu superseded",
                                  cause, peak, reader.overwrittenUnread, reader.producerDropped,
                                  reader.counters.missed, reader.counters.torn, reader.counters.rejected,
                                  lock.withLock { latest.superseded }),
                           failure))
        }
        drain()
        // The extension publishes nothing while the screen is still. While its
        // heartbeat says the producer is live, that silence may be a still
        // screen, provided no known loss invalidated the last image. This
        // cannot detect a ReplayKit callback stall while the producer's own
        // heartbeat timer remains live. Recognition is told so: its analysis
        // pace then settles as it would on unchanged frames. Only once frames
        // have stopped, so frames still coming cost no extra hop.
        let stillUptime = ProcessInfo.processInfo.systemUptime
        if continuity.mayAdvanceStill(state: state, heartbeatAge: age),
           stillUptime - lastFrameArrival >= LiveGlyphOutput.stillLookInterval,
           let sinks = lock.withLock({ isDelivering ? self.sinks : nil }), sinks.recognition.powerSaving {
            // Use the instant vouched for by this poll, not the eventual
            // queue execution time: a backed-up queue cannot extend a stale
            // heartbeat's permission to advance the gate.
            sinks.recognitionQueue.async { sinks.recognition.noteStillScreen(uptime: stillUptime) }
        }
    }

    /// Maps the ring once the extension has created it, and again if the
    /// extension had to replace the file.
    private func openRing() {
        guard let url = BroadcastChannel.ringURL else { return }
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        if let reader, reader.ring.inode == UInt64(info.st_ino) { return }
        guard let mapping = try? FrameRingMapping.open(at: url) else { return }
        reader = FrameRingReader(ring: mapping)
        // A new reader's own counts start over.
        PowerMeter.shared.restartExtensionCounts()
        continuity.interrupt()
    }

    private func drain() {
        guard let reader,
              let delivery = lock.withLock({ isDelivering ? self.sinks.map { ($0, self.latest) } : nil })
        else { return }
        let (sinks, latest) = delivery
        while true {
            switch reader.next() {
            case .nothingNew:
                continuity.noteLosses(reader.counters.missed + reader.counters.torn + reader.counters.rejected)
                return
            case .sessionChanged:
                continuity.interrupt()
            case .frame(let frame):
                let losses = reader.counters.missed + reader.counters.torn + reader.counters.rejected
                let arrival = continuity.frame(arrival: frame.arrivalUptime, losses: losses)
                lastFrameArrival = frame.arrivalUptime
                guard let sample = sampleBuffer(for: frame) else {
                    continuity.interrupt()
                    continue
                }
                let newestOnly = sinks.recognition.powerSaving
                var backlogFull = false
                let admitted = lock.withLock { () -> Bool in
                    guard isDelivering else { return false }
                    // The slot reports its own depth and replaced frames.
                    guard !newestOnly else { return true }
                    guard pending < Self.maximumPending else { backlogFull = true; return false }
                    pending += 1
                    // Under the same lock, so depths reach the meter in order.
                    // The meter's lock never takes another.
                    PowerMeter.shared.setQueueDepth(pending, capacity: Self.maximumPending)
                    return true
                }
                guard admitted else {
                    if backlogFull { PowerMeter.shared.count(.backlogDropped) }
                    continuity.interrupt()
                    continue
                }
                let captured = CapturedFrame(
                    sampleBuffer: sample,
                    metadata: CaptureFrameMetadata(status: .complete,
                                                   orientation: frame.orientation == 0 ? nil : frame.orientation),
                    arrivalUptime: frame.arrivalUptime, deliveryGapMilliseconds: arrival.gapMilliseconds,
                    continuityBroken: arrival.continuityBroken)
                continuity.deliveredFrame()
                guard newestOnly else {
                    sinks.recognitionQueue.async { [weak self] in
                        sinks.recognition.process(captured)
                        guard let self else { return }
                        self.lock.withLock {
                            self.pending -= 1
                            PowerMeter.shared.setQueueDepth(self.pending, capacity: Self.maximumPending)
                        }
                    }
                    continue
                }
                guard latest.put(captured) else { continue }
                sinks.recognitionQueue.async { [latest] in
                    guard let frame = latest.take() else { return }
                    sinks.recognition.process(frame)
                }
            }
        }
    }

    private func sampleBuffer(for frame: FrameRingReader.Frame) -> CMSampleBuffer? {
        let pixels = frame.pixelBuffer
        let key = "\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))/"
            + "\(CVPixelBufferGetPixelFormatType(pixels))"
        if format?.key != key {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                               formatDescriptionOut: &description) == noErr,
                  let description else { return nil }
            format = (key, description)
        }
        guard let description = format?.description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: frame.presentationTime,
                                                                      preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
