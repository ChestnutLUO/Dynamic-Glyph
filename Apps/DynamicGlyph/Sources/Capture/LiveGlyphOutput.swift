import Foundation
import CoreImage
import CoreMedia
import ImageIO
import GlyphRecognition
import GlyphRecognitionImages
import GlyphRecognitionCxx

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
    /// The pixel steps: the luma gate, the conversions, the panel checks, the
    /// array hunt, the Glyph read and the slot strip. One of the two arms of
    /// the engine A/B; everything after it is shared.
    /// Made with a nil table without Glyph assistance: then only item panels
    /// are looked for.
    private let engine: FrameRecognitionEngine
    /// The logic arm's name, "swift" or "cpp": every decision after the
    /// engine (tracking, sessions, schedules, parsers) runs on that arm's
    /// objects, taken from one `RecognitionLogicSet`.
    let logicName: String
    private let makeGearEvidenceSchedule: () -> any GearEvidenceScheduling
    private let makePortalObserver: () -> any PortalLevelObserving
    private let portalLevelEstimate: @Sendable (PortalScreenEvidence?, Int?, Bool) -> PortalLevelEstimate?
    private let resultSummary: @Sendable (HackResult, [ValidatorResultComparison.Entry]) -> HackResultSummary
    /// The `lazyImage` cut: the frame's CGImage is rendered only when the
    /// text lane takes a read, not for every analysed frame. Nothing is
    /// saved while the engine renders one itself, as the Swift arm does.
    private let lazyImage: Bool
    /// The `planeGate` cut: with `lazyImage`, a footer label or command band
    /// that would be rendered alone is first looked at in the capture's
    /// planes, and not rendered when they show it holds nothing.
    private let planeGate: Bool
    /// The `portalSettle` cut: a portal screen is offered to the text lane
    /// only until `portalLimiter` calls its levels settled.
    private let portalSettle: Bool
    /// The `gearSettle` cut: a gear read due on a settled, still panel is
    /// answered with the read that settled it (`gearLimiter`).
    private let gearSettle: Bool
    /// The `resultSettle` cut: a result read due on a complete, still result
    /// panel is answered with the last read (`resultLimiter`).
    private let resultSettle: Bool
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
    private var gearTracker: any GearDropTracking
    private var gearSession: any GearDropSessioning
    private var gearDisplay: any GearDropDisplaying
    private var loggedGearEvents = 0
    private var gearEvidenceSchedule: any GearEvidenceScheduling
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
    private var portalObserver: any PortalLevelObserving
    /// Whether the portal screen on view still needs reading. Fed only with
    /// `portalSettle`; reset with the observer, and when a hack claims its
    /// screen.
    private var portalLimiter = PortalReadLimiter()
    /// Fed only with `gearSettle`: whether the current panel's settled
    /// reading may stand in for a read; and the frame a real gear read was
    /// admitted at, with its signature, until that read is taken.
    private var gearLimiter = GearSettleLimiter()
    private var gearSettleFrame: (time: Double, signature: StillSignature?, region: PanelRegion,
                                  bounds: GearDropPanelBounds)?
    /// Fed only with `resultSettle`, as `gearLimiter` is.
    private var resultLimiter = ResultSettleLimiter()
    private var resultSettleFrame: (time: Double, signature: StillSignature?, region: PanelRegion)?
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
    private let headerReader: GameHeaderReader
    private let commands: any CommandNoticeCapturing
    private var commandScreen: any CommandScreenWatching
    private let commandFile: FileHandle?
    private let commandWriter: CommandEvidenceWriter?
    private let predictor: (any SequencePredicting)?
    private var tracker: any PresentationTracking
    private var inputValidator: (any PlayerInputValidating)?
    private let inputFile: FileHandle?
    private let resultFile: FileHandle?
    private let resultWriter: ResultEvidenceWriter?
    private var resultSession: any ResultObserving
    private var resultEvidenceSchedule: any ResultEvidenceScheduling
    private var loggedResultRevision = -1
    private var previousResultRead: GameHeaderReader.ResultRead?

    private var lastSample = -Double.infinity
    /// The last frame due at the full rate, analyzed or not.
    private var lastLooked = -Double.infinity
    /// How often frames are analyzed and whether they get the full pipeline,
    /// from a luma gate read before any conversion. See `AnalysisRateController`.
    private var pace: any AnalysisPacing
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
    private var commandContext: any CommandPhaseContexting
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
    /// `engine` runs the pixel steps; nil is the Swift arm on `table`. Of the
    /// `cuts`, `lazyImage`, `planeGate`, `portalSettle`, `gearSettle` and `resultSettle` are applied here,
    /// `headerStillSkip`, `gearLeanRead`, `gearLanguageSettle`,
    /// `headerWindowMask` and `headerCoverSkip` by the header reader; the rest
    /// belong to the engine.
    /// `logic` is everything after the engine, made for this session from the
    /// same `table`, `sequenceTable` and `sessionID`; nil is the Swift set
    /// around `languages`. A given set brings its own language memory, and
    /// `languages` is then not used.
    init(table: GlyphTable?, sequenceTable: SequenceTable?, sessionID: CaptureSessionID,
         directory: URL?, recorders: [DebugScreenRecorder] = [], readsResults: Bool,
         readsGear: Bool = false, savesGearPictures: Bool = true,
         languages: GameLanguageMemory = GameLanguageMemory(language: .english, isAutomatic: false),
         power: PowerConditions = .shared, powerSaving: Bool = true,
         engine: FrameRecognitionEngine? = nil, cuts: Set<RecognitionCut> = [],
         logic: RecognitionLogicSet? = nil, meter: PowerMeter = .shared, readingMode: ReadingModeSignal? = nil,
         // Test seams only: nil preserves the shipped header, portal and gear OCR operations and scheduling.
         headerOperation: GameHeaderReader.HeaderOperation? = nil,
         portalOperation: GameHeaderReader.PortalOperation? = nil,
         gearReadingOperation: GameHeaderReader.GearReadingOperation? = nil,
         trace: (@Sendable (LiveGlyphTrace) -> Void)? = nil,
         telemetry: @escaping @Sendable (FrameTelemetry) -> Void,
         deliverResult: @escaping @Sendable (HackResultSummary) -> Void,
         deliverGear: @escaping @Sendable (HackGearAttachment) -> Void = { _ in },
         deliverDrop: @escaping @Sendable (GearDrop) -> Void = { _ in },
         deliver: @escaping @Sendable (LiveGlyphUpdate) -> Void) throws {
        assistsGlyphs = table != nil
        self.engine = engine ?? SwiftFrameRecognitionEngine(table: table)
        lazyImage = cuts.contains(.lazyImage)
        planeGate = cuts.contains(.planeGate)
        portalSettle = cuts.contains(.portalSettle)
        gearSettle = cuts.contains(.gearSettle)
        resultSettle = cuts.contains(.resultSettle)
        self.power = power
        self.powerSaving = powerSaving
        self.meter = meter
        self.readingMode = readingMode
        // A new session starts on the window's own background.
        readingMode?.publish(.none)
        self.trace = trace
        let logic = logic ?? makeSwiftLogicSet(table: table, sequenceTable: sequenceTable, sessionID: sessionID,
                                               languages: languages)
        logicName = logic.name
        makeGearEvidenceSchedule = logic.makeGearEvidenceSchedule
        makePortalObserver = logic.makePortalObserver
        portalLevelEstimate = logic.portalLevelEstimate
        resultSummary = logic.resultSummary
        headerReader = GameHeaderReader(configuration: .init(
            skipsUnchangedHeaders: powerSaving, languages: logic.languageMemory,
            allowsGearRetries: { !(powerSaving && power.isConstrained) },
            leanGearReads: cuts.contains(.gearLeanRead),
            settlesGearLanguage: cuts.contains(.gearLanguageSettle),
            skipsStillHeaders: cuts.contains(.headerStillSkip),
            masksHeaderWindow: cuts.contains(.headerWindowMask),
            skipsCoveredHeaders: cuts.contains(.headerCoverSkip)),
            logic: logic, headerOperation: headerOperation, gearReadingOperation: gearReadingOperation,
            portalOperation: portalOperation, meter: meter)
        predictor = logic.predictor
        self.sessionID = sessionID
        tracker = logic.tracker
        inputValidator = logic.inputValidator
        resultSession = logic.resultSession
        resultEvidenceSchedule = logic.resultEvidenceSchedule
        commands = logic.commandNoticeCapture
        commandScreen = logic.commandScreen
        commandContext = logic.commandContext
        gearTracker = logic.gearTracker
        gearSession = logic.gearSession
        gearEvidenceSchedule = logic.gearEvidenceSchedule
        portalObserver = logic.portalObserver
        pace = logic.pace
        commandWriter = directory.map(CommandEvidenceWriter.init(directory:))
        commandFile = try directory.map { try Self.makeFile($0.appendingPathComponent("commands.jsonl")) }
        inputFile = try directory.map { try Self.makeFile($0.appendingPathComponent("input-validation.jsonl")) }
        resultFile = try directory.map { try Self.makeFile($0.appendingPathComponent("results.jsonl")) }
        resultWriter = try directory.map(ResultEvidenceWriter.init(directory:))
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
        gearDisplay = logic.gearDisplay
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
            resultLimiter.reset(); resultSettleFrame = nil
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
                let renderStarted = meter.now()
                let crop = try? render(pixels, region: CommandNoticeDetector.band(width: facts.width,
                                                                                  height: facts.height))
                meter.finish(.bandRender, since: renderStarted)
                let bandStarted = meter.now()
                defer { meter.finish(.commandBand, since: bandStarted) }
                if let crop {
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
            gateReading = facts.status == .complete ? CMSampleBufferGetImageBuffer(buffer).flatMap(readGate) : nil
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
        var portalFaction: PortalFaction?
        /// The portal check ran on this frame's pixels, finding a screen or not.
        var portalChecked = false
        var observation: GlyphFrameObservation?
        var band: FrameTopBand?
        var slots: SlotStripReading?
        var slotRejection: SlotStripRejection?
        var slotCover: SlotStripWindowCover?
        var hasInputTimerBar = false
        /// The frame as a CGImage, once rendered: by the engine, or here on
        /// demand through `frameImage()`.
        var image: CGImage?
        /// The pixels the engine analysed, for a render on demand.
        var analysedPixels: CVPixelBuffer?
        var state = "waitingForEmptyArray"
        var error: String?
        if facts.status != .complete {
            // Idle means no new image; it does not establish a Glyph boundary.
            // Other stream interruptions invalidate geometric continuity.
            if facts.status != .idle { engine.resetSession(); gearContinuityBroken = true }
            state = "capture_\(facts.status.rawValue)"
        } else if facts.width >= facts.height || (facts.orientation != nil && facts.orientation != 1) {
            engine.resetSession()
            state = "unsupportedOrientation"
        } else if let pixels = CMSampleBufferGetImageBuffer(buffer) {
            // A portal's level is matched to the Glyph hack that follows,
            // when gear is read. With power saving the portal screen, which
            // comes before every hack, also keeps the full pace, so the hack's
            // empty array is fitted before its first Glyph. A quiet screen
            // shows no array: the search for one is skipped.
            let request = FrameAnalysisRequest(assistsGlyphs: assistsGlyphs, searchesArray: !quiet,
                                               checksGear: readsGear,
                                               checksPortal: assistsGlyphs && (readsGear || powerSaving),
                                               readsStrip: assistsGlyphs)
            do {
                let analysis = try FramePlanes.withLocked(pixels) { planes in
                    try engine.analyze(FrameInput(planes: planes, time: time) { try self.render(pixels) },
                                       request: request)
                }
                record(analysis.timings)
                analysedPixels = pixels
                image = analysis.image
                gearBounds = analysis.gearBounds
                portalCandidate = analysis.portalCandidate
                portalFaction = analysis.portalFaction
                portalChecked = request.checksPortal
                panelCandidate = analysis.resultCandidate
                observation = analysis.observation
                band = analysis.topBand
                switch analysis.slots {
                case .success(let reading)?: slots = reading
                case .failure(let rejection)?: slotRejection = rejection
                case nil: break
                }
                slotCover = analysis.slotCover
                hasInputTimerBar = analysis.hasInputTimerBar
                if assistsGlyphs {
                    // A hunt that ran this frame and matched all the rings is
                    // a fit on the current clock epoch.
                    if analysis.timings.gridHunt != nil, engine.sessionValidatedAt == time,
                       observation?.state == .noStroke, observation?.calibration != nil {
                        fitFreshnessIsCurrentEpoch = true
                    }
                    state = quiet ? "quietScreen" : observation?.state.rawValue ?? "waitingForEmptyArray"
                } else {
                    state = "gearOnly"
                }
            } catch let failure {
                engine.resetSession()
                state = "conversionFailed"
                error = String(describing: failure)
            }
        } else {
            engine.resetSession()
            state = "missingPixels"
        }
        let hasAnalysis = analysedPixels != nil
        /// The frame as a CGImage, rendered here if the engine left it to the
        /// text lane; nil when nothing was analysed or the render failed. The
        /// render is timed as conversion, like the engine's own.
        func frameImage() -> CGImage? {
            if let image { return image }
            guard let analysedPixels else { return nil }
            let started = meter.now()
            image = try? render(analysedPixels)
            meter.finish(.conversion, since: started)
            return image
        }
        /// A top-left rectangle of the analysed frame rendered on its own,
        /// timed as `metric` so that `conversion` keeps counting whole frames.
        /// It equals the same rectangle cut from a whole render, byte for byte
        /// (`RegionRenderTests`). Nil when nothing was analysed or the render
        /// failed.
        func regionImage(_ rect: CGRect, timedAs metric: PowerMetric) -> CGImage? {
            guard let analysedPixels else { return nil }
            let started = meter.now()
            defer { meter.finish(metric, since: started) }
            return try? render(analysedPixels, region: rect)
        }
        /// The frame as the lazy text lane takes it. A header read's rectangle
        /// is cut from the frame when that is rendered already, exactly as the
        /// read would crop it, so no frame is rendered twice; otherwise only
        /// the rectangle is rendered.
        let lazyFrame = GameHeaderReader.LazyFrame(width: facts.width, height: facts.height,
                                                   whole: frameImage) { rect in
            image.flatMap { $0.cropping(to: rect) } ?? regionImage(rect, timedAs: .headerRender)
        }
        samples += 1
        // Panel geometry keeps the pace until its reads have kept finding no
        // panel; an open group or a read panel keeps it regardless (`paceBusy`).
        if gearBounds != nil {
            lastGearBoundsTime = time
        } else if hasAnalysis, time < lastGearBoundsTime || time - lastGearBoundsTime > Self.gearRejectionsForgetAfter {
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
            // After the throttle: a notice lasts at least one 20-Hz sample.
            // Cut from the frame when it is rendered, or about to be for a text
            // lane without `lazyImage`; otherwise only the band is rendered,
            // and with `planeGate` not even that when the planes show it dark.
            if commandScreen.watching, hasAnalysis {
                let rect = CommandNoticeDetector.band(width: facts.width, height: facts.height)
                let frame = lazyImage ? image : frameImage()
                let alone = lazyImage && frame == nil
                let dark = alone && planeGate && analysedPixels.map(bandIsEmpty) == true
                let region = alone && !dark ? regionImage(rect, timedAs: .bandRender) : nil
                let bandStarted = meter.now()
                defer { meter.finish(.commandBand, since: bandStarted) }
                if dark {
                    commands.observeEmptyBand(at: time)
                    currentNotice = commands.showsNotice
                    meter.count(.bandGated)
                } else if let crop = region ?? frame.flatMap({ Self.copy($0, cropping: rect) }) {
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
            portalObserver = makePortalObserver()
            portalLimiter.reset()
            gearLimiter.reset(); gearSettleFrame = nil
            gearRejections = 0
            if let closed = gearTracker.loseContinuity(at: time) { closeGear(closed) }
            lastInputVisible = false; lastGameProgressVisible = false
            drainGearEvents()
        }
        if portalSettle, readsGear, portalChecked {
            if let portalFaction {
                portalLimiter.candidate(at: time, faction: portalFaction)
            } else {
                portalLimiter.absent(at: time)
            }
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
            && engine.sessionValidatedAt.map { time >= $0 && time - $0 <= Self.freshFitWindow } == true
        var header: HeaderReading?
        /// The header reader issued `header` again for a still header.
        var headerReused = false
        if hasAnalysis, !assistsGlyphs {
            // Only a panel needs reading: no header, no slot row.
            if let gearBounds {
                let reissues = gearSettleReissues(at: time, bounds: gearBounds, pixels: analysedPixels)
                var submission = GameHeaderReader.Submission.none
                if lazyImage {
                    submission = headerReader.submit(lazyFrame, at: time, session: sessionID, gearBounds: gearBounds,
                                                     readsHeader: false, constrained: constrained,
                                                     gearPanelSettled: gearTracker.currentPanelSettled,
                                                     gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: false,
                                                     reissues: reissues)
                } else if let image = frameImage() {
                    submission = headerReader.submit(image, at: time, session: sessionID, gearBounds: gearBounds,
                                                     readsHeader: false, constrained: constrained,
                                                     gearPanelSettled: gearTracker.currentPanelSettled,
                                                     gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: false,
                                                     reissues: reissues)
                }
                noteGearSubmission(submission, at: time, bounds: gearBounds, pixels: analysedPixels)
            } else {
                if gearSettle { gearLimiter.reset() }
                // The new-panel check needs the frames without a panel too.
                headerReader.observeGearPanel(nil, at: time)
            }
        } else if hasAnalysis {
            // Current evidence can precede the tracker entering a hack. Bypass
            // only content suppression, retaining the outside OCR cadence.
            let requiresFreshHeader = slots != nil || hasInputTimerBar || freshFit
            // Text recognition runs behind the sampler on its own schedule.
            // Between hacks the header only has to notice the next one.
            let headerInterval = powerSaving ? type(of: pace).headerInterval(
                mode: decision.mode, inHack: inHack, constrained: constrained) : nil
            let headerPriority = tracker.state == .presenting || tracker.state == .input
            // Commands come before presentation; the header has the lane to
            // itself while a hack is shown.
            let commandCapture = readsResults && tracker.state != .presenting && tracker.state != .input
                ? commands : nil
            let readsHeader = !powerSaving || headerInterval != nil
            let offersPortal = readsGear && portalCandidate && (!portalSettle || portalLimiter.wantsRead(at: time))
            if readsGear, portalCandidate, !offersPortal { meter.count(.portalHeld) }
            var reissues = gearSettleReissues(at: time, bounds: gearBounds, pixels: analysedPixels)
            reissues.result = resultSettleReading(at: time, panelCandidate: panelCandidate, pixels: analysedPixels)
            var submission = GameHeaderReader.Submission.none
            if lazyImage {
                // Rendered only if the lane takes this frame: see `GameHeaderReader`.
                submission = headerReader.submit(lazyFrame, at: time, session: sessionID,
                                    resultContext: resultSession.context, panelCandidate: panelCandidate,
                                    keepResultImage: keepsDiagnostics, gearBounds: gearBounds,
                                    headerPriority: headerPriority, portalCandidate: offersPortal,
                                    commands: commandCapture, readsHeader: readsHeader, headerInterval: headerInterval,
                                    constrained: constrained, gearPanelSettled: gearTracker.currentPanelSettled,
                                    gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: inHack,
                                    requiresFreshHeader: requiresFreshHeader, topBand: band, reissues: reissues)
            } else if let image = frameImage() {
                submission = headerReader.submit(image, at: time, session: sessionID,
                                    resultContext: resultSession.context, panelCandidate: panelCandidate,
                                    keepResultImage: keepsDiagnostics, gearBounds: gearBounds,
                                    headerPriority: headerPriority, portalCandidate: offersPortal,
                                    commands: commandCapture, readsHeader: readsHeader, headerInterval: headerInterval,
                                    constrained: constrained, gearPanelSettled: gearTracker.currentPanelSettled,
                                    gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: inHack,
                                    requiresFreshHeader: requiresFreshHeader, topBand: band, reissues: reissues)
            }
            noteGearSubmission(submission, at: time, bounds: gearBounds, pixels: analysedPixels)
            noteResultSubmission(submission, at: time, pixels: analysedPixels)
            let issued = headerReader.issuedReading(for: time, session: sessionID)
            header = issued?.reading
            headerReused = issued?.reused == true
        }

        let evidence = FrameEvidence(
            sessionID: sessionID, time: time,
            header: layoutConsistent || observation?.calibration == nil ? header : nil,
            slots: slots, slotRejection: slotRejection,
            shape: observation.map(ShapeEvidence.init) ?? .unavailable,
            hasValidCalibration: hasValidCalibration,
            hasInputTimerBar: hasInputTimerBar,
            partialSlots: slotCover?.row,
            hasPartialInputTimerBar: slotCover?.hasPartialInputTimerBar == true)
        // Hack signs that a slow look reads keep the next frames at the full
        // pace: the node array fitted where the layout expects it, the slot
        // strip, the input countdown, whole or beside our own window. A
        // resting look searches for the array; a quiet one (no candidate, so
        // no hack screen) does not.
        let countdown = evidence.hasInputTimerBar || evidence.hasPartialInputTimerBar
        if freshPixels {
            if powerSaving, slots != nil || countdown || freshFit {
                sawActivity = true
            }
            activityReasons.set(.calibration, powerSaving && freshFit)
            activityReasons.set(.slots, powerSaving && slots != nil)
            activityReasons.set(.timer, powerSaving && countdown)
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
            // qualify. With `headerStillSkip` a reading issued again for a
            // still header counts at the skipped frame's time, as a read of
            // that frame would: a header that changed is read, never reused.
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
            // An item panel on screen, or its group still being read, is no
            // time for a drone check: see `observeMode`. Asked before the
            // render, so a frame the probe would skip is not rendered for it.
            // With `lazyImage` a frame not rendered yet renders only the
            // footer's label.
            let panelShowing = gearBounds != nil || gearTracker.isObserving
            if !evidence.hasValidCalibration, commands.modeProbeDue(at: time, panelShowing: panelShowing) {
                if let frame = lazyImage ? image : frameImage() {
                    let probeStarted = meter.now()
                    _ = try? commands.observeMode(in: frame, at: time, panelShowing: panelShowing)
                    meter.finish(.footerProbe, since: probeStarted)
                } else if lazyImage, planeGate, let analysedPixels, !footerMayHoldCandidate(analysedPixels) {
                    // The planes show too little yellow for a candidate:
                    // `observeMode` would find none and change nothing.
                    meter.count(.footerGated)
                } else if lazyImage,
                          let footer = regionImage(DroneFooterProbe.textRect(width: facts.width, height: facts.height),
                                                   timedAs: .footerRender) {
                    let probeStarted = meter.now()
                    _ = try? commands.observeMode(footer: footer, frameWidth: facts.width, frameHeight: facts.height,
                                                  at: time, panelShowing: panelShowing)
                    meter.finish(.footerProbe, since: probeStarted)
                }
            }
        }
        if readsGear { notePortal(events) }
        let previousComparison = resultSession.comparison
        if readsResults,
           let retired = resultSession.observe(evidence, presentation: tracker, panelCandidate: panelCandidate,
                                               imageAnalyzed: hasAnalysis,
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
        if readsGear { observeGear(at: time, evidence: evidence, slots: slots, analyzed: hasAnalysis,
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
        if let snapshotWriter, observation != nil, snapshotSchedule.wantsSnapshot(key: key, at: time),
           let image = frameImage() {
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
        if let slotCover {
            row["windowCover"] = slotCover.side.rawValue
            row["windowCoveredFrom"] = slotCover.coveredFrom
            row["windowCoveredTo"] = slotCover.coveredTo
            row["partialInputTimerBar"] = slotCover.hasPartialInputTimerBar
            if let partial = slotCover.row {
                row["partialSlotCenters"] = partial.markerCentersX
                row["partialSlotHighlight"] = partial.highlightedMarker ?? -1
            }
        }
        if let header {
            row["headerPhase"] = header.phase.rawValue
            row["headerText"] = header.matchedText
            row["headerConfidence"] = header.confidence
            row["headerSourceTime"] = header.sourceTime
            if headerReused { row["headerReused"] = true }
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
                                  headerMetrics.lastLatencyMilliseconds)
                + Self.stillSummary(headerMetrics, reused: headerReused),
            counters: counters, lastFacts: lastFacts)))
    }

    /// The header cuts' part of the Diagnostics page's header line: looks
    /// skipped on a still header, those the `headerWindowMask` cut skipped
    /// once the window was left out, header reads the `headerCoverSkip` cut
    /// left out under the window, and whether this frame's reading was
    /// issued again rather than read. Empty without any skip.
    private static func stillSummary(_ metrics: GameHeaderReader.Metrics, reused: Bool) -> String {
        let skipped = metrics.headerSkippedStillInHack + metrics.headerSkippedStillOutside
        let masked = metrics.headerSkippedMaskedInHack + metrics.headerSkippedMaskedOutside
        let covered = metrics.headerSkippedCoveredInHack + metrics.headerSkippedCoveredOutside
        guard skipped + masked + covered > 0 else { return "" }
        return ", \(skipped) still" + (masked > 0 ? ", \(masked) masked" : "")
            + (covered > 0 ? ", \(covered) covered" : "") + (reused ? " (reused)" : "")
    }

    // MARK: - The engine's frame

    /// The luma gate straight from the capture's pixels, through the engine.
    /// Nil for a format it doesn't read, which then never slows analysis down.
    private func readGate(_ pixels: CVPixelBuffer) -> LumaGateReading? {
        FramePlanes.withLocked(pixels) { planes in planes.flatMap { engine.gate($0, step: LumaGate().step) } }
    }

    /// `RegionGate`'s prefilters straight from the capture's pixels, which
    /// are valid only while locked. A format they don't read is rendered
    /// and detected as without the cut.
    private func footerMayHoldCandidate(_ pixels: CVPixelBuffer) -> Bool {
        FramePlanes.withLocked(pixels) { planes in planes.map(RegionGate.footerMayHoldCandidate) ?? true }
    }

    private func bandIsEmpty(_ pixels: CVPixelBuffer) -> Bool {
        FramePlanes.withLocked(pixels) { planes in planes.map(RegionGate.bandIsEmpty) ?? false }
    }

    /// The frame through Core Image, as the Swift arm and the text lane need it.
    private func render(_ pixels: CVPixelBuffer) throws -> CGImage {
        let input = CIImage(cvPixelBuffer: pixels)
        guard let image = context.createCGImage(input, from: input.extent) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return image
    }

    /// One top-left `.integral` rectangle of the frame through Core Image,
    /// alone: the drone footer's label or the command band. Core Image
    /// renders into memory of its own, so the image holds none of the
    /// capture's planes.
    private func render(_ pixels: CVPixelBuffer, region: CGRect) throws -> CGImage {
        let input = CIImage(cvPixelBuffer: pixels)
        // Core Image uses a bottom-left origin; frame regions use top-left.
        let rect = CGRect(x: region.minX, y: input.extent.height - region.maxY, width: region.width,
                          height: region.height)
        guard let image = context.createCGImage(input, from: rect) else { throw CocoaError(.coderReadCorrupt) }
        return image
    }

    /// The engine's step times, into the Power section under the same names
    /// as when the steps ran here. A step that did not run is not counted.
    private func record(_ timings: FrameStepTimings) {
        let steps: [(PowerMetric, UInt64?)] = [
            (.conversion, timings.conversion), (.decode, timings.decode), (.gearCheck, timings.gearCheck),
            (.portalCheck, timings.portalCheck), (.resultCheck, timings.resultCheck), (.gridHunt, timings.gridHunt),
            (.glyphRead, timings.glyphRead), (.slotStrip, timings.slotStrip)
        ]
        for (metric, nanoseconds) in steps {
            if let nanoseconds { meter.record(metric, nanoseconds: nanoseconds) }
        }
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
        if resultSettle, !read.reissued { noteResultRead(read.evidence) }
        guard keepsDiagnostics else { return }
        var readRow = read.evidence.diagnosticRow
        if read.reissued { readRow["reissued"] = true }
        append(readRow, to: resultFile)
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

    /// `resultSettle`: the last reading to issue for a result read due at
    /// this frame, when the result is complete and the panel still against
    /// the read that completed it. The frame's signature is built only while
    /// a reading is anchored.
    private func resultSettleReading(at time: Double, panelCandidate: Bool,
                                     pixels: CVPixelBuffer?) -> ResultFrameEvidence? {
        guard resultSettle else { return nil }
        let signature = resultLimiter.isSettled
            ? resultLimiter.region.flatMap { region in pixels.flatMap { resultSignature($0, over: region) } } : nil
        return resultLimiter.look(at: time, context: resultSession.context, panelCandidate: panelCandidate,
                                  signature: signature)
    }

    /// `resultSettle`: a real result read started on this frame.
    private func noteResultSubmission(_ submission: GameHeaderReader.Submission, at time: Double,
                                      pixels: CVPixelBuffer?) {
        guard resultSettle, submission == .read(.result), let pixels,
              let region = ResultSettleLimiter.region(width: CVPixelBufferGetWidth(pixels),
                                                      height: CVPixelBufferGetHeight(pixels)) else { return }
        resultSettleFrame = (time, resultSignature(pixels, over: region), region)
    }

    /// `resultSettle`: a real result read the session accepted. It settles
    /// the limiter when the result is complete after it and the read agrees
    /// with the one before.
    private func noteResultRead(_ evidence: ResultFrameEvidence) {
        defer { resultSettleFrame = nil }
        guard let frame = resultSettleFrame, frame.time == evidence.sourceTime else {
            resultLimiter.reset(); return
        }
        resultLimiter.accept(evidence, complete: resultSession.tracker?.result.state == .complete,
                             signature: frame.signature, region: frame.region)
    }

    private func resultSignature(_ pixels: CVPixelBuffer, over region: PanelRegion) -> StillSignature? {
        FramePlanes.withLocked(pixels) { planes in
            planes.flatMap {
                StillSignature(planes: $0, left: region.left, top: region.top, width: region.width,
                               height: region.height, columns: ResultSettleLimiter.columns,
                               rows: ResultSettleLimiter.rows)
            }
        }
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
        if read.reissued { row["reissued"] = true } else if gearSettle { noteGearRead(evidence, accepted: readsPanel) }
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
            gearGroupOpen = true; gearEvidenceSchedule = makeGearEvidenceSchedule(); gearPictures = []
        }
        // A reissued reading kept its frame only when the schedule wanted it.
        if readsPanel, let bounds = evidence.bounds, read.image != nil || read.reissued, let writer = gearWriter {
            if !gearEvidenceSchedule.shouldSave(stage: evidence.stage, at: evidence.sourceTime) {
                row["imageStatus"] = "evidenceSchedule"
            } else if let image = read.image {
                let saved = writer.enqueue(image, bounds: bounds, sourceTime: evidence.sourceTime)
                if saved.file != nil {
                    gearEvidenceSchedule.didEnqueue(stage: evidence.stage, at: evidence.sourceTime)
                }
                if let file = saved.file, let folderName {
                    gearPictures.append(HackGearPicture(path: "\(folderName)/\(file)", stage: evidence.stage))
                }
                row["image"] = saved.file; row["imageStatus"] = saved.status
            } else {
                row["imageStatus"] = "notRendered"
            }
        }
        append(row, to: gearFile)
    }

    /// `gearSettle`: the settled reading to issue for a gear read due at this
    /// frame, when the current panel is settled and still against the read
    /// that settled it. The frame's signature is built only while a reading
    /// is anchored, from the capture's planes.
    private func gearSettleReissues(at time: Double, bounds: GearDropPanelBounds?,
                                    pixels: CVPixelBuffer?) -> GameHeaderReader.Reissues {
        guard gearSettle, gearLimiter.isSettled else { return GameHeaderReader.Reissues() }
        let signature = gearLimiter.region.flatMap { region in pixels.flatMap { gearSignature($0, over: region) } }
        guard let reading = gearLimiter.look(at: time, settled: gearTracker.currentPanelSettled,
                                             signature: signature, bounds: bounds) else {
            return GameHeaderReader.Reissues()
        }
        // A read would have kept its frame for the evidence pictures.
        let keepsImage = gearWriter != nil && gearEvidenceSchedule.shouldSave(stage: reading.stage, at: time)
        return GameHeaderReader.Reissues(gear: reading, keepsGearImage: keepsImage)
    }

    /// `gearSettle`: a real gear read started on this frame. Its signature,
    /// over the panel it reads, is what later frames are compared with once
    /// the read settles the panel.
    private func noteGearSubmission(_ submission: GameHeaderReader.Submission, at time: Double,
                                    bounds: GearDropPanelBounds?, pixels: CVPixelBuffer?) {
        guard gearSettle, submission == .read(.gear), let bounds, let pixels,
              let region = GearSettleLimiter.region(bounds, width: CVPixelBufferGetWidth(pixels),
                                                    height: CVPixelBufferGetHeight(pixels)) else { return }
        gearSettleFrame = (time, gearSignature(pixels, over: region), region, bounds)
    }

    /// `gearSettle`: a real gear read was taken. It anchors the limiter when
    /// the tracker accepted it and calls the panel settled after it; any
    /// other read ends the anchor.
    private func noteGearRead(_ evidence: GearDropFrameEvidence, accepted: Bool) {
        defer { gearSettleFrame = nil }
        guard accepted, let frame = gearSettleFrame, frame.time == evidence.sourceTime else {
            gearLimiter.reset(); return
        }
        gearLimiter.accept(evidence, settled: gearTracker.currentPanelSettled, signature: frame.signature,
                           region: frame.region, bounds: frame.bounds)
    }

    private func gearSignature(_ pixels: CVPixelBuffer, over region: PanelRegion) -> StillSignature? {
        FramePlanes.withLocked(pixels) { planes in
            planes.flatMap {
                StillSignature(planes: $0, left: region.left, top: region.top, width: region.width,
                               height: region.height, columns: GearSettleLimiter.columns,
                               rows: GearSettleLimiter.rows)
            }
        }
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
        if portalSettle { portalLimiter.accept(screen) }
        var row = encodedRow(screen) ?? [:]
        row["schemaVersion"] = 1; row["kind"] = "portalScreen"
        append(row, to: gearFile)
    }

    /// A hack's portal screen is the last one before its Glyphs; its Glyph
    /// count is known once the input shows it.
    private func notePortal(_ events: [TrackingEvent]) {
        for event in events where event.kind == .hackStarted {
            if let screen = portalObserver.claim(at: event.time) { portalScreens[event.hackID] = screen }
            portalLimiter.reset()
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
        let estimate = portalLevelEstimate(portalScreens[hackID], glyphCounts[hackID],
                                           readsResults && commands.summary(hackID: hackID).settlesGlyphCount)
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
    private func publishResult(_ result: HackResult, comparison: (any ValidatorResultComparing)?) {
        if readsGear { gearSession.accept(result) }
        let entries = comparison?.compare(result) ?? []
        deliverResult(resultSummary(result, entries))
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
