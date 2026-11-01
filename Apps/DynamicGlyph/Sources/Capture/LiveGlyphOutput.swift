import Foundation
import CoreImage
import CoreMedia
import ImageIO
import GlyphRecognition
import GlyphRecognitionImages

/// One analyzed sample, for the displays and, while logs are kept, for the
/// Diagnostics page.
struct LiveGlyphUpdate: Sendable {
    let snapshot: GlyphDisplaySnapshot
    /// Nil unless session logs are kept: without them none of it is gathered.
    let diagnostics: RecognitionDiagnostics?
}

/// What the Diagnostics page shows. The sequence display reads the snapshot,
/// never these.
struct RecognitionDiagnostics: Sendable {
    let samples: Int
    let elapsed: Double
    let state: String
    let names: [String]
    let extensions: Int
    let calibration: String
    let milliseconds: Double
    let snapshotCount: Int
    let changed: Bool
    let error: String?
    let phase: String
    let slotSummary: String
    let headerSummary: String
    let counters: CaptureCounters
    let lastFacts: FrameFacts
}

/// What the presentation tracker did on one analyzed frame, for the
/// recording benchmark: only frames whose evidence produced tracking events.
struct LiveGlyphTrace: Sendable {
    /// The frame's presentation time.
    let time: Double
    let events: [TrackingEvent]
    let state: TrackingState
    let phaseSource: PhaseSource
    /// Source time of the frame whose header established the current phase.
    let phaseTime: Double?
    let hackID: Int
    let slots: [SlotObservation]
}

/// One captured frame's row for the session log's `frames.csv`.
struct FrameTelemetry: @unchecked Sendable {
    // Unchecked for the sample buffer, which is handed on once and not
    // touched again here.
    let buffer: CMSampleBuffer?
    let facts: FrameFacts
    let index: Int
    let hashChanged: Bool
}

/// Recognition for frames from any capture source.
///
/// All mutable state and file I/O belong to the capture source's serial
/// queue. The UI receives small value snapshots; no pixels cross to MainActor.
// Sendability relies on queue confinement: after init, process(_:) and close()
// must run on the same serial queue. The one exception is the header reader,
// which locks its own state.
final class LiveGlyphOutput: @unchecked Sendable {
    /// Nil without Glyph assistance: then only item panels are looked for.
    private var session: GlyphFrameSession?
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// The Power section's counters: measurement only, kept whether or not
    /// logs are, so they show the cost of a session without them. The
    /// recording benchmark passes its own.
    private let meter: PowerMeter
    /// The floating window's debug fill, told only when the gate's pace
    /// changes it. Nil in the benchmark and tests.
    private let readingMode: ReadingModeSignal?
    private var publishedTint = ReadingModeTint.none
    /// The recording benchmark's view of the tracker; nil in capture.
    private let trace: (@Sendable (LiveGlyphTrace) -> Void)?
    /// Whether this session keeps logs. Without them only the work the
    /// displays need is done: nothing is written, hashed, counted or described.
    private let keepsDiagnostics: Bool
    /// All three are nil when the player has not asked for session logs.
    private let file: FileHandle?
    private let trackingFile: FileHandle?
    private let snapshotWriter: GlyphSnapshotWriter?
    /// The session log's per-frame row, called only while logs are kept. The
    /// buffer is handed over only when a JPEG is actually wanted. Passing it
    /// every frame meant every captured surface was retained across a hop to
    /// MainActor, for work that runs once every five seconds.
    private let telemetry: @Sendable (FrameTelemetry) -> Void
    private let deliver: @Sendable (LiveGlyphUpdate) -> Void
    /// Separate from `deliver`: a result carries its own hack identity and must
    /// still arrive when Stop has already retired the session's display.
    private let deliverResult: @Sendable (HackResultSummary) -> Void
    /// Off means no conclusion is observed at all, so no result OCR runs.
    private let readsResults: Bool
    /// A tester feature: on only while session logs are kept, so every
    /// reading lands in the report. Off means no drop panel is looked for.
    /// Gear drops are read this session. Logs and panel pictures need the
    /// session folder; reading itself doesn't.
    let readsGear: Bool
    /// Off when capture only reads gear: no shape list, no phase, no result.
    let assistsGlyphs: Bool
    private let deliverGear: @Sendable (HackGearAttachment) -> Void
    /// Groups no Glyph hack claimed, with at least one row read.
    private let deliverDrop: @Sendable (GearDrop) -> Void
    private let gearFile: FileHandle?
    private let gearWriter: GearEvidenceWriter?
    private var gearTracker = GearDropTracker()
    private var gearSession = GearDropObservationSession()
    private var gearDisplay: GearDropDisplayTracker
    private var loggedGearEvents = 0
    private var gearEvidenceSchedule = GearEvidenceSchedule()
    private var gearGroupOpen = false
    /// Item-panel reads in a row that found the panel geometry was no panel
    /// (`nonPanel`), up to `gearRejectionsBeforeIdle`; an accepted read clears
    /// it. Unlike the text schedule's own count, a frame without the geometry
    /// does not clear it: a false candidate that flickers must not win back
    /// the full pace each time it reappears. Seconds without it do (see
    /// `gearRejectionsForgetAfter`).
    private var gearRejections = 0
    /// As many as the text schedule's back-off takes. Past it, panel geometry
    /// alone stops keeping the full pace; its reads go on at the schedule's
    /// cadence, and a read that finds a panel restores the pace at once.
    static let gearRejectionsBeforeIdle = 3
    /// The count also starts over on a new hack, on lost continuity, and
    /// once analysed frames have shown no panel geometry for this long: a
    /// panel coming back later is a new one, read at the full pace again.
    static let gearRejectionsForgetAfter = 3.0
    /// The last analysed frame with panel geometry.
    private var lastGearBoundsTime = -Double.infinity
    /// The session folder's name, for pictures a hack card can open later.
    private let folderName: String?
    private var gearPictures: [HackGearPicture] = []
    /// Set when the source reported lost continuity or an interruption since
    /// the last analyzed frame. Whether a pause in callbacks is a stall or a
    /// still screen is the source's call, made in `CapturedFrame`.
    private var gearContinuityBroken = false
    /// The portal screen before each hack, for its level. Kept with gear
    /// reading: it is a tester feature that logs what it read.
    private var portalObserver = PortalLevelObserver()
    private var portalScreens: [Int: PortalScreenEvidence] = [:]
    private var glyphCounts: [Int: Int] = [:]
    /// Carried over idle frames, which show an unchanged screen.
    private var lastInputVisible = false
    private var lastGameProgressVisible = false
    /// Empty unless this session records the screen: for a bug report, for
    /// Photos, or both. Each encodes its own copy of the same frames.
    private let recorders: [DebugScreenRecorder]

    private let sessionID: CaptureSessionID
    private let layout = GameUILayout()
    private let slotReader: SlotStripReader
    private let headerReader: GameHeaderReader
    private let commands = CommandNoticeCapture()
    private var commandScreen = CommandScreenWatch()
    private let commandFile: FileHandle?
    private let commandWriter: CommandEvidenceWriter?
    private let predictor: SequencePredictor?
    private var tracker: PresentationTracker
    private var inputValidator: PlayerInputValidator?
    private let inputFile: FileHandle?
    private let resultFile: FileHandle?
    private let resultWriter: ResultEvidenceWriter?
    private var resultSession = ResultObservationSession()
    private var resultEvidenceSchedule = ResultEvidenceSchedule()
    private var loggedResultRevision = -1
    private var previousResultRead: GameHeaderReader.ResultRead?

    private var lastSample = -Double.infinity
    /// The last frame due at the full rate, analyzed or not.
    private var lastLooked = -Double.infinity
    /// How often frames are analyzed and whether they get the full pipeline,
    /// from a luma gate read before any conversion. See `AnalysisRateController`.
    private var pace = AnalysisRateController()
    private let gate = LumaGate()
    /// The previous frame's presentation time, repeated or not.
    private var lastPresentation = -Double.infinity
    /// The last frame with a new presentation time, and when it arrived on
    /// the uptime clock: a still screen's looks extrapolate the frames' clock
    /// from it.
    private var clockAnchor: (time: Double, uptime: Double)?
    /// When the last frame of any kind arrived, on the uptime clock.
    private var lastArrival = -Double.infinity
    /// The gate's last look, at a frame or at a still screen, in frame time.
    private var lastPaceLook = -Double.infinity
    /// A still screen is looked at about four times a second at most: enough
    /// for the pace to settle and for the Power section's time split, while
    /// costing nothing but the look. A broadcast's link asks every 250 ms,
    /// with timer jitter, hence a little less than that.
    static let stillLookInterval = 0.2
    private let power: PowerConditions
    /// Phase 1 power saving: the luma gate and quiet pace, the header cadence
    /// between hacks, the command band cut after the throttle, Low Power Mode
    /// and thermal back-off, and (in the broadcast link) newest-frame-only
    /// delivery. Off reproduces the pipeline as it was before, for comparison.
    let powerSaving: Bool
    /// Constrained by Low Power Mode or heat, and power saving allowed to act on it.
    private var constrained: Bool { powerSaving && power.isConstrained }
    /// The last analysed frame showed gear panel geometry that counts as
    /// activity (not a rejected candidate).
    private var gearPanelShown = false
    /// A drop group is open and its current panel has rows unconfirmed: a
    /// gear read in flight may be the one that confirms them, so a new panel
    /// doesn't stop it (`GameTextSchedule.observeGearPanel`).
    private var gearPanelUnconfirmed: Bool { gearTracker.isObserving && !gearTracker.currentPanelSettled }
    /// Whether the analysis pace is halved: constrained, except while a gear
    /// panel shows. A new panel replaces the last one in place and can last
    /// 0.45 s; at 10 Hz its first read and each read's completion waited up
    /// to 0.1 s for an analysed frame, and its rows need two reads. Lane and
    /// header spacings still follow `constrained`.
    private var analysisConstrained: Bool { constrained && !gearPanelShown }
    /// The last analyzed frame showed positive evidence of a hack screen (the
    /// node array calibrated, the slot strip, the input countdown, a command
    /// notice) or a result, item or portal panel: analysis keeps its full
    /// pace. A dark or changing screen alone is none of these.
    private var sawActivity = false
    /// A node fit counts as evidence only this soon after it last matched all
    /// 11 rings: the session keeps a fit for eight seconds after that, which
    /// used to hold 20 Hz through every result screen and gear panel.
    static let freshFitWindow = 1.0
    /// Idle-only clock changes can bypass GlyphFrameSession.observe's reset.
    /// Cached geometry may still be used, but only a genuine new ring match
    /// can make it activity evidence on the new source-clock epoch.
    private var fitFreshnessIsCurrentEpoch = true
    /// Whether the hack's command phase is still current, from header readings
    /// and notice boxes: it lets the cached fit keep the command watch while
    /// strokes cover the array, and never once the phase has ended.
    private var commandContext = CommandPhaseContext()
    /// Diagnostic decomposition of that same last-frame activity. No pixels,
    /// strings or per-look collections; this never changes the pace policy.
    private var activityReasons = AnalysisGateReasons()
    private var lumaReasons = AnalysisGateReasons()
    private var lastTelemetryImage = -Double.infinity
    private var counters = CaptureCounters()
    private var lastFacts = FrameFacts()
    private var snapshotSchedule = SnapshotSchedule()
    private var firstTime: Double?
    private var previousKey = ""
    private var samples = 0
    private var closed = false
    private var writeError: String?

    private var cachedOutlook = SequenceOutlook.unavailable
    private var cachedOutlookKey = ""
    private var trackingEvents = 0

    /// A nil `table` reads gear only, whatever `readsResults` and `readsGear` say.
    init(table: GlyphTable?, sequenceTable: SequenceTable?, sessionID: CaptureSessionID,
         directory: URL?, recorders: [DebugScreenRecorder] = [], readsResults: Bool,
         readsGear: Bool = false, savesGearPictures: Bool = true,
         languages: GameLanguageMemory = GameLanguageMemory(language: .english, isAutomatic: false),
         power: PowerConditions = .shared, powerSaving: Bool = true,
         meter: PowerMeter = .shared, readingMode: ReadingModeSignal? = nil,
         // Test seam only: nil preserves the shipped header OCR operation and scheduling.
         headerOperation: GameHeaderReader.HeaderOperation? = nil,
         trace: (@Sendable (LiveGlyphTrace) -> Void)? = nil,
         telemetry: @escaping @Sendable (FrameTelemetry) -> Void,
         deliverResult: @escaping @Sendable (HackResultSummary) -> Void,
         deliverGear: @escaping @Sendable (HackGearAttachment) -> Void = { _ in },
         deliverDrop: @escaping @Sendable (GearDrop) -> Void = { _ in },
         deliver: @escaping @Sendable (LiveGlyphUpdate) -> Void) throws {
        assistsGlyphs = table != nil
        session = table.map(GlyphFrameSession.init(table:))
        self.power = power
        self.powerSaving = powerSaving
        self.meter = meter
        self.readingMode = readingMode
        // A new session starts on the window's own background.
        readingMode?.publish(.none)
        self.trace = trace
        headerReader = GameHeaderReader(configuration: .init(
            skipsUnchangedHeaders: powerSaving, languages: languages,
            allowsGearRetries: { !(powerSaving && power.isConstrained) }),
            headerOperation: headerOperation, meter: meter)
        predictor = table == nil ? nil : sequenceTable.map(SequencePredictor.init(table:))
        self.sessionID = sessionID
        tracker = PresentationTracker(sessionID: sessionID)
        inputValidator = table.map { PlayerInputValidator(table: $0, sessionID: sessionID) }
        commandWriter = directory.map(CommandEvidenceWriter.init(directory:))
        commandFile = try directory.map { try Self.makeFile($0.appendingPathComponent("commands.jsonl")) }
        inputFile = try directory.map { try Self.makeFile($0.appendingPathComponent("input-validation.jsonl")) }
        resultFile = try directory.map { try Self.makeFile($0.appendingPathComponent("results.jsonl")) }
        resultWriter = try directory.map(ResultEvidenceWriter.init(directory:))
        slotReader = SlotStripReader(layout: layout)
        self.recorders = recorders
        self.deliver = deliver
        self.deliverResult = deliverResult
        // A result belongs to a Glyph hack, so gear-only capture reads none.
        self.readsResults = readsResults && assistsGlyphs
        // With Glyph hacks, gear depends on the result reader for each hack's
        // bonus. Without a session folder it is still read and shown, just
        // not logged.
        let gear = !assistsGlyphs || (readsGear && readsResults)
        self.readsGear = gear
        self.deliverGear = deliverGear
        self.deliverDrop = deliverDrop
        gearDisplay = GearDropDisplayTracker(standalone: !assistsGlyphs)
        gearFile = try directory.flatMap { gear ? try Self.makeFile($0.appendingPathComponent("gear-drops.jsonl")) : nil }
        gearWriter = directory.flatMap { gear && savesGearPictures ? GearEvidenceWriter(directory: $0) : nil }
        folderName = directory?.lastPathComponent
        self.telemetry = telemetry
        keepsDiagnostics = directory != nil
        snapshotWriter = try directory.map(GlyphSnapshotWriter.init(directory:))
        file = try directory.map { try Self.makeFile($0.appendingPathComponent("recognition.jsonl")) }
        trackingFile = try directory.map { try Self.makeFile($0.appendingPathComponent("tracking.jsonl")) }
    }

    private static func makeFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    /// A text read is still running. Tests wait on this rather than on how
    /// long a read takes, which varies with the machine's load.
    var isReadingText: Bool { headerReader.isReading }
    /// The OCR lane's counts, for tests and diagnostics.
    var textReadMetrics: GameHeaderReader.Metrics { headerReader.snapshotMetrics() }

    func close() {
        guard !closed else { return }
        closed = true
        // Asked for first so that finalizing the movie overlaps draining the
        // outstanding PNG writes instead of queueing behind them.
        for recorder in recorders { recorder.requestFinish(.sessionStopped) }
        consumeResult()
        headerReader.invalidate()
        snapshotWriter?.finish()
        for recorder in recorders { recorder.waitForFinish() }
        recordInput(inputValidator?.finish(at: tracker.lastEvidenceTime ?? 0) ?? [])
        resultSession.finish(at: tracker.lastEvidenceTime ?? 0, reason: "captureStopped")
        logResult()
        resultWriter?.finish()
        if readsGear {
            consumeGear()
            let end = tracker.lastEvidenceTime ?? 0
            if let group = gearTracker.finish(at: end, reason: "captureStopped") { closeGear(group) }
            gearSession.invalidate(at: end, reason: "captureStopped")
            drainGearEvents()
            gearWriter?.finish()
            try? gearFile?.synchronize()
            try? gearFile?.close()
        }
        previousResultRead = nil
        commandWriter?.finish()
        try? commandFile?.synchronize()
        try? commandFile?.close()
        try? resultFile?.synchronize()
        try? resultFile?.close()
        try? inputFile?.synchronize()
        try? inputFile?.close()
        try? file?.synchronize()
        try? file?.close()
        try? trackingFile?.synchronize()
        try? trackingFile?.close()
    }

    /// A hack, or one whose header went unreadable a moment ago.
    private func isInHack(at time: Double) -> Bool {
        let phaseAge = time - (tracker.lastPhaseTime ?? -.infinity)
        return tracker.state == .presenting || tracker.state == .input || tracker.state == .command
            || commandScreen.watching
            || tracker.state == .interrupted && phaseAge.isFinite && phaseAge >= 0 && phaseAge < 5
    }

    /// A reader is following something: the pace never slows then.
    private var paceBusy: Bool {
        // A result context is ownership, not current screen activity. It may
        // stay uncertain indefinitely behind an overlay; do not close it just
        // to save power, nor let it alone pin analysis at 20 Hz. Fresh result
        // geometry, slots/timer and the existing hack grace still keep pace.
        sawActivity || gearGroupOpen || gearTracker.isObserving
    }

    /// Every look of the gate, at a frame or at a still screen.
    private func notePace(_ decision: AnalysisRateController.Decision, inHack: Bool, at time: Double,
                          gate: LumaGateReading? = nil, still: Bool = false) {
        // Raw inputs, including retained context and each busy/hack signal.
        // Candidate inputs can settle and overlap: they are not sole causes.
        var reasons = activityReasons
        if powerSaving {
            if let gate {
                lumaReasons = []
                lumaReasons.set(.darkCandidate, gate.darkFraction >= LumaGate.minimumDarkFraction)
                lumaReasons.set(.dimCandidate, gate.brightFraction <= LumaGate.maximumBrightFraction)
            }
            reasons.formUnion(lumaReasons)
            reasons.set(.noPixels, gate == nil && !still)
            reasons.set(.candidateEntry, pace.enteredCandidate)
            reasons.set(.screenSwitch, pace.switchedScreen)
            reasons.set(.resultContext, resultSession.context != nil)
            reasons.set(.gearGroup, gearGroupOpen)
            reasons.set(.gearObserver, gearTracker.isObserving)
            reasons.set(.commandWatch, commandScreen.watching)
            reasons.set(.command, tracker.state == .command)
            reasons.set(.presenting, tracker.state == .presenting)
            reasons.set(.input, tracker.state == .input)
            reasons.set(.interrupted, tracker.state == .interrupted && inHack)
        } else {
            reasons = AnalysisGateReasons(.savingOff)
        }
        // The Power section's time split: frame looks and still-screen ticks.
        let current = ReadingMode(decision, powerSaving: powerSaving, inHack: inHack, policy: pace.policy)
        meter.noteAnalysisMode(decision.mode, at: time, current: current, reasons: reasons, still: still, gate: gate)
        // The floating window's debug fill, only when it changes.
        if let readingMode, current.tint != publishedTint {
            publishedTint = current.tint
            readingMode.publish(current.tint)
        }
    }

    /// The gate's look at a screen the source vouches is still, at `time` on
    /// the frames' clock: no frame is converted, read, analyzed or counted.
    private func lookAtStillScreen(at time: Double) {
        guard time - lastPaceLook >= Self.stillLookInterval else { return }
        lastPaceLook = time
        // Silence cannot prove that an interrupted hack ended. Keep the last
        // real frame's safety window until another real frame can reassess it.
        let inHack = isInHack(at: lastPresentation)
        notePace(pace.advanceStill(at: time, busy: paceBusy, inHack: inHack, constrained: analysisConstrained),
                 inHack: inHack, at: time, still: true)
    }

    /// For a source that delivers nothing while the screen is still, as a
    /// broadcast does: it calls this a few times a second, on the queue
    /// `process(_:)` runs on, while its stream is live. Once no frame has
    /// arrived for a 20-Hz interval, the gate looks at the still screen at
    /// the time the frames' clock has reached at `uptime`, so its pace
    /// settles as it would on unchanged frames. Without power saving, before
    /// the first frame and after close, it does nothing.
    func noteStillScreen(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard !closed, powerSaving, let clockAnchor,
              uptime - lastArrival >= pace.policy.activeInterval else { return }
        lookAtStillScreen(at: clockAnchor.time + (uptime - clockAnchor.uptime))
    }

    func process(_ frame: CapturedFrame) {
        guard !closed else { return }
        meter.count(.framesDelivered)
        // A frame that is not analysed is timed whole, on whichever return
        // it takes; an analysed one's handling up to its analysis is intake.
        let intakeStarted = meter.now()
        var analysed = false
        defer { if !analysed { meter.finish(.skippedFrame, since: intakeStarted) } }
        let buffer = frame.sampleBuffer
        // Arrival is when the source received the frame; a broadcast's frames
        // then wait in the transport and the queue before they get here.
        let arrived = frame.arrivalUptime
        let started = ProcessInfo.processInfo.systemUptime
        let callbackGapMilliseconds = frame.deliveryGapMilliseconds
        if frame.continuityBroken { gearContinuityBroken = true }
        let facts = FrameFacts(metadata: frame.metadata, sampleBuffer: buffer, hashing: keepsDiagnostics)
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if keepsDiagnostics {
            let frameIndex = counters.frames
            let hashChanged = counters.count(facts.status, hash: facts.hash)
            lastFacts = facts
            // One evidence JPEG every five seconds. Deciding that here, on the
            // recognition queue, is what lets every other frame's row cross to
            // MainActor without the pixels attached.
            var wantsImage = false
            if facts.status == .complete, time.isFinite,
               time < lastTelemetryImage || time - lastTelemetryImage >= 5 {
                lastTelemetryImage = time
                wantsImage = true
            }
            telemetry(FrameTelemetry(buffer: wantsImage ? buffer : nil, facts: facts,
                                     index: frameIndex, hashChanged: hashChanged))
        }
        guard time.isFinite else { return }
        let repeated = time == lastPresentation
        let sourceGap = time - lastPresentation
        let arrivalGap = max(0, arrived - (clockAnchor?.uptime ?? lastArrival))
        // A source-clock jump is not an ordinary still-screen delivery gap:
        // elapsed arrival time explains the latter. Invalidate phase/command
        // ownership before any queued completion can be consumed.
        let clockEpochBroken = lastPresentation.isFinite && (
            time < lastPresentation
            || !repeated && facts.status == .complete && sourceGap > tracker.policy.maximumFrameGap
                && (frame.continuityBroken || sourceGap - arrivalGap > tracker.policy.maximumFrameGap))
        if clockEpochBroken {
            headerReader.invalidatePhase()
            tracker.invalidatePhase()
            commands.invalidateQueue(at: time)
            commandScreen.reset()
            commandContext.reset()
            fitFreshnessIsCurrentEpoch = false
            sawActivity = false
            activityReasons = []
        }
        var currentNotice = false
        lastPresentation = time
        lastArrival = arrived
        if !repeated { clockAnchor = (time, arrived) }
        // A gap in the frames may hide a notice: uncertain, not "no command".
        // Checked on every delivered frame, so a throttled one still counts.
        if readsResults, frame.continuityBroken || (facts.status != .complete && facts.status != .idle)
            || facts.width >= facts.height || (facts.orientation != nil && facts.orientation != 1) {
            commands.interrupt(at: time); commandScreen.stop()
        }
        // Without power saving, as before: command notices can last a single
        // 20-Hz sample, so their small band is inspected on every delivered
        // frame, before throttling full Glyph analysis.
        if readsResults, !powerSaving {
            consumeCommand()
            if commandScreen.watching, facts.status == .complete,
               let pixels = CMSampleBufferGetImageBuffer(buffer) {
                let bandStarted = meter.now()
                defer { meter.finish(.commandBand, since: bandStarted) }
                let input = CIImage(cvPixelBuffer: pixels)
                let band = CommandNoticeDetector.band(width: facts.width, height: facts.height)
                // Core Image uses a bottom-left origin; detector bands use top-left.
                let rect = CGRect(x: band.minX, y: input.extent.height - band.maxY,
                                  width: band.width, height: band.height)
                if let crop = context.createCGImage(input, from: rect) {
                    do {
                        try commands.observe(band: crop, at: time)
                        currentNotice = commands.showsNotice
                    } catch { /* No current evidence from a failed crop/read. */ }
                }
            }
        }
        // ScreenCaptureKit's idle frames on a still screen repeat the last
        // timestamp, which the 20-Hz throttle below would drop: the gate is told
        // the screen is still instead, at the time the frames' clock has
        // reached by now. Nothing is analyzed or recorded, as before.
        if repeated, facts.status == .idle, powerSaving {
            if let clockAnchor { lookAtStillScreen(at: clockAnchor.time + max(0, arrived - clockAnchor.uptime)) }
            return
        }
        // Timestamp throttling drops frames before conversion and recognition.
        // 20 Hz, less a millisecond of timestamp jitter. 10 Hz kept every slot
        // while the strip was readable, but the blank between two Glyphs lasts
        // about 100 ms, so at 10 Hz it is one sample: with the strip covered,
        // the fallback then merges a whole hack into one uncertain slot.
        guard time < lastLooked || time - lastLooked >= pace.policy.activeInterval else { return }
        lastLooked = time
        lastPaceLook = time
        // Only frames due at the full rate reach the gate, which then decides
        // whether this one is analyzed at all and how fully.
        let inHack = isInHack(at: time)
        let decision: AnalysisRateController.Decision
        var gateReading: LumaGateReading?
        if !powerSaving {
            decision = AnalysisRateController.Decision(mode: .active, interval: pace.policy.activeInterval)
        } else if facts.status == .idle {
            // An idle frame says the screen did not change: it settles the
            // pace like an unchanged frame, though it has no pixels to read.
            decision = pace.advanceStill(at: time, busy: paceBusy, inHack: inHack, constrained: analysisConstrained)
        } else {
            gateReading = facts.status == .complete ? CMSampleBufferGetImageBuffer(buffer).flatMap(gate.read) : nil
            decision = pace.decide(at: time, gate: gateReading, busy: paceBusy, inHack: inHack,
                                   constrained: analysisConstrained)
        }
        notePace(decision, inHack: inHack, at: time, gate: gateReading, still: facts.status == .idle)
        guard time < lastSample || time - lastSample >= decision.interval else {
            // Still recorded at 20 Hz: a bug report shows what the player saw.
            for recorder in recorders { recorder.offer(buffer, at: time, status: facts.status) }
            return
        }
        lastSample = time
        meter.count(.framesAnalysed)
        meter.noteAnalysisSample(decision.mode)
        let analysisStarted = meter.now()
        analysed = true
        meter.record(.frameIntake, nanoseconds: analysisStarted &- intakeStarted)
        defer { meter.finish(.frameWork, since: analysisStarted) }
        let quiet = decision.mode == .quiet
        // Fed after the 20-Hz throttle, also for frames a quiet or constrained
        // pace leaves unanalyzed; pressure drops are counted in recording.json.
        let offerStarted = ProcessInfo.processInfo.systemUptime
        for recorder in recorders { recorder.offer(buffer, at: time, status: facts.status) }
        let recordingOfferMilliseconds = (ProcessInfo.processInfo.systemUptime - offerStarted) * 1000
        if !recorders.isEmpty { meter.record(.recordingOffer, nanoseconds: UInt64(max(0, recordingOfferMilliseconds) * 1e6)) }
        if firstTime == nil { firstTime = time }
        let elapsed = time - firstTime!

        var panelCandidate = false
        var gearBounds: GearDropPanelBounds?
        var portalCandidate = false
        var observation: GlyphFrameObservation?
        var image: CGImage?
        var state = "waitingForEmptyArray"
        var error: String?
        if facts.status != .complete {
            // Idle means no new image; it does not establish a Glyph boundary.
            // Other stream interruptions invalidate geometric continuity.
            if facts.status != .idle { session?.reset(); gearContinuityBroken = true }
            state = "capture_\(facts.status.rawValue)"
        } else if facts.width >= facts.height || (facts.orientation != nil && facts.orientation != 1) {
            session?.reset()
            state = "unsupportedOrientation"
        } else if let pixels = CMSampleBufferGetImageBuffer(buffer) {
            do {
                let conversionStarted = meter.now()
                let input = CIImage(cvPixelBuffer: pixels)
                let converted = context.createCGImage(input, from: input.extent)
                meter.finish(.conversion, since: conversionStarted)
                guard let cgImage = converted else {
                    throw CocoaError(.coderReadCorrupt)
                }
                image = cgImage
                // A failed panel check is no reason to lose the frame for Glyphs.
                if readsGear {
                    let gearStarted = meter.now()
                    gearBounds = try? GearDropScreenReader().bounds(in: cgImage)
                    meter.finish(.gearCheck, since: gearStarted)
                }
                // A portal's level is matched to the Glyph hack that follows,
                // when gear is read. With power saving the portal screen,
                // which comes before every hack, also keeps the full pace, so
                // the hack's empty array is fitted before its first Glyph.
                if assistsGlyphs, readsGear || powerSaving {
                    let portalStarted = meter.now()
                    portalCandidate = (try? PortalScreenReader().isCandidate(cgImage)) == true
                    meter.finish(.portalCheck, since: portalStarted)
                }
                if assistsGlyphs {
                    let decodeStarted = meter.now()
                    let luminance = try ImageDecoder.decode(cgImage)
                    meter.finish(.decode, since: decodeStarted)
                    let panelStarted = meter.now()
                    panelCandidate = ResultPanelDetector().isCandidate(luminance)
                    meter.finish(.resultCheck, since: panelStarted)
                    // A quiet screen shows no array: the search for one is skipped.
                    if !quiet, session != nil {
                        let glyphStarted = meter.now()
                        observation = session?.observe(luminance, at: time)
                        // The session times its own hunt for the node array;
                        // the rest of `observe` is reading the Glyph.
                        let total = meter.now() &- glyphStarted
                        let huntTime = session?.lastGridHuntNanoseconds
                        if huntTime != nil, session?.validatedAt == time,
                           observation?.state == .noStroke, observation?.calibration != nil {
                            fitFreshnessIsCurrentEpoch = true
                        }
                        let hunt = min(huntTime ?? 0, total)
                        if huntTime != nil { meter.record(.gridHunt, nanoseconds: hunt) }
                        meter.record(.glyphRead, nanoseconds: total - hunt)
                    }
                    state = quiet ? "quietScreen" : observation?.state.rawValue ?? "waitingForEmptyArray"
                } else {
                    state = "gearOnly"
                }
            } catch let failure {
                session?.reset()
                state = "conversionFailed"
                error = String(describing: failure)
            }
        } else {
            session?.reset()
            state = "missingPixels"
        }
        samples += 1
        // Panel geometry keeps the pace until its reads have kept finding no
        // panel; an open group or a read panel keeps it regardless (`paceBusy`).
        if gearBounds != nil {
            lastGearBoundsTime = time
        } else if image != nil, time < lastGearBoundsTime || time - lastGearBoundsTime > Self.gearRejectionsForgetAfter {
            gearRejections = 0
        }
        let gearRejected = gearBounds != nil && gearRejections >= Self.gearRejectionsBeforeIdle
        let gearActivity = gearBounds != nil && !gearRejected
        // An idle frame repeats the screen the last analysed one showed, so it
        // keeps that frame's activity: it has no pixels to find any in.
        let freshPixels = facts.status != .idle
        if freshPixels {
            gearPanelShown = gearActivity
            sawActivity = gearActivity || portalCandidate || (readsResults && panelCandidate)
            activityReasons = []
            activityReasons.set(.gearPanel, gearActivity)
            activityReasons.set(.gearRejected, gearRejected)
            activityReasons.set(.portalPanel, portalCandidate)
            activityReasons.set(.resultPanel, readsResults && panelCandidate)
        }
        if readsResults, powerSaving {
            consumeCommand()
            // After the throttle, cut from the frame already converted rather
            // than rendered again: a notice lasts at least one 20-Hz sample.
            if commandScreen.watching, let image {
                let bandStarted = meter.now()
                defer { meter.finish(.commandBand, since: bandStarted) }
                if let crop = Self.copy(image, cropping: CommandNoticeDetector.band(width: facts.width,
                                                                                    height: facts.height)) {
                    do {
                        try commands.observe(band: crop, at: time)
                        currentNotice = commands.showsNotice
                    } catch { /* No current evidence from a failed crop/read. */ }
                    // A notice box on this frame is a command being entered.
                    if currentNotice {
                        sawActivity = true
                        activityReasons.set(.commandNotice, true)
                    }
                }
            }
        }

        // MARK: Phase and slot evidence
        // Invalidate ownership before any completed OCR can enter the tracker.
        let continuityLost = gearContinuityBroken
        gearContinuityBroken = false
        if readsGear, gearSession.prepareFrame(at: time, continuityLost: continuityLost) {
            headerReader.invalidateGear()
            portalObserver = PortalLevelObserver()
            gearRejections = 0
            if let closed = gearTracker.loseContinuity(at: time) { closeGear(closed) }
            lastInputVisible = false; lastGameProgressVisible = false
            drainGearEvents()
        }
        consumeResult()
        consumeGear()
        consumePortal()
        // A fit that overlaps the regions the layout describes means this is
        // not the screen those fractions were measured on. A cached fit counts
        // as a current hack cue only while recently matched on an empty array.
        let layoutConsistent = observation?.calibration.map(layout.isConsistent) ?? false
        let hasValidCalibration = observation?.calibration != nil && layoutConsistent
        let freshFit = fitFreshnessIsCurrentEpoch && hasValidCalibration
            && session?.validatedAt.map { time >= $0 && time - $0 <= Self.freshFitWindow } == true
        var band: FrameTopBand?
        var slots: SlotStripReading?
        var slotRejection: SlotStripRejection?
        var hasInputTimerBar = false
        var header: HeaderReading?
        if let image, facts.status == .complete, !assistsGlyphs {
            // Only a panel needs reading: no header, no slot row.
            if let gearBounds {
                headerReader.submit(image, at: time, session: sessionID, gearBounds: gearBounds, readsHeader: false,
                                    constrained: constrained, gearPanelSettled: gearTracker.currentPanelSettled,
                                    gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: false)
            } else {
                // The new-panel check needs the frames without a panel too.
                headerReader.observeGearPanel(nil, at: time)
            }
        } else if let image, facts.status == .complete {
            let slotStarted = meter.now()
            band = try? ImageDecoder.topBand(image, layout: layout)
            if let band {
                switch slotReader.read(band) {
                case .success(let reading): slots = reading
                case .failure(let rejection): slotRejection = rejection
                }
            }
            meter.finish(.slotStrip, since: slotStarted)
            hasInputTimerBar = band.map(slotReader.hasTimerBar) == true
            // Current evidence can precede the tracker entering a hack. Bypass
            // only content suppression, retaining the outside OCR cadence.
            let requiresFreshHeader = slots != nil || hasInputTimerBar || freshFit
            // Text recognition runs behind the sampler on its own schedule.
            // Between hacks the header only has to notice the next one.
            let headerInterval = powerSaving ? AnalysisRateController.headerInterval(
                mode: decision.mode, inHack: inHack, constrained: constrained) : nil
            headerReader.submit(image, at: time, session: sessionID,
                                resultContext: resultSession.context, panelCandidate: panelCandidate,
                                keepResultImage: keepsDiagnostics, gearBounds: gearBounds,
                                headerPriority: tracker.state == .presenting || tracker.state == .input,
                                portalCandidate: readsGear && portalCandidate,
                                // Commands come before presentation; the header
                                // has the lane to itself while a hack is shown.
                                commands: readsResults && tracker.state != .presenting && tracker.state != .input
                                    ? commands : nil,
                                readsHeader: !powerSaving || headerInterval != nil, headerInterval: headerInterval,
                                constrained: constrained, gearPanelSettled: gearTracker.currentPanelSettled,
                                gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: inHack,
                                requiresFreshHeader: requiresFreshHeader, topBand: band)
            header = headerReader.reading(for: time, session: sessionID)
        }

        let evidence = FrameEvidence(
            sessionID: sessionID, time: time,
            header: layoutConsistent || observation?.calibration == nil ? header : nil,
            slots: slots, slotRejection: slotRejection,
            shape: observation.map(ShapeEvidence.init) ?? .unavailable,
            hasValidCalibration: hasValidCalibration,
            hasInputTimerBar: hasInputTimerBar)
        // Hack signs that a slow look reads keep the next frames at the full
        // pace: the node array fitted where the layout expects it, the slot
        // strip, the input countdown. A resting look searches for the array;
        // a quiet one (no candidate, so no hack screen) does not.
        if freshPixels {
            if powerSaving, slots != nil || evidence.hasInputTimerBar || freshFit {
                sawActivity = true
            }
            activityReasons.set(.calibration, powerSaving && freshFit)
            activityReasons.set(.slots, powerSaving && slots != nil)
            activityReasons.set(.timer, powerSaving && evidence.hasInputTimerBar)
        }
        let events = tracker.accept(evidence)
        if events.contains(where: { $0.kind == .hackStarted }) { gearRejections = 0 }
        if let trace, !events.isEmpty {
            trace(LiveGlyphTrace(time: time, events: events, state: tracker.state, phaseSource: tracker.phaseSource,
                                 phaseTime: tracker.lastPhaseTime, hackID: tracker.hackID, slots: tracker.slots))
        }
        if readsResults {
            for event in events where event.kind == .hackStarted {
                commands.bind(hackID: event.hackID)
                commandWriter?.nextHack()
                logCommands(hackID: event.hackID, at: event.time, kind: "bound")
            }
            // Geometry remains available for recognition for eight seconds.
            // A fit from the last second arms the watch; an armed watch goes
            // on through a drawn command on a fresh header vote or a current
            // notice. The cached fit also arms or keeps it while the command
            // phase is current: header text is read only on some frames and
            // a read can finish after its 0.35-s freshness, so each reading
            // counts at its own source time, and a frame with no fresh one
            // does not end the phase. Readable header text of another phase,
            // or `leave` without command evidence, ends it, so the cache
            // cannot hold the watch after the hack. So does a reading that
            // recognised nothing, unless a notice of this window has been
            // read: while a command is drawn the header mostly reads that
            // way. Retained tracker phase and stale notice state never
            // qualify.
            if let latest = headerReader.latestReading(session: sessionID) {
                commandContext.header(latest)
            }
            // After any bind above: a bound or cancelled window has none.
            commandContext.noticeRead(at: commands.noticeReadAt)
            if currentNotice { commandContext.notice(at: time) }
            let supportedCommand = commandScreen.watching && (header?.phase == .command || currentNotice)
            let cachedCommandPhase = hasValidCalibration && commandContext.isCurrent(at: time)
            switch commandScreen.observe(at: time, calibrated: freshFit || supportedCommand || cachedCommandPhase,
                                         commandPhase: !evidence.hasInputTimerBar
                                            && tracker.state != .presenting && tracker.state != .input,
                                         complete: facts.status == .complete) {
            case .interrupt: commands.interrupt(at: time)
            case .cancel: commands.cancel(); commandContext.noticeRead(at: nil)
            case .none: break
            }
            if !evidence.hasValidCalibration, let image {
                let probeStarted = meter.now()
                // An item panel on screen, or its group still being read, is
                // no time for a drone check: see `observeMode`.
                _ = try? commands.observeMode(in: image, at: time,
                                              panelShowing: gearBounds != nil || gearTracker.isObserving)
                meter.finish(.footerProbe, since: probeStarted)
            }
        }
        if readsGear { notePortal(events) }
        let previousComparison = resultSession.comparison
        if readsResults,
           let retired = resultSession.observe(evidence, presentation: tracker, panelCandidate: panelCandidate,
                                               imageAnalyzed: image != nil,
                                               commands: readsResults ? commands.summary(hackID: tracker.hackID) : nil) {
            publishResult(retired, comparison: previousComparison)
            loggedResultRevision = -1
            previousResultRead = nil
        }
        // An idle frame is an unchanged screen, not lost geometry; passing it
        // on would end the player's attempt as if calibration had failed.
        if facts.status != .idle,
           let checks = inputValidator?.accept(evidence, tracker: tracker, edgeEvidence: observation?.evidence ?? []) {
            recordInput(checks)
        }
        if !events.isEmpty { record(events, elapsed: elapsed) }
        logResult()
        if readsGear { observeGear(at: time, evidence: evidence, slots: slots, analyzed: image != nil,
                                   gearBounds: gearBounds, resultPage: panelCandidate) }

        let snapshot = makeSnapshot(observation: observation, arrivalUptime: arrived, sourceTime: time)
        guard keepsDiagnostics else {
            deliver(LiveGlyphUpdate(snapshot: snapshot, diagnostics: nil))
            return
        }

        // MARK: Raw evidence, unchanged in shape from schema 2 plus tracking
        let names = observation?.exactMatches.map(\.name) ?? []
        let edges = observation?.edges.map { "\($0.lower.character)-\($0.upper.character)" }.sorted() ?? []
        let key = state + ":" + edges.joined(separator: ",") + ":" + names.joined(separator: ",")
        let changed = facts.status != .idle && key != previousKey
        if changed { previousKey = key }
        var snapshotName: String?
        // Retain eligibility after a throttled transition; otherwise a blank
        // can consume the allowance just before a short presentation starts.
        if let snapshotWriter, let image, observation != nil, snapshotSchedule.wantsSnapshot(key: key, at: time) {
            let name = String(format: "glyph-%05d.png", samples)
            if snapshotWriter.enqueue(image, name: name, sample: samples) {
                snapshotSchedule.didQueue(key: key, at: time)
                snapshotName = name
            }
        }
        let fit = observation?.calibration
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let headerMetrics = headerReader.snapshotMetrics()
        var row: [String: Any] = [
            "sample": samples, "presentationTime": time, "elapsed": elapsed,
            "schemaVersion": 4,
            "state": state, "completion": "unconfirmed",
            "phase": tracker.state.rawValue, "phaseSource": tracker.phaseSource.rawValue,
            "hackID": tracker.hackID, "revision": tracker.revision,
            "exactMatches": names, "edges": edges,
            "extensions": observation?.extensions.map(\.name) ?? [],
            "candidates": observation?.candidates.map { ["name": $0.id.name, "edgeDistance": $0.distance] as [String: Any] } ?? [],
            "strokePixels": observation?.strokePixelCount ?? 0,
            "unexplainedInkPixels": observation?.unexplainedInkPixelCount ?? 0,
            "width": facts.width, "height": facts.height, "pixelFormat": facts.pixelFormat,
            "captureStatus": facts.status.rawValue, "processingMilliseconds": milliseconds,
            "queueMilliseconds": max(0, (started - arrived) * 1000),
            "recordingOfferMilliseconds": recordingOfferMilliseconds,
            "inputTimerVisible": evidence.hasInputTimerBar,
            "headerSubmitted": headerMetrics.submitted - headerMetrics.resultSubmitted,
            "headerCompleted": headerMetrics.completed - headerMetrics.resultCompleted,
            "resultSubmitted": headerMetrics.resultSubmitted, "resultCompleted": headerMetrics.resultCompleted,
            "resultLatencyMilliseconds": headerMetrics.resultLatencyMilliseconds,
            "resultTotalLatencyMilliseconds": headerMetrics.resultTotalLatencyMilliseconds,
            "textDroppedBusy": headerMetrics.droppedBusy, "textStaleCompletions": headerMetrics.staleCompletions,
            "headerDroppedBusy": headerMetrics.droppedBusy,
            "headerLatencyMilliseconds": headerMetrics.lastLatencyMilliseconds,
            "analysisMode": decision.mode.rawValue, "powerConstrained": constrained, "powerSaving": powerSaving
        ]
        // Which trigger constrains it: Low Power Mode, heat, or both.
        for (key, value) in power.current.logRow { row[key] = value }
        if let callbackGapMilliseconds { row["callbackGapMilliseconds"] = callbackGapMilliseconds }
        if let slots {
            row["slotCount"] = slots.slotCount
            row["slotHighlight"] = slots.highlightedIndex ?? -1
            row["inputTimerBar"] = slots.hasInputTimerBar
            row["slotStripPartlyCovered"] = slots.isPartlyCovered
        }
        if let slotRejection { row["slotRejection"] = slotRejection.rawValue }
        if let header {
            row["headerPhase"] = header.phase.rawValue
            row["headerText"] = header.matchedText
            row["headerConfidence"] = header.confidence
            row["headerSourceTime"] = header.sourceTime
        }
        if let orientation = facts.orientation { row["orientation"] = orientation }
        if let fit {
            row["calibration"] = ["origin": [fit.origin.x, fit.origin.y], "size": [fit.size.x, fit.size.y],
                                  "matchedNodes": fit.matchedNodes.count, "rms": fit.rootMeanSquareError]
        }
        if let snapshotName {
            row["snapshot"] = snapshotName
            row["snapshotStatus"] = "queued"
        }
        if let error { row["error"] = error }
        if let failure = headerMetrics.lastError { row["headerError"] = failure }
        if let failure = headerMetrics.resultError { row["resultError"] = failure }
        append(row, to: file)

        deliver(LiveGlyphUpdate(snapshot: snapshot, diagnostics: RecognitionDiagnostics(
            samples: samples, elapsed: elapsed, state: state, names: names,
            extensions: observation?.extensions.count ?? 0,
            calibration: fit.map { String(format: "%d rings · RMS %.2f px", $0.matchedNodes.count, $0.rootMeanSquareError) }
                ?? "waiting for 11 clear rings",
            milliseconds: milliseconds, snapshotCount: snapshotSchedule.count, changed: changed,
            error: error ?? writeError,
            phase: "\(tracker.state.rawValue) · \(tracker.phaseSource.rawValue)",
            slotSummary: slots.map { "\($0.slotCount) slots, highlight \($0.highlightedIndex.map { String($0 + 1) } ?? "none")" }
                ?? (slotRejection?.rawValue ?? "no strip read"),
            headerSummary: String(format: "%d read, %d dropped, %.0f ms",
                                  headerMetrics.completed, headerMetrics.droppedBusy,
                                  headerMetrics.lastLatencyMilliseconds),
            counters: counters, lastFacts: lastFacts)))
    }

    // MARK: - Snapshot

    private func makeSnapshot(observation: GlyphFrameObservation?, arrivalUptime: Double,
                              sourceTime: Double) -> GlyphDisplaySnapshot {
        let prefix = tracker.confirmedPrefix
        let expected = tracker.expectedSlotCount
        let key = prefix.map(\.name).joined(separator: ",") + "|" + (expected.map(String.init) ?? "-")
        if let predictor, key != cachedOutlookKey {
            cachedOutlook = predictor.outlook(observed: prefix, expectedLength: expected)
            cachedOutlookKey = key
        } else if predictor == nil {
            cachedOutlook = .unavailable
        }

        let provisional = observation?.state == .uniqueVisibleShape
            ? observation?.exactMatches.first : nil
        return GlyphDisplaySnapshot(
            captureSessionID: sessionID, hackID: tracker.hackID, revision: tracker.revision,
            liveness: .live, state: tracker.state, phaseSource: tracker.phaseSource,
            acceptance: .trackingSequence,
            sourceFrameTime: sourceTime, evidenceArrivalUptime: arrivalUptime,
            expectedSlotCount: expected, slots: tracker.slots,
            currentSlotIndex: tracker.currentSlotIndex, inputSlotIndex: tracker.inputSlotIndex,
            inputSlotObservedTime: tracker.lastIndicatorTime,
            indicatorsObstructed: tracker.indicatorsObstructed,
            slotCountConflict: tracker.slotCountConflict, isFrozen: tracker.isFrozen,
            provisionalGlyph: provisional, provisionalExtensionCount: observation?.extensions.count ?? 0,
            outlook: cachedOutlook,
            calibrationSummary: observation?.calibration.map {
                String(format: "%d rings · RMS %.2f px", $0.matchedNodes.count, $0.rootMeanSquareError)
            } ?? "waiting for 11 clear rings",
            inputChecks: inputValidator?.results ?? [], inputCheckRevision: inputValidator?.revision ?? 0,
            gear: readsGear ? gearDisplay.display : nil, gearRevision: gearDisplay.revision)
    }

    // MARK: - Logs

    private func consumeResult() {
        guard let read = headerReader.takeResult(), read.evidence.context == resultSession.context else { return }
        defer { if keepsDiagnostics { previousResultRead = read } }
        let before = resultSession.tracker?.result
        resultSession.accept(read.evidence)
        guard keepsDiagnostics else { return }
        append(read.evidence.diagnosticRow, to: resultFile)
        let after = resultSession.tracker?.result
        let decision = before?.outcomes != after?.outcomes
            || before?.finalHackingBonus != after?.finalHackingBonus
            || before?.finalSpeedBonus != after?.finalSpeedBonus
            || before?.finalStageTime != after?.finalStageTime
        if decision, let previous = previousResultRead,
           previous.evidence.context == read.evidence.context,
           let image = previous.image, let writer = resultWriter {
            let status = writer.enqueue(image, hackID: previous.evidence.context.hackID,
                                       sourceTime: previous.evidence.sourceTime, decision: true) ?? "queued"
            append(["schemaVersion": 1, "kind": "evidence", "hackID": previous.evidence.context.hackID,
                    "sourceTime": previous.evidence.sourceTime, "selection": "decisionSupport", "status": status],
                   to: resultFile)
        }
        if let selection = resultEvidenceSchedule.select(read.evidence, decision: decision) {
            var row: [String: Any] = ["schemaVersion": 1, "kind": "evidence", "hackID": read.evidence.context.hackID,
                "sourceTime": read.evidence.sourceTime, "selection": selection.rawValue]
            if selection == .budgetExhausted { row["status"] = "budgetExhausted" }
            else if let image = read.image, let writer = resultWriter {
                row["status"] = writer.enqueue(image, hackID: read.evidence.context.hackID,
                    sourceTime: read.evidence.sourceTime, decision: decision) ?? "queued"
            } else { row["status"] = "missingImage" }
            append(row, to: resultFile)
        }
        logResult()
    }

    // MARK: - Gear drops

    private func consumeGear() {
        guard readsGear else { return }
        // Reads stopped for a new panel: times only.
        for cancel in headerReader.takeGearCancels() {
            append(["schemaVersion": 1, "kind": "cancel", "sourceTime": cancel.sourceTime,
                    "requestedAt": cancel.requestedAt, "stopped": cancel.stopped,
                    "latencyMilliseconds": (cancel.latencyMilliseconds * 10).rounded() / 10], to: gearFile)
        }
        guard let read = headerReader.takeGear() else { return }
        let evidence = read.evidence
        if let closed = gearTracker.accept(evidence) { closeGear(closed) }
        var row = encodedRow(evidence) ?? [:]
        row["schemaVersion"] = 1; row["kind"] = "reading"
        row["disposition"] = gearTracker.readingDisposition.rawValue
        let readsPanel = gearTracker.readingDisposition == .accepted
        // Debug log only: counts and confidences of each OCR pass, no text.
        if read.untitledPanel { row["untitledPanel"] = true }
        if !read.passes.isEmpty { row["passes"] = read.passes.map(\.logRow) }
        row["powerConstrained"] = constrained
        for (key, value) in power.current.logRow { row[key] = value }
        // Only reads that saw the frame count: not out-of-order or closed ones.
        switch gearTracker.readingDisposition {
        case .accepted: gearRejections = 0
        case .nonPanel: gearRejections = min(Self.gearRejectionsBeforeIdle, gearRejections + 1)
        default: break
        }
        if readsPanel, gearTracker.isObserving, !gearGroupOpen {
            gearGroupOpen = true; gearEvidenceSchedule = GearEvidenceSchedule(); gearPictures = []
        }
        if readsPanel, let bounds = evidence.bounds, let image = read.image, let writer = gearWriter {
            if gearEvidenceSchedule.shouldSave(stage: evidence.stage, at: evidence.sourceTime) {
                let saved = writer.enqueue(image, bounds: bounds, sourceTime: evidence.sourceTime)
                if saved.file != nil {
                    gearEvidenceSchedule.didEnqueue(stage: evidence.stage, at: evidence.sourceTime)
                }
                if let file = saved.file, let folderName {
                    gearPictures.append(HackGearPicture(path: "\(folderName)/\(file)", stage: evidence.stage))
                }
                row["image"] = saved.file; row["imageStatus"] = saved.status
            } else { row["imageStatus"] = "evidenceSchedule" }
        }
        append(row, to: gearFile)
    }

    private func observeGear(at time: Double, evidence: FrameEvidence, slots: SlotStripReading?, analyzed: Bool,
                             gearBounds: GearDropPanelBounds?, resultPage: Bool) {
        if analyzed {
            lastInputVisible = evidence.hasInputTimerBar || slots?.highlightedIndex != nil
            lastGameProgressVisible = resultPage || gearBounds != nil
            if let closed = gearTracker.observe(at: time, panelCandidate: gearBounds != nil,
                                                pendingReadSourceTime: headerReader.pendingGearSourceTime) {
                closeGear(closed)
            }
        }
        gearSession.observe(at: time, hackID: tracker.hackID, inputVisible: lastInputVisible,
                            gameProgressVisible: lastGameProgressVisible, inputPhase: tracker.state)
        drainGearEvents()
        gearDisplay.update(waiting: gearSession.waiting, reading: gearTracker.isObserving,
                           associationUncertain: gearSession.isAssociationUncertain, at: time)
    }

    private func closeGear(_ group: GearDropSummary) {
        let attached = gearSession.close(group)
        gearDisplay.finished(attached)
        let pictures = gearPictures
        gearGroupOpen = false; gearPictures = []
        var row = encodedRow(attached) ?? [:]
        row["schemaVersion"] = 1; row["kind"] = "group"
        row["recognizedQuantity"] = attached.recognizedQuantity
        row["unidentifiedQuantity"] = attached.unidentifiedQuantity
        row["bothPanelsRead"] = attached.bothPanelsRead
        append(row, to: gearFile)
        if let hackID = attached.hackID {
            deliverGear(HackGearAttachment(captureSessionID: sessionID.rawValue, hackID: hackID,
                                           reading: .read(attached), pictures: pictures,
                                           portalLevel: portalLevel(for: hackID), sessionFolder: folderName))
        } else if attached.panels.contains(where: { !$0.entries.isEmpty }) {
            // A group with no row read has nothing to count: a cooldown or
            // out-of-range panel looks the same. It stays in the logs.
            deliverDrop(GearDrop(captureSessionID: sessionID.rawValue, summary: attached, pictures: pictures,
                                 sessionFolder: folderName))
        }
        drainGearEvents()
    }

    /// Logs queue changes, and tells the results page when a hack stopped
    /// waiting without a drop group, so a tester sees it was tried.
    private func drainGearEvents() {
        let events = gearSession.events
        guard events.count > loggedGearEvents else { return }
        for event in events[loggedGearEvents...] {
            var row: [String: Any] = ["schemaVersion": 1, "kind": "queue", "time": event.time, "reason": event.reason]
            if let hackID = event.hackID { row["hackID"] = hackID }
            append(row, to: gearFile)
            let ended = ["waitTimeout", "frameGap", "queueLimit", "captureStopped"].contains(event.reason)
            if ended, let hackID = event.hackID {
                gearDisplay.ended(hackID: hackID, at: event.time)
                deliverGear(HackGearAttachment(captureSessionID: sessionID.rawValue, hackID: hackID,
                                               reading: .notRead(reason: event.reason),
                                               portalLevel: portalLevel(for: hackID), sessionFolder: folderName))
            }
        }
        loggedGearEvents = events.count
    }

    // MARK: - Portal level

    private func consumePortal() {
        guard readsGear, let screen = headerReader.takePortal() else { return }
        portalObserver.accept(screen)
        var row = encodedRow(screen) ?? [:]
        row["schemaVersion"] = 1; row["kind"] = "portalScreen"
        append(row, to: gearFile)
    }

    /// A hack's portal screen is the last one before its Glyphs; its Glyph
    /// count is known once the input shows it.
    private func notePortal(_ events: [TrackingEvent]) {
        for event in events where event.kind == .hackStarted {
            if let screen = portalObserver.claim(at: event.time) { portalScreens[event.hackID] = screen }
        }
        if tracker.state == .input, tracker.hackID > 0, let count = tracker.expectedSlotCount, count > 0 {
            glyphCounts[tracker.hackID] = count
        }
        // Bounded: only hacks still waiting for drops need these.
        for key in portalScreens.keys.sorted().dropLast(32) { portalScreens[key] = nil }
        for key in glyphCounts.keys.sorted().dropLast(32) { glyphCounts[key] = nil }
    }

    /// Once per hack, when its gear is delivered, and logged with every source.
    private func portalLevel(for hackID: Int) -> PortalLevelEstimate? {
        // Commands are read with results, which gear reading with Glyphs needs.
        let estimate = PortalLevelRules.estimate(screen: portalScreens[hackID], glyphCount: glyphCounts[hackID],
                                                 glyphCountSettled: readsResults
                                                     && commands.summary(hackID: hackID).settlesGlyphCount)
        portalScreens[hackID] = nil; glyphCounts[hackID] = nil
        if let estimate {
            var row = encodedRow(estimate) ?? [:]
            row["schemaVersion"] = 1; row["kind"] = "portalLevel"; row["hackID"] = hackID
            append(row, to: gearFile)
        }
        return estimate
    }

    /// A crop with its own pixels: a plain `cropping(to:)` would keep the
    /// whole frame alive for as long as a notice waits for its read.
    private static func copy(_ image: CGImage, cropping rect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        // A colour space no bitmap context takes still gets its notice read.
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return cropped }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage() ?? cropped
    }

    private func consumeCommand() {
        for id in commands.takeDropped() {
            append(["schemaVersion": 1, "kind": "dropped", "noticeID": id], to: commandFile)
        }
        guard let (frame, read) = headerReader.takeCommand() else { return }
        commands.accept(read, frame: frame)
        var row: [String: Any] = ["schemaVersion": 1, "kind": "notice", "noticeID": frame.id,
                "sourceTime": frame.sourceTime, "notice": read.notice?.rawValue ?? "unreadable",
                "confidence": read.confidence, "language": read.language ?? "unknown"]
        if read.notice != nil, let file = commandWriter?.enqueue(frame) { row["image"] = file; row["imageStatus"] = "queued" }
        append(row, to: commandFile)
    }

    private func logCommands(hackID: Int, at time: Double, kind: String) {
        var row = encodedRow(commands.summary(hackID: hackID)) ?? [:]
        row["schemaVersion"] = 1; row["kind"] = kind; row["hackID"] = hackID; row["sourceTime"] = time
        append(row, to: commandFile)
    }

    private func encodedRow<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func logResult() {
        guard let observer = resultSession.tracker, observer.revision != loggedResultRevision else { return }
        loggedResultRevision = observer.revision
        publishResult(observer.result, comparison: resultSession.comparison)
    }

    /// Delivered whether or not logs are kept; only the log row needs them.
    private func publishResult(_ result: HackResult, comparison: ValidatorResultComparison?) {
        if readsGear { gearSession.accept(result) }
        let entries = comparison?.compare(result) ?? []
        deliverResult(HackResultSummary(result: result, comparison: entries))
        guard keepsDiagnostics else { return }
        var row = result.diagnosticRow
        row["commands"] = result.context.commands.flatMap(encodedRow)
        row["comparisons"] = entries.map(\.diagnosticRow)
        row["supersededAttemptIDs"] = comparison?.supersededAttemptIDs.sorted() ?? []
        append(row, to: resultFile)
    }

    private func recordInput(_ events: [InputCheckEvent]) {
        resultSession.accept(events)
        guard inputFile != nil else { return }
        for event in events { append(event.diagnosticRow, to: inputFile) }
    }

    private func record(_ events: [TrackingEvent], elapsed: Double) {
        guard trackingFile != nil else { return }
        for event in events {
            trackingEvents += 1
            var row: [String: Any] = [
                "event": trackingEvents, "schemaVersion": 1, "kind": event.kind.rawValue,
                "presentationTime": event.time, "elapsed": elapsed, "hackID": event.hackID,
                "reason": event.reason, "sampleCount": event.sampleCount,
                "trackingState": tracker.state.rawValue, "revision": tracker.revision
            ]
            if let index = event.slotIndex { row["slotIndex"] = index }
            if let glyph = event.glyph { row["glyph"] = glyph.name }
            append(row, to: trackingFile)
        }
    }

    private func append(_ row: [String: Any], to handle: FileHandle?) {
        guard let handle else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
            if samples % 20 == 0 { try handle.synchronize() }
        } catch { writeError = "Evidence log: \(error.localizedDescription)" }
    }
}
