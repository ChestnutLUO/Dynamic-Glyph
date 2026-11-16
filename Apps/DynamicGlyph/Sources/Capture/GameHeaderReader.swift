import CoreGraphics
import Foundation
import GlyphRecognition
import GlyphRecognitionImages

/// One bounded OCR lane shared by headers, conclusion panels and gear-drop
/// panels. Every result retains its source timestamp and the hack identity
/// captured at submission.
final class GameHeaderReader: @unchecked Sendable {
    struct Configuration {
        var layout = GameUILayout()
        var minimumInterval = 0.1
        var maximumAge = 0.35
        var skipsUnchangedHeaders = true
        /// The game language, shared with the rest of the capture; readers
        /// try the others on a confirmed screen they can't read. A logic set
        /// given to the reader brings its own, which is used instead.
        var languages: any GameLanguageRemembering = GameLanguageMemory(language: .english, isAutomatic: false)
        /// Asked at each gear read: off reads a panel in one pass, without
        /// row or other-language retries (Low Power Mode, a hot phone), except
        /// one reread of each row that pass left unparsed and, for a missing
        /// or unclear title, one title pass in one language family.
        var allowsGearRetries: @Sendable () -> Bool = { true }
        /// The `gearLeanRead` cut: a gear read leaves out rereads of clearly
        /// red rows the panel pass read whole and of empty cells, and the
        /// numeric quantity pass (`GearDropScreenReader.RowRereads.lean`).
        var leanGearReads = false
        /// The `gearLanguageSettle` cut: once a screen has confirmed the
        /// automatic game language, a gear read of a titled panel with a
        /// name read stays in it
        /// (`GearDropScreenReader.mayShowAnotherLanguage`).
        var settlesGearLanguage = false
        /// The `headerStillSkip` cut. A header-only read, in a hack or out of
        /// one, fresh header required or not, is skipped while the header is
        /// still (`HeaderStillSignature`) against the last read admitted, for
        /// under `maximumUnchangedAge`, and that read's reading is issued
        /// again at the skipped frame's time. The issue keeps the header's
        /// cadence as the read would have, so headers are answered at the
        /// same frames with the cut as without it. It replaces the exact
        /// comparison `skipsUnchangedHeaders` makes; off leaves that as it is.
        var skipsStillHeaders = false
        /// The `headerWindowMask` cut, a refinement of `skipsStillHeaders`
        /// that does nothing without it. When a header is not still, the
        /// app's own Picture in Picture window is looked for in the engine's
        /// top band (`FloatingWindowFinder`), in this frame and in the last
        /// read's; found in both, in the same place, the cells under it are
        /// left out and the rest compared (`HeaderStillSignature`). Still
        /// there, the look is skipped as a still one is. The window found
        /// nowhere, moved, or leaving too little of the header compares the
        /// whole header as `skipsStillHeaders` alone does.
        var masksHeaderWindow = false
        /// The `headerCoverSkip` cut. When the schedule offers a header-only
        /// read, or takes a command read, the app's own Picture in Picture
        /// window is looked for in the engine's top band
        /// (`FloatingWindowFinder`), at most once a frame. Over at least half
        /// of the header's rows (`coversHeader`), the header is not read: a
        /// header-only look is skipped with no reading issued, as for a
        /// header that can't be read, and leaves the lane free; a command
        /// read reads its notice alone. No band, no window or a window over
        /// less of the header reads as before. With `skipsStillHeaders`, a
        /// look its cadence holds is never asked, and a covered look is
        /// skipped before the still comparison, so it issues nothing.
        var skipsCoveredHeaders = false
    }

    struct Metrics: Sendable {
        var headerInHackSubmitted = 0
        var headerOutsideSubmitted = 0
        var headerSkippedUnchanged = 0
        /// Header-only reads the `headerStillSkip` cut skipped, each issuing
        /// the last read's reading again, in a hack and outside one.
        var headerSkippedStillInHack = 0
        var headerSkippedStillOutside = 0
        /// Header-only reads the `headerWindowMask` cut skipped, still only
        /// once the window's cells were left out, in a hack and outside one.
        var headerSkippedMaskedInHack = 0
        var headerSkippedMaskedOutside = 0
        /// Header OCR the `headerCoverSkip` cut left out while the app's
        /// window covered the header, in a hack and outside one: header-only
        /// looks skipped, and command reads' header requests.
        var headerSkippedCoveredInHack = 0
        var headerSkippedCoveredOutside = 0
        /// Gear reads due on a settled panel that the `gearSettle` cut
        /// answered with the settling read's evidence instead.
        var gearReissued = 0
        /// Result reads due on a complete result that the `resultSettle` cut
        /// answered with its last reading instead.
        var resultReissued = 0
        var submitted = 0
        var completed = 0
        var droppedBusy = 0
        var failed = 0
        var resultSubmitted = 0
        var resultCompleted = 0
        var staleCompletions = 0
        var lastLatencyMilliseconds = 0.0
        var resultLatencyMilliseconds = 0.0
        var resultTotalLatencyMilliseconds = 0.0
        var resultError: String?
        var gearSubmitted = 0
        var gearCompleted = 0
        var gearLatencyMilliseconds = 0.0
        var gearError: String?
        /// Gear reads asked to stop for a new panel (`GameTextSchedule
        /// .observeGearPanel`), how many stopped early and how many had
        /// already finished, and the time from asking to the read's return.
        var gearCancelRequested = 0
        var gearCancelStopped = 0
        var gearCancelFinished = 0
        var gearCancelLatencyMilliseconds = 0.0
        var gearCancelTotalLatencyMilliseconds = 0.0
        var gearCancelMaximumLatencyMilliseconds = 0.0
        var portalSubmitted = 0
        var portalCompleted = 0
        var portalLatencyMilliseconds = 0.0
        var portalError: String?
        var totalLatencyMilliseconds = 0.0
        var lastError: String?
        var averageLatencyMilliseconds: Double {
            let headers = completed - resultCompleted - gearCompleted - portalCompleted
            return headers > 0 ? totalLatencyMilliseconds / Double(headers) : 0
        }
    }

    struct ResultRead: @unchecked Sendable {
        let evidence: ResultFrameEvidence
        /// Retained only for optional evidence logging; at most one completed read.
        let image: CGImage?
        /// Issued again by a settle cut in place of a read: no OCR ran.
        var reissued = false
    }

    /// A gear read asked to stop for a new panel, once it has returned: for
    /// the session log, times only.
    struct GearCancel: Sendable {
        /// The read's source frame, and the new panel's frame that stopped it.
        let sourceTime: Double
        let requestedAt: Double
        /// From the ask to the read's return, on the uptime clock.
        let latencyMilliseconds: Double
        /// False when the read had finished all its passes anyway.
        let stopped: Bool
    }

    struct GearRead: @unchecked Sendable {
        let evidence: GearDropFrameEvidence
        /// Retained only for evidence logging, which gear reading requires.
        let image: CGImage?
        /// No panel title, but a drop panel's body (`GearPanelReading`).
        var untitledPanel = false
        /// The read's OCR passes, for the session log only.
        var passes: [GearReadPass] = []
        /// Issued again by a settle cut in place of a read: no OCR ran.
        var reissued = false
    }

    /// What a settle cut issues in place of a read due at the submitted
    /// frame, if the schedule offers one. `gear` is the settled panel's
    /// evidence (`GearSettleLimiter`); `keepsGearImage` renders the frame
    /// for it, as a read would have kept it, when the caller would save it.
    /// `result` is a complete result's last reading (`ResultSettleLimiter`),
    /// kept with its frame as `keepResultImage` keeps a read's.
    struct Reissues {
        var gear: GearDropFrameEvidence?
        var keepsGearImage = false
        var result: ResultFrameEvidence?
    }

    /// What a submission did with the lane: nothing, a read started, or a
    /// reading issued again in its place.
    enum Submission: Equatable {
        case none
        case read(GameTextSchedule.Mode)
        case reissued(GameTextSchedule.Mode)
    }

    /// What a header read is given: the whole frame, or only its header
    /// rectangle (`HeaderTextRecognizer.headerRect`), which the read then
    /// takes as its crop.
    enum HeaderImage: Sendable {
        case frame(CGImage)
        case region(CGImage)
    }

    /// A frame the lane renders only once it admits a read: the `lazyImage`
    /// cut. Header and command reads ask for the header's rectangle alone;
    /// result, gear and portal reads, which also keep the frame as evidence,
    /// for the whole.
    struct LazyFrame {
        let width: Int, height: Int
        /// The whole frame, rendered at most once.
        let whole: () -> CGImage?
        /// One top-left rectangle of the frame.
        let region: (CGRect) -> CGImage?
    }

    typealias HeaderOperation = @Sendable (HeaderImage, Double) async throws -> HeaderReading
    typealias ResultOperation = @Sendable (CGImage, ResultReadContext, Double) throws -> ResultFrameEvidence
    typealias GearOperation = @Sendable (CGImage, GearDropPanelBounds, Double) throws -> GearDropFrameEvidence
    /// A gear read with what pacing and the session log need besides evidence.
    typealias GearReadingOperation = @Sendable (CGImage, GearDropPanelBounds, Double) throws -> GearPanelReading
    /// A gear read that can be stopped: when a new panel replaces the one
    /// it reads, the lane cancels the token, and the read throws (or returns
    /// in full, if it had finished). It owns the lane until it returns.
    typealias CancellableGearReadingOperation =
        @Sendable (CGImage, GearDropPanelBounds, Double, GearReadCancellation) throws -> GearPanelReading
    typealias PortalOperation = @Sendable (CGImage, Double) throws -> PortalScreenEvidence
    private let readHeader: HeaderOperation
    private let readResult: ResultOperation
    private let readGear: CancellableGearReadingOperation
    private let readPortal: PortalOperation
    private let commandLogic: CommandNoticeReader.Logic
    private let configuration: Configuration
    /// The layout's header rectangle, as every header read crops it.
    private let headerGeometry: HeaderTextRecognizer
    /// The capture's language: the logic set's, or the configuration's.
    private let languages: any GameLanguageRemembering
    private let meter: PowerMeter?
    /// Exact packed RGB content, not a lossy thumbnail/hash: any changed byte
    /// in the OCR crop forces a read at the next eligible look. The slice
    /// retains at most one already-decoded top band, never a capture surface.
    private struct HeaderSignature: Equatable, Sendable {
        let width: Int
        let frameHeight: Int
        let rows: Range<Int>
        let pixels: ArraySlice<UInt8>
    }
    private struct HeaderBaseline {
        let signature: HeaderSignature
        let session: CaptureSessionID
        let language: GameLanguage
        let sourceTime: Double
    }
    /// The `headerStillSkip` cut's anchor: the last header-only read the lane
    /// admitted, and the reading it returned once it has. A command read,
    /// a failure or an invalidation leaves none. `issuedAt` is the last frame
    /// its reading was issued again for. `window` is where the app's window
    /// stood in the read's frame, found only with `masksHeaderWindow`.
    private struct StillAnchor {
        let signature: HeaderStillSignature
        let window: FloatingWindowFinder.Window?
        let session: CaptureSessionID
        let language: GameLanguage
        let sourceTime: Double
        let requestID: Int
        var reading: HeaderReading?
        var issuedAt: Double?
    }
    /// Two normal outside-hack intervals (0.5 s), one constrained interval
    /// (1 s). Never suppress a look at/after this age, even if pixels match.
    /// Quiet mode/no frames/busy panels can delay eligibility, not this gate.
    /// With `skipsStillHeaders` it is how old the anchor's read may be: the
    /// header is read for real at least once a second, in a hack too.
    static let maximumUnchangedAge = 1.0
    /// Seconds between two reads of a gear panel; doubled when constrained,
    /// except between a read finding a panel and its rows being confirmed.
    static let gearInterval = 0.2
    private var headerBaseline: HeaderBaseline?
    private var stillAnchor: StillAnchor?
    private let lock = NSLock()
    /// The lane's schedule: the logic set's, or the Swift one.
    private var schedule: any GameTextScheduling
    private var generation = 0
    private var phaseGeneration = 0
    private var gearGeneration = 0
    private var submittedGearGeneration: Int?
    private var activeContext: ResultReadContext?
    private var reading: HeaderReading?
    private var readingSession: CaptureSessionID?
    /// `reading` was issued again for a still header, not read.
    private var readingReused = false
    private var resultRead: ResultRead?
    private var gearRead: GearRead?
    private var portalRead: PortalScreenEvidence?
    private var commandRead: (CommandNoticeFrame, CommandNoticeReading)?
    private var metrics = Metrics()
    /// The running gear read's token, and when (uptime, frame time) the lane
    /// asked it to stop.
    private var gearCancellation: (id: Int, token: GearReadCancellation)?
    private var gearCancelAsked: (id: Int, uptime: Double, frameTime: Double)?
    private var gearCancels: [GearCancel] = []

    /// `logic` supplies the schedule, the language memory and the text
    /// parsers, from one arm of the logic layer; nil is the Swift arm with
    /// the configuration's language.
    init(configuration: Configuration = Configuration(), logic: RecognitionLogicSet? = nil,
         headerOperation: HeaderOperation? = nil,
         resultOperation: ResultOperation? = nil, gearOperation: GearOperation? = nil,
         gearReadingOperation: GearReadingOperation? = nil,
         cancellableGearReadingOperation: CancellableGearReadingOperation? = nil,
         portalOperation: PortalOperation? = nil, meter: PowerMeter? = nil) {
        self.configuration = configuration
        self.meter = meter
        let languages = logic?.languageMemory ?? configuration.languages
        self.languages = languages
        schedule = logic?.textSchedule ?? GameTextSchedule()
        commandLogic = logic?.commandReaderLogic ?? .swift
        let layout = configuration.layout
        headerGeometry = HeaderTextRecognizer(layout: layout)
        let headerMatcher = logic?.headerPhraseMatcher ?? { HeaderPhraseMatcher(language: $0) }
        // The header follows the language the other screens found.
        readHeader = headerOperation ?? { image, time in
            let language = languages.current
            let recognizer = HeaderTextRecognizer(layout: layout, language: language, matcher: headerMatcher(language))
            switch image {
            case .frame(let frame): return try await recognizer.read(frame, sourceTime: time)
            case .region(let header): return try await recognizer.read(headerRegion: header, sourceTime: time)
            }
        }
        let resultParsers = logic?.resultTextParser ?? ResultScreenReader.swiftParsers
        readResult = resultOperation ?? { image, context, time in
            try ResultScreenReader.read(image, context: context, sourceTime: time, languages: languages,
                                        parsers: resultParsers)
        }
        let titleMemory = logic?.makeGearTitleMemory() ?? GearTitleLanguageMemory()
        let allowsGearRetries = configuration.allowsGearRetries
        let leanGearReads = configuration.leanGearReads
        let settlesGearLanguage = configuration.settlesGearLanguage
        let gearLogic = logic?.gearReaderLogic ?? .swift
        // Test seams: `cancellableGearReadingOperation` first, then
        // `gearReadingOperation`, then `gearOperation`. The last two can't be
        // stopped: asked to, they run to the end and are delivered.
        let evidenceOnly: GearReadingOperation? = gearOperation.map { operation in
            { image, bounds, time in GearPanelReading(evidence: try operation(image, bounds, time)) }
        }
        let uncancellable: CancellableGearReadingOperation? = (gearReadingOperation ?? evidenceOnly).map { operation in
            let wrapped: CancellableGearReadingOperation = { image, bounds, time, _ in try operation(image, bounds, time) }
            return wrapped
        }
        readGear = cancellableGearReadingOperation ?? uncancellable ?? { image, bounds, time, cancellation in
            try GearDropScreenReader.reading(image, bounds: bounds, sourceTime: time, titleMemory: titleMemory,
                                             languages: languages, retries: allowsGearRetries(),
                                             rereadsUnreadableRows: true, lean: leanGearReads,
                                             settlesLanguage: settlesGearLanguage, cancellation: cancellation,
                                             logic: gearLogic)
        }
        let portalReader = PortalScreenReader(parser: logic?.portalScreenParser ?? PortalScreenParser())
        readPortal = portalOperation ?? { image, time in try portalReader.read(image, sourceTime: time) }
    }

    /// `gearBounds` is the drop panel found in this frame, or nil when gear
    /// reading is off or no panel shows. `headerPriority` keeps gear reads out
    /// of a presentation or input, when the header decides the phase.
    /// `readsHeader` off leaves the lane idle between panel reads.
    /// `headerInterval` slows header-only reads below the lane's cadence.
    /// `inHack` and current-frame `requiresFreshHeader` bypass content suppression
    /// without changing cadence or hack classification. `topBand` reuses the
    /// slot reader's decoded pixels. Only outside header-only reads can skip,
    /// unless `skipsStillHeaders` is on: then any header-only read can.
    /// `constrained` doubles the lane's interval and the gear panel's cadence,
    /// except while a panel that a read has found stays on screen with rows
    /// still to confirm (`gearPanelSettled` false). Every read runs at
    /// user-initiated priority: the lane is shared, so a slow panel read
    /// would hold up the header reads a phase waits on.
    /// Every call is an analysed frame for the new-panel check
    /// (`GameTextSchedule.observeGearPanel`): a new panel stops the gear
    /// read in flight, which keeps the lane until it returns, and its own
    /// first read then has no spacing. `gearPanelUnconfirmed` (an open drop
    /// group whose current panel isn't settled) lets that read run on.
    /// Callers that skip frames without a panel call
    /// `observeGearPanel(nil, at:)` for them.
    /// `reissues` answers a read the schedule admits, without OCR, with a
    /// settle cut's reading at this frame's time: the schedule finishes it
    /// at once, as a read that found its panel, and `takeGear` or
    /// `takeResult` returns it like a read. Returns what the lane did with
    /// the frame.
    @discardableResult
    func submit(_ image: CGImage, at time: Double, session: CaptureSessionID,
                resultContext: ResultReadContext? = nil, panelCandidate: Bool = false,
                keepResultImage: Bool = false, gearBounds: GearDropPanelBounds? = nil,
                headerPriority: Bool = false, portalCandidate: Bool = false,
                commands: (any CommandNoticeCapturing)? = nil, readsHeader: Bool = true,
                headerInterval: Double? = nil, constrained: Bool = false, gearPanelSettled: Bool = false,
                gearPanelUnconfirmed: Bool = false,
                inHack: Bool = true, requiresFreshHeader: Bool = false, topBand: FrameTopBand? = nil,
                reissues: Reissues = Reissues()) -> Submission {
        perform(width: image.width, height: image.height, source: .rendered(image),
                at: time, session: session, resultContext: resultContext, panelCandidate: panelCandidate,
                keepResultImage: keepResultImage, gearBounds: gearBounds, headerPriority: headerPriority,
                portalCandidate: portalCandidate, commands: commands, readsHeader: readsHeader,
                headerInterval: headerInterval, constrained: constrained, gearPanelSettled: gearPanelSettled,
                gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: inHack,
                requiresFreshHeader: requiresFreshHeader, topBand: topBand, reissues: reissues)
    }

    /// The same submission with the frame rendered only once the schedule has
    /// admitted a read: the `lazyImage` cut. `frame` renders once, after
    /// `schedule.take`, and never for a submit that is dropped: a header or
    /// command read only the header's rectangle, any other read the whole
    /// frame. Nil releases the lane and counts as a failed read. The
    /// unchanged-header check reads `topBand`; without a matching band it
    /// performs OCR rather than render a frame the schedule might then skip.
    @discardableResult
    func submit(_ frame: LazyFrame, at time: Double, session: CaptureSessionID,
                resultContext: ResultReadContext? = nil, panelCandidate: Bool = false,
                keepResultImage: Bool = false, gearBounds: GearDropPanelBounds? = nil,
                headerPriority: Bool = false, portalCandidate: Bool = false,
                commands: (any CommandNoticeCapturing)? = nil, readsHeader: Bool = true,
                headerInterval: Double? = nil, constrained: Bool = false, gearPanelSettled: Bool = false,
                gearPanelUnconfirmed: Bool = false,
                inHack: Bool = true, requiresFreshHeader: Bool = false, topBand: FrameTopBand? = nil,
                reissues: Reissues = Reissues()) -> Submission {
        perform(width: frame.width, height: frame.height, source: .lazy(frame),
                at: time, session: session, resultContext: resultContext, panelCandidate: panelCandidate,
                keepResultImage: keepResultImage, gearBounds: gearBounds, headerPriority: headerPriority,
                portalCandidate: portalCandidate, commands: commands, readsHeader: readsHeader,
                headerInterval: headerInterval, constrained: constrained, gearPanelSettled: gearPanelSettled,
                gearPanelUnconfirmed: gearPanelUnconfirmed, inHack: inHack,
                requiresFreshHeader: requiresFreshHeader, topBand: topBand, reissues: reissues)
    }

    /// A submission's frame: rendered already, or rendered on admission.
    private enum FrameSource {
        case rendered(CGImage)
        case lazy(LazyFrame)
    }

    private func perform(width: Int, height: Int, source: FrameSource,
                         at time: Double, session: CaptureSessionID,
                         resultContext: ResultReadContext?, panelCandidate: Bool,
                         keepResultImage: Bool, gearBounds: GearDropPanelBounds?,
                         headerPriority: Bool, portalCandidate: Bool,
                         commands: (any CommandNoticeCapturing)?, readsHeader: Bool,
                         headerInterval: Double?, constrained: Bool, gearPanelSettled: Bool,
                         gearPanelUnconfirmed: Bool,
                         inHack: Bool, requiresFreshHeader: Bool, topBand: FrameTopBand?,
                         reissues: Reissues) -> Submission {
        lock.lock()
        noteGearPanel(gearBounds, at: time, previousPanelUnconfirmed: gearPanelUnconfirmed)
        activeContext = resultContext
        if inHack || requiresFreshHeader { headerBaseline = nil }
        // A completion can race the consumer's takeResult() call. Keep that
        // source frame until it is drained rather than overwrite it next read.
        guard resultRead == nil, gearRead == nil, portalRead == nil, commandRead == nil else {
            metrics.droppedBusy += 1
            lock.unlock()
            return .none
        }
        let busy = schedule.inFlight != nil
        let language = languages.current
        var signature: HeaderSignature?
        var stillSignature: HeaderStillSignature?
        // `headerWindowMask` and `headerCoverSkip`: the window in this
        // frame, looked for at most once, when a look first needs it.
        var window: FloatingWindowFinder.Window??
        let findWindow = { () -> FloatingWindowFinder.Window? in
            if let found = window { return found }
            let found = self.floatingWindow(width: width, height: height, topBand: topBand)
            window = .some(found)
            return found
        }
        let minimumInterval = configuration.minimumInterval * (constrained ? 2 : 1)
        // The schedule calls admission only for an eligible header-only look,
        // before reserving the shared lane. Comparison/counters stay locked.
        guard let request = schedule.take(at: time, panelCandidate: panelCandidate,
                                          resultEligible: resultContext != nil,
                                          minimumInterval: minimumInterval,
                                          gearCandidate: gearBounds != nil,
                                          headerPriority: headerPriority, portalCandidate: portalCandidate,
                                          commandCandidate: commands?.queue.isEmpty == false,
                                          readsHeader: readsHeader, headerInterval: headerInterval,
                                          gearInterval: constrained ? 2 * Self.gearInterval : Self.gearInterval,
                                          // A panel a read has found keeps the normal pace
                                          // until its rows are confirmed: each needs two
                                          // agreeing reads before the panel goes.
                                          gearPanelPace: constrained && !gearPanelSettled
                                              ? .init(minimumInterval: configuration.minimumInterval,
                                                      gearInterval: Self.gearInterval) : nil,
                                          admitsHeader: {
            if configuration.skipsStillHeaders,
               stillIssueHoldsCadence(at: time, session: session, language: language,
                                      minimumInterval: minimumInterval, headerInterval: headerInterval) {
                return false
            }
            if configuration.skipsCoveredHeaders, coversHeader(findWindow(), width: width, height: height) {
                countCovered(inHack: inHack)
                return false
            }
            if configuration.skipsStillHeaders {
                stillSignature = headerStillSignature(width: width, height: height, topBand: topBand) {
                    if case .rendered(let image) = source { return image }
                    return nil
                }
                guard let reissued = stillReading(stillSignature, at: time, session: session, language: language,
                                                  rows: headerRows(width: width, height: height),
                                                  window: findWindow) else { return true }
                stillAnchor?.issuedAt = time
                reading = reissued.reading; readingSession = session; readingReused = true
                switch (reissued.masked, inHack) {
                case (false, true): metrics.headerSkippedStillInHack += 1; meter?.count(.headerStillInHack)
                case (false, false): metrics.headerSkippedStillOutside += 1; meter?.count(.headerStillOutside)
                case (true, true): metrics.headerSkippedMaskedInHack += 1; meter?.count(.headerMaskedInHack)
                case (true, false): metrics.headerSkippedMaskedOutside += 1; meter?.count(.headerMaskedOutside)
                }
                return false
            }
            guard !inHack, !requiresFreshHeader, configuration.skipsUnchangedHeaders else { return true }
            signature = headerSignature(width: width, height: height, topBand: topBand) {
                if case .rendered(let image) = source { return image }
                return nil
            }
            guard let signature, let baseline = headerBaseline,
                  baseline.session == session, baseline.language == language,
                  time >= baseline.sourceTime, time - baseline.sourceTime < Self.maximumUnchangedAge,
                  signature == baseline.signature else { return true }
            metrics.headerSkippedUnchanged += 1
            meter?.count(.headerUnchanged)
            // No new reading or sourceTime: reused OCR cannot cast fresh votes.
            return false
        }) else {
            if busy { metrics.droppedBusy += 1 }
            lock.unlock(); return .none
        }
        if request.mode == .gear, let settled = reissues.gear {
            // The schedule's cadence moves as for a read that found its
            // panel; the lane is free again at once.
            let image: CGImage?
            switch source {
            case .rendered(let frame): image = reissues.keepsGearImage ? frame : nil
            case .lazy(let frame): image = reissues.keepsGearImage ? frame.whole() : nil
            }
            schedule.finish(request, panelPresent: true)
            gearRead = GearRead(evidence: settled.at(sourceTime: time), image: image, reissued: true)
            metrics.gearReissued += 1
            meter?.count(.gearHeld)
            lock.unlock(); return .reissued(.gear)
        }
        if request.mode == .result, let settled = reissues.result, settled.context == resultContext {
            let image: CGImage?
            switch source {
            case .rendered(let frame): image = keepResultImage ? frame : nil
            case .lazy(let frame): image = keepResultImage ? frame.whole() : nil
            }
            schedule.finish(request, panelPresent: settled.panelPresent)
            resultRead = ResultRead(evidence: settled.at(sourceTime: time), image: image, reissued: true)
            metrics.resultReissued += 1
            meter?.count(.resultHeld)
            lock.unlock(); return .reissued(.result)
        }
        // Admitted: the frame is rendered now, once, for this read alone.
        let headerRequest = request.mode == .header || request.mode == .command
        // `headerCoverSkip`: a command read under the window reads its
        // notice alone, and a lazy frame is not rendered for it.
        let skipsCommandHeader = request.mode == .command && configuration.skipsCoveredHeaders
            && coversHeader(findWindow(), width: width, height: height)
        let rendered: HeaderImage?
        switch source {
        case .rendered(let image): rendered = .frame(image)
        case .lazy where skipsCommandHeader: rendered = nil
        case .lazy(let frame) where headerRequest:
            rendered = frame.region(headerGeometry.headerRect(width: width, height: height)).map(HeaderImage.region)
        case .lazy(let frame): rendered = frame.whole().map(HeaderImage.frame)
        }
        if rendered == nil && !skipsCommandHeader {
            schedule.finish(request)
            metrics.failed += 1
            switch request.mode {
            case .result: metrics.resultError = "frame not rendered"
            case .gear: metrics.gearError = "frame not rendered"
            case .portal: metrics.portalError = "frame not rendered"
            case .header, .command: metrics.lastError = "frame not rendered"
            }
            lock.unlock(); return .none
        }
        if headerRequest {
            // Store on admission, not completion: hack evidence or an
            // invalidation while OCR runs must not allow a late cache refill.
            headerBaseline = signature.map {
                HeaderBaseline(signature: $0, session: session, language: language, sourceTime: time)
            }
            if configuration.skipsStillHeaders {
                // A command read is never asked, so it leaves no anchor.
                stillAnchor = stillSignature.map {
                    StillAnchor(signature: $0, window: configuration.masksHeaderWindow ? findWindow() : nil,
                                session: session, language: language, sourceTime: time, requestID: request.id)
                }
            }
        }
        let commandFrame = request.mode == .command ? commands?.take(at: time) : nil
        let cancellation = GearReadCancellation()
        gearCancellation = request.mode == .gear ? (request.id, cancellation) : nil
        let token = generation
        let phaseToken = phaseGeneration
        let gearToken = gearGeneration
        submittedGearGeneration = request.mode == .gear ? gearToken : nil
        let languages = languages, commandLogic = commandLogic
        metrics.submitted += 1
        if skipsCommandHeader {
            countCovered(inHack: inHack)
        } else if request.mode == .header || request.mode == .command {
            if inHack { metrics.headerInHackSubmitted += 1 } else { metrics.headerOutsideSubmitted += 1 }
            meter?.count(inHack ? .headerInHack : .headerOutside)
        }
        if request.mode == .result { metrics.resultSubmitted += 1 }
        if request.mode == .gear { metrics.gearSubmitted += 1 }
        if request.mode == .portal { metrics.portalSubmitted += 1 }
        lock.unlock()

        let headerOperation = readHeader, resultOperation = readResult, gearOperation = readGear
        let portalOperation = readPortal
        let started = ProcessInfo.processInfo.systemUptime
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if request.mode == .result, let resultContext, case .frame(let image)? = rendered {
                    let evidence = try resultOperation(image, resultContext, time)
                    self?.finish(request, header: nil, result: ResultRead(evidence: evidence,
                                 image: keepResultImage ? image : nil), session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if request.mode == .gear, let gearBounds, case .frame(let image)? = rendered {
                    let reading = try gearOperation(image, gearBounds, time, cancellation)
                    self?.countWithheld(reading.withheld)
                    self?.finish(request, header: nil, result: nil,
                                 gear: GearRead(evidence: reading.evidence, image: image,
                                                untitledPanel: reading.untitledPanel, passes: reading.passes),
                                 session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if request.mode == .portal, case .frame(let image)? = rendered {
                    let evidence = try portalOperation(image, time)
                    self?.finish(request, header: nil, result: nil, portal: evidence, session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if let commandFrame {
                    var header: HeaderReading?
                    if !skipsCommandHeader, let rendered { header = try await headerOperation(rendered, time) }
                    let read = (try? CommandNoticeReader.read(commandFrame, languages: languages, logic: commandLogic))
                        ?? .init(notice: nil, confidence: 0)
                    self?.finish(request, header: header, result: nil, command: (commandFrame, read), session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if !skipsCommandHeader, let rendered {
                    let header = try await headerOperation(rendered, time)
                    self?.finish(request, header: header, result: nil, session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else {
                    // A covered command read whose notice frame was gone:
                    // nothing to read, and the lane is released.
                    self?.finish(request, header: nil, result: nil, session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                }
            } catch {
                self?.finish(request, header: nil, result: nil, session: session,
                             generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: error.localizedDescription)
            }
        }
        return .read(request.mode)
    }

    /// The passes a finished gear read's cuts left out, for the Power section.
    private func countWithheld(_ withheld: GearReadWithheld) {
        guard let meter else { return }
        for (metric, count) in [(PowerMetric.gearRedRowSkipped, withheld.redRows),
                                (.gearEmptyCellSkipped, withheld.emptyCells),
                                (.gearQuantitySkipped, withheld.quantities),
                                (.gearLanguageSkipped, withheld.languageSweeps)] where count > 0 {
            meter.count(metric, UInt64(count))
        }
    }

    private func finish(_ request: GameTextSchedule.Request, header: HeaderReading?, result: ResultRead?,
                        gear: GearRead? = nil, portal: PortalScreenEvidence? = nil,
                        command: (CommandNoticeFrame, CommandNoticeReading)? = nil,
                        session: CaptureSessionID, generation token: Int,
                        phaseGeneration phaseToken: Int, gearGeneration gearToken: Int, started: Double, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        if gearCancellation?.id == request.id { gearCancellation = nil }
        // A read stopped for a new panel: its lane time is the cancel's
        // latency. Stopped, it delivers nothing and is no miss; finished in
        // full, it is delivered below like any other read.
        if let asked = gearCancelAsked, asked.id == request.id {
            gearCancelAsked = nil
            let latency = (ProcessInfo.processInfo.systemUptime - asked.uptime) * 1000
            let stopped = error != nil
            metrics.gearCancelLatencyMilliseconds = latency
            metrics.gearCancelTotalLatencyMilliseconds += latency
            metrics.gearCancelMaximumLatencyMilliseconds = max(metrics.gearCancelMaximumLatencyMilliseconds, latency)
            if stopped { metrics.gearCancelStopped += 1 } else { metrics.gearCancelFinished += 1 }
            if gearCancels.count < 64 {
                gearCancels.append(GearCancel(sourceTime: request.sourceTime, requestedAt: asked.frameTime,
                                              latencyMilliseconds: latency, stopped: stopped))
            }
            if stopped {
                schedule.finish(request)
                return
            }
        }
        let phaseRequest = request.mode == .header || request.mode == .command
        // Phase work belongs to its source-clock epoch, independently of panel
        // ownership. Never repair an OCR payload by giving it a newer timestamp.
        let valid = token == generation && (!phaseRequest || phaseToken == phaseGeneration)
            && (header.map { $0.sourceTime.isFinite && $0.sourceTime == request.sourceTime } ?? true)
            && (result == nil || result?.evidence.context == activeContext)
            && ((request.mode != .gear && request.mode != .portal) || gearToken == gearGeneration)
        let gearPanel = gear.map { $0.evidence.stage == .portal || $0.evidence.stage == .bonus } ?? false
        schedule.finish(request, panelPresent: valid && (result?.evidence.panelPresent == true || gearPanel),
                        untitledPanel: valid && gear?.untitledPanel == true)
        guard valid else { metrics.staleCompletions += 1; return }
        let latency = (ProcessInfo.processInfo.systemUptime - started) * 1000
        switch request.mode {
        case .result: metrics.resultLatencyMilliseconds = latency
        case .gear: metrics.gearLatencyMilliseconds = latency
        case .portal: metrics.portalLatencyMilliseconds = latency
        case .header, .command: metrics.lastLatencyMilliseconds = latency
        }
        if let error {
            if request.mode == .header || request.mode == .command { headerBaseline = nil; stillAnchor = nil }
            metrics.failed += 1
            switch request.mode {
            case .result: metrics.resultError = error
            case .gear: metrics.gearError = error
            case .portal: metrics.portalError = error
            case .header, .command: metrics.lastError = error
            }
            return
        }
        metrics.completed += 1
        switch request.mode {
        case .result: metrics.resultTotalLatencyMilliseconds += latency
        case .gear, .portal: break
        case .header, .command: metrics.totalLatencyMilliseconds += latency
        }
        if let command { commandRead = command }
        if let header {
            reading = header; readingSession = session; readingReused = false
            if stillAnchor?.requestID == request.id { stillAnchor?.reading = header }
        }
        if let result { resultRead = result; metrics.resultCompleted += 1 }
        if let gear { gearRead = gear; metrics.gearCompleted += 1 }
        if let portal { portalRead = portal; metrics.portalCompleted += 1 }
    }

    /// HeaderTextRecognizer's own crop, `headerRect`. Live capture
    /// supplies its slot-reader band; callers without one decode only the crop
    /// from the CGImage `image` gives, which a lazy frame declines. Failure is
    /// fail-open (always perform OCR).
    private func headerSignature(width: Int, height frameHeight: Int, topBand: FrameTopBand?,
                                 image: () -> CGImage?) -> HeaderSignature? {
        let rect = headerGeometry.headerRect(width: width, height: frameHeight)
        guard !rect.isEmpty, rect.minY >= 0, rect.maxY <= Double(frameHeight) else { return nil }
        let rows = Int(rect.minY)..<Int(rect.maxY)
        if let topBand, topBand.frameHeight == frameHeight, topBand.image.width == width,
           rows.upperBound <= topBand.image.height {
            let stride = width * 3
            return HeaderSignature(width: width, frameHeight: frameHeight, rows: rows,
                pixels: topBand.image.pixels[(rows.lowerBound * stride)..<(rows.upperBound * stride)])
        }
        guard let image = image(), let crop = try? ImageDecoder.decodeColor(image, in: rect) else { return nil }
        return HeaderSignature(width: width, frameHeight: frameHeight, rows: rows, pixels: crop.pixels[...])
    }

    /// The same crop as `headerSignature`, from the same sources, as the
    /// `headerStillSkip` cut's grid. Nil reads: a lazy frame is never
    /// rendered for it.
    private func headerStillSignature(width: Int, height frameHeight: Int, topBand: FrameTopBand?,
                                      image: () -> CGImage?) -> HeaderStillSignature? {
        let rect = headerGeometry.headerRect(width: width, height: frameHeight)
        guard !rect.isEmpty, rect.minY >= 0, rect.maxY <= Double(frameHeight) else { return nil }
        let rows = Int(rect.minY)..<Int(rect.maxY)
        if let topBand, topBand.frameHeight == frameHeight, topBand.image.width == width,
           rows.upperBound <= topBand.image.height {
            return HeaderStillSignature(rgb: topBand.image.pixels, width: width, rows: rows,
                                        frameWidth: width, frameHeight: frameHeight)
        }
        guard let image = image(), let crop = try? ImageDecoder.decodeColor(image, in: rect) else { return nil }
        return HeaderStillSignature(rgb: crop.pixels, width: crop.width, rows: 0..<crop.height,
                                    frameWidth: width, frameHeight: frameHeight)
    }

    /// The anchor's reading at `time`, when this frame's header is still
    /// against it; nil reads. With the lock held.
    ///
    /// The schedule asks only while the lane is free, so the anchor's read
    /// has always returned by then; one that returned nothing usable (a
    /// failure clears the anchor, a stale completion leaves it without a
    /// reading) reads again. Skipping without a reading instead would starve
    /// the tracker, which in a hack holds a phase only 0.75 s past its last
    /// header vote and reads a vote only 0.35 s old.
    ///
    /// With `masksHeaderWindow`, a header that is not still is compared again
    /// without the cells under the app's window, found in this frame by
    /// `window` and in the anchor's; `masked` says it was still only so.
    private func stillReading(_ signature: HeaderStillSignature?, at time: Double, session: CaptureSessionID,
                              language: GameLanguage, rows: Range<Int>,
                              window: () -> FloatingWindowFinder.Window?) -> (reading: HeaderReading, masked: Bool)? {
        guard let signature, let anchor = stillAnchor, let anchorReading = anchor.reading,
              anchor.session == session, anchor.language == language,
              time >= anchor.sourceTime, time - anchor.sourceTime < Self.maximumUnchangedAge else { return nil }
        if signature.isStill(comparedWith: anchor.signature) { return (anchorReading.at(sourceTime: time), false) }
        guard configuration.masksHeaderWindow, let anchorWindow = anchor.window, let window = window(),
              signature.isStill(comparedWith: anchor.signature, outside: window, otherWindow: anchorWindow,
                                rows: rows) else { return nil }
        return (anchorReading.at(sourceTime: time), true)
    }

    /// The frame rows `headerStillSignature` lays its grid over.
    private func headerRows(width: Int, height: Int) -> Range<Int> {
        let rect = headerGeometry.headerRect(width: width, height: height)
        guard !rect.isEmpty, rect.minY >= 0 else { return 0..<0 }
        return Int(rect.minY)..<Int(rect.maxY)
    }

    /// The `headerWindowMask` cut's window: the app's own, found in the
    /// engine's top band of a frame `width` by `height` when the band holds
    /// the header's rows. Nil without a band: a frame is never rendered to
    /// look for it.
    private func floatingWindow(width: Int, height: Int, topBand: FrameTopBand?) -> FloatingWindowFinder.Window? {
        let rect = headerGeometry.headerRect(width: width, height: height)
        guard let topBand, topBand.frameHeight == height, topBand.image.width == width,
              !rect.isEmpty, Int(rect.maxY) <= topBand.image.height else { return nil }
        return FloatingWindowFinder.find(in: topBand)
    }

    /// The `headerCoverSkip` cut's test: `window` lies over at least half
    /// of the rows of the header's rectangle in a frame `width` by
    /// `height`. Rows only: the window spans most of the width wherever it
    /// sits over the header, and the replay this follows measured rows.
    private func coversHeader(_ window: FloatingWindowFinder.Window?, width: Int, height: Int) -> Bool {
        let rows = headerRows(width: width, height: height)
        guard let window, !rows.isEmpty else { return false }
        let overlap = max(0, min(rows.upperBound, window.bottom) - max(rows.lowerBound, window.top))
        return 2 * overlap >= rows.count
    }

    /// One header read the `headerCoverSkip` cut left out. With the lock held.
    private func countCovered(inHack: Bool) {
        if inHack {
            metrics.headerSkippedCoveredInHack += 1; meter?.count(.headerCoveredInHack)
        } else {
            metrics.headerSkippedCoveredOutside += 1; meter?.count(.headerCoveredOutside)
        }
    }

    /// Whether the last reading issued again still holds the header's
    /// cadence at `time`, as the read it stood in for would have held the
    /// schedule's: the lane's spacing and, outside a hack, `headerInterval`,
    /// with the schedule's own tolerances. A still header is then answered at
    /// the frames a read would be, never more often: the tracker's votes, and
    /// with them the 0.75-s phase grace, fall where the reads' would. Such a
    /// look neither reads nor issues, whatever its pixels, as the schedule
    /// would not have offered it after a read. With the lock held.
    private func stillIssueHoldsCadence(at time: Double, session: CaptureSessionID, language: GameLanguage,
                                        minimumInterval: Double, headerInterval: Double?) -> Bool {
        guard let anchor = stillAnchor, let issued = anchor.issuedAt,
              anchor.session == session, anchor.language == language, time >= issued else { return false }
        return time - issued < minimumInterval || headerInterval.map { time - issued < $0 - 0.002 } ?? false
    }

    func takeCommand() -> (CommandNoticeFrame, CommandNoticeReading)? {
        lock.lock(); defer { lock.unlock() }
        let value = commandRead; commandRead = nil
        return value
    }

    func takeResult() -> ResultRead? {
        lock.lock()
        defer { lock.unlock() }
        let value = resultRead
        resultRead = nil
        return value
    }

    func takePortal() -> PortalScreenEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let value = portalRead
        portalRead = nil
        return value
    }

    /// The new-panel check for an analysed frame that `submit` doesn't see
    /// (gear-only capture submits only frames with a panel).
    func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        noteGearPanel(bounds, at: time)
    }

    /// With the lock held.
    private func noteGearPanel(_ bounds: GearDropPanelBounds?, at time: Double, previousPanelUnconfirmed: Bool = false) {
        guard let request = schedule.observeGearPanel(bounds, at: time,
                                                      previousPanelUnconfirmed: previousPanelUnconfirmed) else { return }
        metrics.gearCancelRequested += 1
        gearCancelAsked = (request.id, ProcessInfo.processInfo.systemUptime, time)
        if let running = gearCancellation, running.id == request.id { running.token.cancel() }
    }

    /// Gear reads stopped for a new panel since the last call, for the log.
    func takeGearCancels() -> [GearCancel] {
        lock.lock(); defer { lock.unlock() }
        let value = gearCancels; gearCancels = []
        return value
    }

    func takeGear() -> GearRead? {
        lock.lock()
        defer { lock.unlock() }
        let value = gearRead
        gearRead = nil
        return value
    }

    /// Include a completion waiting to be consumed: it can race takeGear().
    /// Invalidated requests still own the lane, but must never delay closure.
    var pendingGearSourceTime: Double? {
        lock.lock(); defer { lock.unlock() }
        if let gearRead { return gearRead.evidence.sourceTime }
        guard submittedGearGeneration == gearGeneration,
              let request = schedule.inFlight, request.mode == .gear else { return nil }
        return request.sourceTime
    }

    /// A read is running on the lane.
    var isReading: Bool {
        lock.lock(); defer { lock.unlock() }
        return schedule.inFlight != nil
    }

    func reading(for frameTime: Double, session: CaptureSessionID) -> HeaderReading? {
        issuedReading(for: frameTime, session: session)?.reading
    }

    /// A header reading, and whether it was issued again for a still header
    /// (`skipsStillHeaders`) rather than read from its frame.
    struct IssuedReading: Sendable, Equatable {
        let reading: HeaderReading
        let reused: Bool
    }

    /// The reading `reading(for:session:)` returns, with how it was issued,
    /// for the session log.
    func issuedReading(for frameTime: Double, session: CaptureSessionID) -> IssuedReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let reading, readingSession == session else { return nil }
        let age = frameTime - reading.sourceTime
        return age >= 0 && age <= configuration.maximumAge ? IssuedReading(reading: reading, reused: readingReused) : nil
    }

    /// The latest header reading of this session at any age, for evidence
    /// judged by its own source time. Phase invalidation clears it.
    func latestReading(session: CaptureSessionID) -> HeaderReading? {
        lock.lock()
        defer { lock.unlock() }
        return readingSession == session ? reading : nil
    }

    func snapshotMetrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        headerBaseline = nil; stillAnchor = nil
        submittedGearGeneration = nil
        activeContext = nil; reading = nil; readingSession = nil; readingReused = false
        resultRead = nil; gearRead = nil; portalRead = nil; commandRead = nil
        // Keep the old request in flight until it finishes: invalidation must
        // not permit two concurrent Vision requests or a late cache refill.
    }

    /// A source-clock discontinuity invalidates phase evidence only. Panel
    /// ownership and all cadence state survive; old work still owns the lane
    /// until its one completion releases it.
    func invalidatePhase() {
        lock.lock()
        defer { lock.unlock() }
        phaseGeneration += 1
        // Identical pixels and reused numeric times do not identify a clock
        // epoch. Its first eligible phase read must not inherit suppression.
        headerBaseline = nil; stillAnchor = nil
        reading = nil; readingSession = nil; readingReused = false; commandRead = nil
    }

    /// A capture gap invalidates only gear ownership; header and result work
    /// retain their existing scheduling and context checks.
    func invalidateGear() {
        lock.lock()
        defer { lock.unlock() }
        gearGeneration += 1
        gearRead = nil; portalRead = nil
        // The old request still owns the single OCR lane until completion.
    }
}
