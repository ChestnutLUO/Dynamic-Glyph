import AVFoundation
import Foundation
import GlyphRecognition

/// Feeds the Picture in Picture layer from a background queue.
///
/// iOS 27 deprecates `AVSampleBufferVideoRenderer`'s direct enqueue path in
/// favour of a receiver obtained from an `AVSampleBufferRenderSynchronizer`.
/// The deprecated calls below are deliberate and the warnings are left visible.
/// The new path changes the timing model from "display immediately" to a
/// synchronizer timeline, and its interaction with
/// `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)` is
/// untested here; this path is the one Spike A demonstrated keeping a session
/// alive on device. Migrating it is follow-up work with its own device test,
/// not something to slip in underneath the display this milestone is about.
///
/// Two separate rates, on purpose. Frames are enqueued at a steady 15 Hz
/// because that is the cadence Spike A kept a session alive with, and nothing
/// yet shows that event-only enqueueing survives backgrounding on this OS.
/// Pixels are only redrawn when the model actually changed, so a held
/// presentation costs one draw and then repeats.
final class GlyphPiPRenderLoop {
    struct Stats: Sendable {
        var ticks: UInt64 = 0
        var enqueued: UInt64 = 0
        var redraws: UInt64 = 0
        var notReady: UInt64 = 0
        var rendererFailures: UInt64 = 0
        var poolExhausted: UInt64 = 0
        var lastEnqueueUptime: Double = 0
    }

    /// Called on the main queue for anything worth putting in the event log.
    var onEvent: ((String) -> Void)?

    private let lock = NSLock()
    private var stats = Stats()
    private var pending: GlyphDisplaySnapshot
    private var drawnKey: String?
    private var drawnBuffer: CVPixelBuffer?

    private let layer: AVSampleBufferDisplayLayer
    private var factory: GlyphFrameFactory
    private let table: GlyphTable?
    private var pendingCanvas: PiPCanvasConfiguration
    private var windowWidth: Double?
    /// The Diagnostics debug fill, read once a tick; nil draws as always.
    private let readingMode: ReadingModeSignal?
    private let queue = DispatchQueue(label: "spikeB.pip.render", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?

    init(layer: AVSampleBufferDisplayLayer, table: GlyphTable?, initial: GlyphDisplaySnapshot,
         canvas: PiPCanvasConfiguration = .standard, readingMode: ReadingModeSignal? = nil) {
        self.layer = layer
        self.readingMode = readingMode
        self.table = table
        self.factory = GlyphFrameFactory(table: table, canvas: canvas)
        self.pendingCanvas = canvas
        self.pending = initial
    }

    func update(_ snapshot: GlyphDisplaySnapshot) {
        lock.lock()
        pending = snapshot
        lock.unlock()
    }

    func updateCanvas(_ canvas: PiPCanvasConfiguration) {
        lock.lock()
        pendingCanvas = canvas
        lock.unlock()
    }

    /// The floating window's width in points, as iOS reports it.
    func updateWindowWidth(_ width: Double) {
        lock.lock()
        windowWidth = width
        lock.unlock()
    }

    func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    func start() {
        // A DispatchSourceTimer rather than CADisplayLink: the latter stops in
        // the background, which is when this display matters most.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 15.0, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.drawnBuffer = nil
            self.drawnKey = nil
            self.lock.unlock()
            self.layer.sampleBufferRenderer.flush()
        }
    }

    private func tick() {
        // The Power section's floating-window time: every tick, and the
        // redraws within them.
        let meter = PowerMeter.shared
        let tickStarted = meter.now()
        defer { meter.finish(.pipTick, since: tickStarted) }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let snapshot = pending
        let canvas = pendingCanvas
        let windowWidth = windowWidth
        var previousKey = drawnKey
        var buffer = drawnBuffer
        lock.unlock()
        // Changes only when the gate's pace or the switch does, so a steady
        // state still costs one draw.
        let tint = readingMode?.displayed ?? .none

        // Pool, format description and cached pixels change together on the
        // render queue. Never wrap an old-size buffer in the new format.
        if factory.canvas != canvas {
            factory = GlyphFrameFactory(table: table, canvas: canvas)
            layer.sampleBufferRenderer.flush()
            buffer = nil
            previousKey = nil
            lock.lock()
            drawnBuffer = nil
            drawnKey = nil
            lock.unlock()
            report("canvas applied: \(canvas.width)x\(canvas.height) at \(canvas.resolution)x")
        }

        // Everything the frame actually shows has to be in this key. Keying on
        // `revision` alone left the highlight and the visible shape stale for
        // the whole of the input phase, because the indicator advancing is a
        // reading rather than a tracking decision. The status line carries
        // freshness, so a model that has not changed still redraws once a
        // second as it goes stale.
        var key = "\(snapshot.captureSessionID).\(snapshot.hackID).\(snapshot.revision)."
            + "\(snapshot.currentSlotIndex ?? -1).\(snapshot.inputSlotIndex ?? -1)."
            + "\(snapshot.provisionalGlyph?.name ?? "-").\(snapshot.indicatorsObstructed)."
            + "\(Int(snapshot.age(atUptime: now)))." + snapshot.statusLine(atUptime: now)
            + ".\(windowWidth ?? 0)." + snapshot.inputCheckRenderKey(atUptime: now)
            + ".gear:" + (snapshot.visibleGear(atUptime: now)?.renderKey ?? "-")
        key += ".tint:\(tint.rawValue)"
        if key != previousKey || buffer == nil {
            let drawStarted = meter.now()
            let made = factory.makePixelBuffer(snapshot, atUptime: now, windowWidth: windowWidth, tint: tint)
            meter.finish(.pipDraw, since: drawStarted)
            guard let drawn = made else {
                lock.lock(); stats.poolExhausted &+= 1; stats.ticks &+= 1; lock.unlock()
                return
            }
            buffer = drawn
            lock.lock()
            drawnBuffer = drawn
            drawnKey = key
            stats.redraws &+= 1
            lock.unlock()
        }

        lock.lock(); stats.ticks &+= 1; lock.unlock()
        guard let buffer, let sample = factory.makeSampleBuffer(from: buffer) else { return }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            lock.lock(); stats.rendererFailures &+= 1; lock.unlock()
            report("PiP renderer failed: \(renderer.error?.localizedDescription ?? "unknown") — flushing")
            renderer.flush()
            return
        }
        guard renderer.isReadyForMoreMediaData else {
            lock.lock(); stats.notReady &+= 1; lock.unlock()
            return
        }
        renderer.enqueue(sample)
        lock.lock()
        stats.enqueued &+= 1
        stats.lastEnqueueUptime = now
        lock.unlock()
    }

    private func report(_ message: String) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(message) }
    }
}
