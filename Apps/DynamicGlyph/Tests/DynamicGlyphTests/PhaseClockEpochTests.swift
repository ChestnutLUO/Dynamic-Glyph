import CoreGraphics
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

@Suite("Phase clock epoch ownership")
struct PhaseClockEpochTests {
    private let session = CaptureSessionID(rawValue: 71)

    @Test("An old phase completion keeps the lane but cannot refill a new clock epoch",
          arguments: PhaseClockJump.allCases)
    func lateHeaderAcrossClockJump(_ jump: PhaseClockJump) async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        let frame = try image()
        reader.submit(frame, at: jump.oldTime, session: session)
        await barrier.waitForStart(1)
        reader.invalidatePhase()
        #expect(reader.isReading)
        reader.submit(frame, at: jump.newTime, session: session)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == 1)
        await barrier.release(sourceTime: jump.oldTime)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.snapshotMetrics().completed == 0)
        #expect(reader.reading(for: jump.oldTime, session: session) == nil)
        #expect(reader.reading(for: jump.newTime, session: session) == nil)

        reader.submit(frame, at: jump.newTime, session: session)
        await barrier.waitForStart(2)
        #expect(reader.isReading)
        #expect(reader.snapshotMetrics().submitted == 2)
        await barrier.release(sourceTime: jump.newTime)
        try await waitForIdle(reader)
        let fresh = try #require(reader.reading(for: jump.newTime, session: session))
        #expect(fresh.sourceTime == jump.newTime)
        #expect(fresh.phase == .input)
        #expect(reader.snapshotMetrics().completed == 1)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(await barrier.sourceTimes == [jump.oldTime, jump.newTime])
    }

    @Test("Phase invalidation clears cached headers and pending command reads",
          arguments: [false, true])
    func clearsCachedPhase(_ command: Bool) async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        let frame = try image()
        let commands = command ? try commandCapture(at: 1) : nil
        reader.submit(frame, at: 1, session: session, commands: commands)
        await barrier.waitForStart(1)
        await barrier.release(sourceTime: 1)
        try await waitForIdle(reader)
        #expect(reader.reading(for: 1, session: session)?.sourceTime == 1)
        if command {
            // A completed command owns its pending payload until drained.
            reader.submit(frame, at: 1.25, session: session)
            #expect(reader.snapshotMetrics().submitted == 1)
            #expect(reader.snapshotMetrics().droppedBusy == 1)
        }
        reader.invalidatePhase()
        #expect(reader.reading(for: 1, session: session) == nil)
        #expect(reader.takeCommand() == nil)
        reader.submit(frame, at: 1.0625, session: session)
        #expect(reader.snapshotMetrics().submitted == 1)
        reader.submit(frame, at: 1.25, session: session)
        await barrier.waitForStart(2)
        await barrier.release(sourceTime: 1.25)
        try await waitForIdle(reader)
        #expect(reader.reading(for: 1.25, session: session)?.sourceTime == 1.25)
        #expect(reader.snapshotMetrics().completed == 2)
    }

    @Test("An old command completion cannot restore either phase payload")
    func lateCommandAcrossClockJump() async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        let frame = try image(), commands = try commandCapture(at: 100)
        reader.submit(frame, at: 100, session: session, commands: commands)
        await barrier.waitForStart(1)
        reader.invalidatePhase()
        reader.submit(frame, at: 1, session: session)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.isReading)
        await barrier.release(sourceTime: 100)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.takeCommand() == nil)
        #expect(reader.reading(for: 100, session: session) == nil)
        #expect(reader.reading(for: 1, session: session) == nil)
    }

    @Test("Closing a session still rejects its in-flight completion and mismatched consumers")
    func closedSession() async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        let frame = try image(), nextSession = CaptureSessionID(rawValue: 72)
        reader.submit(frame, at: 1, session: session)
        await barrier.waitForStart(1)
        reader.invalidate()
        reader.invalidatePhase()
        reader.submit(frame, at: 1.25, session: nextSession)
        #expect(reader.snapshotMetrics().submitted == 1)
        await barrier.release(sourceTime: 1)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.reading(for: 1, session: session) == nil)
        #expect(reader.reading(for: 1, session: nextSession) == nil)
        reader.submit(frame, at: 1.25, session: nextSession)
        await barrier.waitForStart(2)
        await barrier.release(sourceTime: 1.25)
        try await waitForIdle(reader)
        #expect(reader.reading(for: 1.25, session: nextSession)?.sourceTime == 1.25)
        #expect(reader.reading(for: 1.25, session: session) == nil)
    }

    @Test("Header freshness includes zero and maximum age, but excludes future and expired evidence")
    func freshnessBoundaries() async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        reader.submit(try image(), at: 0, session: session)
        await barrier.waitForStart(1)
        // Zero avoids subtraction rounding at the exact 0.35-second cutoff.
        await barrier.release(sourceTime: 0, phase: .unknown)
        try await waitForIdle(reader)
        #expect(reader.reading(for: 0, session: session)?.phase == .unknown)
        #expect(reader.reading(for: 0.35, session: session)?.sourceTime == 0)
        #expect(reader.reading(for: Double(0.35).nextUp, session: session) == nil)
        #expect(reader.reading(for: -Double.leastNonzeroMagnitude, session: session) == nil)
        #expect(reader.reading(for: .nan, session: session) == nil)
        #expect(reader.reading(for: .infinity, session: session) == nil)
    }

    @Test("Header payload timestamps must be finite and exactly match their request",
          arguments: PhasePayloadClock.allCases)
    func rejectsForgedSourceTime(_ clock: PhasePayloadClock) async throws {
        let barrier = PhaseHeaderBarrier()
        let reader = GameHeaderReader(headerOperation: { _, time in await barrier.read(at: time) })
        let frame = try image()
        reader.submit(frame, at: 1, session: session)
        await barrier.waitForStart(1)
        await barrier.release(sourceTime: clock.time)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.snapshotMetrics().completed == 0)
        #expect(reader.snapshotMetrics().failed == 0)
        #expect(reader.reading(for: 1, session: session) == nil)
        #expect(reader.reading(for: clock.time, session: session) == nil)
        // Rejection releases the lane, without resetting its cadence.
        reader.submit(frame, at: 1.0625, session: session)
        #expect(reader.snapshotMetrics().submitted == 1)
        reader.submit(frame, at: 1.125, session: session)
        await barrier.waitForStart(2)
        await barrier.release(sourceTime: 1.125)
        try await waitForIdle(reader)
        #expect(reader.reading(for: 1.125, session: session)?.sourceTime == 1.125)
    }

    @Test("Phase-only invalidation preserves in-flight and cached panel ownership exactly",
          arguments: PhasePanelMode.allCases)
    func preservesPanels(_ mode: PhasePanelMode) async throws {
        let frame = try image(), context = ResultReadContext(sessionID: session, hackID: 9, glyphs: [nil, "xm"])
        let probe = PhasePanelProbe(mode: mode, invalidateOwner: false)
        let reader = panelReader(probe)
        probe.install(reader)
        submitPanel(reader, mode: mode, frame: frame, context: context)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().completed == 1)
        #expect(reader.snapshotMetrics().staleCompletions == 0)
        reader.invalidatePhase()
        // A completed panel must still prevent overwrite until take().
        submitPanel(reader, mode: mode, frame: frame, context: context, at: 10.5)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == (mode == .result ? 1 : 2))
        switch mode {
        case .result:
            let read = try #require(reader.takeResult())
            #expect(read.evidence == ResultFrameEvidence(context: context, sourceTime: 10,
                panelPresent: true, appearances: [.unreadable]))
            #expect(read.image === frame)
            #expect(reader.takeResult() == nil)
            #expect(reader.snapshotMetrics().resultCompleted == 1)
        case .gear:
            #expect(reader.pendingGearSourceTime == 10)
            let read = try #require(reader.takeGear())
            #expect(read.evidence == GearDropFrameEvidence(sourceTime: 10, stage: .unknown, bounds: Self.bounds,
                unreadableRows: 1))
            #expect(read.image === frame)
            #expect(reader.pendingGearSourceTime == nil)
            #expect(reader.takeGear() == nil)
            #expect(reader.snapshotMetrics().gearCompleted == 1)
        case .portal:
            #expect(reader.takePortal() == PortalScreenEvidence(sourceTime: 10,
                resonators: [8, 8], unreadSlots: 6, badgeHue: 259))
            #expect(reader.takePortal() == nil)
            #expect(reader.snapshotMetrics().portalCompleted == 1)
        }
    }

    @Test("Phase invalidation does not bypass the existing result-context or gear-generation checks",
          arguments: PhasePanelMode.allCases)
    func preservesPanelRejection(_ mode: PhasePanelMode) async throws {
        let probe = PhasePanelProbe(mode: mode, invalidateOwner: true)
        let reader = panelReader(probe)
        probe.install(reader)
        let context = ResultReadContext(sessionID: session, hackID: 9, glyphs: [nil, "xm"])
        submitPanel(reader, mode: mode, frame: try image(), context: context)
        try await waitForIdle(reader)
        #expect(reader.snapshotMetrics().staleCompletions == 1)
        #expect(reader.snapshotMetrics().completed == 0)
        #expect(reader.takeResult() == nil)
        #expect(reader.takeGear() == nil)
        #expect(reader.takePortal() == nil)
        #expect(reader.pendingGearSourceTime == nil)
    }

    private static let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)

    private func panelReader(_ probe: PhasePanelProbe) -> GameHeaderReader {
        GameHeaderReader(resultOperation: { image, context, time in
            try probe.invalidateDuringOperation(image, context: context, at: time)
            return ResultFrameEvidence(context: context, sourceTime: time, panelPresent: true,
                                       appearances: [.unreadable])
        }, gearOperation: { image, bounds, time in
            try probe.invalidateDuringOperation(image, at: time)
            return GearDropFrameEvidence(sourceTime: time, stage: .unknown, bounds: bounds, unreadableRows: 1)
        }, portalOperation: { image, time in
            try probe.invalidateDuringOperation(image, at: time)
            return PortalScreenEvidence(sourceTime: time, resonators: [8, 8], unreadSlots: 6, badgeHue: 259)
        })
    }

    private func submitPanel(_ reader: GameHeaderReader, mode: PhasePanelMode, frame: CGImage,
                             context: ResultReadContext, at time: Double = 10) {
        reader.submit(frame, at: time, session: session, resultContext: mode == .result ? context : nil,
                      panelCandidate: mode == .result, keepResultImage: true,
                      gearBounds: mode == .gear ? Self.bounds : nil, portalCandidate: mode == .portal)
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try #require(context.makeImage())
    }

    private func commandCapture(at time: Double) throws -> CommandNoticeCapture {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 50, y: 30, width: 100, height: 40))
        let capture = CommandNoticeCapture()
        try capture.observe(band: #require(context.makeImage()), at: time)
        try #require(capture.queue.count == 1)
        return capture
    }

    private func waitForIdle(_ reader: GameHeaderReader) async throws {
        // Barriers control operation ordering; this only waits for finish() to
        // publish under the reader's lock, after the continuation is released.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isReading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(!reader.isReading, "OCR completion did not release its lane")
    }
}

enum PhaseClockJump: String, CaseIterable, Sendable {
    case backward, forward
    var oldTime: Double { self == .backward ? 100 : 1 }
    var newTime: Double { self == .backward ? 1 : 100 }
}

enum PhasePayloadClock: String, CaseIterable, Sendable {
    case past, future, adjacent, nan, positiveInfinity, negativeInfinity
    var time: Double {
        switch self {
        case .past: 0
        case .future: 100
        case .adjacent: Double(1).nextUp
        case .nan: .nan
        case .positiveInfinity: .infinity
        case .negativeInfinity: -.infinity
        }
    }
}

enum PhasePanelMode: String, CaseIterable, Sendable { case result, gear, portal }

/// Suspension, not a blocking semaphore: safe even on a single cooperative executor.
private actor PhaseHeaderBarrier {
    private(set) var sourceTimes: [Double] = []
    private var pending: CheckedContinuation<HeaderReading, Never>?
    private var startWaiter: (Int, CheckedContinuation<Void, Never>)?

    func read(at time: Double) async -> HeaderReading {
        await withCheckedContinuation { continuation in
            precondition(pending == nil, "A second OCR request entered the occupied lane")
            pending = continuation
            sourceTimes.append(time)
            if let (count, waiter) = startWaiter, sourceTimes.count >= count {
                startWaiter = nil
                waiter.resume()
            }
        }
    }

    func waitForStart(_ count: Int) async {
        if sourceTimes.count >= count { return }
        await withCheckedContinuation { startWaiter = (count, $0) }
    }

    func release(sourceTime: Double, phase: GamePhase = .input) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: HeaderReading(phase: phase, matchedText: phase == .unknown ? "" : "GO!",
                                                      confidence: phase == .unknown ? 0 : 1, sourceTime: sourceTime))
    }
}

/// Panel operations are synchronous. Invoke the invalidation synchronously from
/// inside the operation itself, before its completion can publish, rather than
/// blocking a thread or racing a sleep. The weak reader reference is lock-owned.
private final class PhasePanelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var reader: GameHeaderReader?
    private let mode: PhasePanelMode
    private let invalidateOwner: Bool

    init(mode: PhasePanelMode, invalidateOwner: Bool) {
        self.mode = mode; self.invalidateOwner = invalidateOwner
    }

    func install(_ reader: GameHeaderReader) {
        lock.lock(); defer { lock.unlock() }
        self.reader = reader
    }

    func invalidateDuringOperation(_ image: CGImage, context: ResultReadContext? = nil, at time: Double) throws {
        lock.lock()
        let owner = reader
        lock.unlock()
        let reader = try #require(owner)
        #expect(reader.isReading)
        reader.invalidatePhase()
        reader.invalidatePhase()
        #expect(reader.isReading)
        if mode == .gear { #expect(reader.pendingGearSourceTime == time) }
        // Do not resubmit the original result context here: doing so could
        // accidentally repair an activeContext erased by invalidatePhase().
        if mode == .result && !invalidateOwner { return }
        let session = context?.sessionID ?? CaptureSessionID(rawValue: 71)
        let nextContext = invalidateOwner && mode == .result
            ? ResultReadContext(sessionID: session, hackID: 10, glyphs: ["old"]) : context
        if invalidateOwner && mode != .result { reader.invalidateGear() }
        // This rejected submission must not replace the in-flight owner. For
        // result mode only, its active context still changes exactly as before.
        reader.submit(image, at: time + 0.25, session: session, resultContext: nextContext)
        #expect(reader.snapshotMetrics().submitted == 1)
        #expect(reader.snapshotMetrics().droppedBusy == 1)
        #expect(reader.isReading)
    }
}
