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
        /// try the others on a confirmed screen they can't read.
        var languages = GameLanguageMemory(language: .english, isAutomatic: false)
        /// Asked at each gear read: off reads a panel in one pass, without
        /// row or other-language retries (Low Power Mode, a hot phone), except
        /// one reread of each row that pass left unparsed and, for a missing
        /// or unclear title, one title pass in one language family.
        var allowsGearRetries: @Sendable () -> Bool = { true }
    }

    struct Metrics: Sendable {
        var headerInHackSubmitted = 0
        var headerOutsideSubmitted = 0
        var headerSkippedUnchanged = 0
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
    }

    typealias HeaderOperation = @Sendable (CGImage, Double) async throws -> HeaderReading
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
    private let configuration: Configuration
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
    /// Two normal outside-hack intervals (0.5 s), one constrained interval
    /// (1 s). Never suppress a look at/after this age, even if pixels match.
    /// Quiet mode/no frames/busy panels can delay eligibility, not this gate.
    static let maximumUnchangedAge = 1.0
    /// Seconds between two reads of a gear panel; doubled when constrained,
    /// except between a read finding a panel and its rows being confirmed.
    static let gearInterval = 0.2
    private var headerBaseline: HeaderBaseline?
    private let lock = NSLock()
    private var schedule = GameTextSchedule()
    private var generation = 0
    private var phaseGeneration = 0
    private var gearGeneration = 0
    private var submittedGearGeneration: Int?
    private var activeContext: ResultReadContext?
    private var reading: HeaderReading?
    private var readingSession: CaptureSessionID?
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

    init(configuration: Configuration = Configuration(), headerOperation: HeaderOperation? = nil,
         resultOperation: ResultOperation? = nil, gearOperation: GearOperation? = nil,
         gearReadingOperation: GearReadingOperation? = nil,
         cancellableGearReadingOperation: CancellableGearReadingOperation? = nil,
         portalOperation: PortalOperation? = nil, meter: PowerMeter? = nil) {
        self.configuration = configuration
        self.meter = meter
        let layout = configuration.layout, languages = configuration.languages
        // The header follows the language the other screens found.
        readHeader = headerOperation ?? { image, time in
            try await HeaderTextRecognizer(layout: layout, language: languages.current).read(image, sourceTime: time)
        }
        readResult = resultOperation ?? { image, context, time in
            try ResultScreenReader.read(image, context: context, sourceTime: time, languages: languages)
        }
        let titleMemory = GearTitleLanguageMemory()
        let allowsGearRetries = configuration.allowsGearRetries
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
                                             rereadsUnreadableRows: true, cancellation: cancellation)
        }
        readPortal = portalOperation ?? { image, time in try PortalScreenReader().read(image, sourceTime: time) }
    }

    /// `gearBounds` is the drop panel found in this frame, or nil when gear
    /// reading is off or no panel shows. `headerPriority` keeps gear reads out
    /// of a presentation or input, when the header decides the phase.
    /// `readsHeader` off leaves the lane idle between panel reads.
    /// `headerInterval` slows header-only reads below the lane's cadence.
    /// `inHack` and current-frame `requiresFreshHeader` bypass content suppression
    /// without changing cadence or hack classification. `topBand` reuses the
    /// slot reader's decoded pixels. Only outside header-only reads can skip.
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
    func submit(_ image: CGImage, at time: Double, session: CaptureSessionID,
                resultContext: ResultReadContext? = nil, panelCandidate: Bool = false,
                keepResultImage: Bool = false, gearBounds: GearDropPanelBounds? = nil,
                headerPriority: Bool = false, portalCandidate: Bool = false,
                commands: CommandNoticeCapture? = nil, readsHeader: Bool = true,
                headerInterval: Double? = nil, constrained: Bool = false, gearPanelSettled: Bool = false,
                gearPanelUnconfirmed: Bool = false,
                inHack: Bool = true, requiresFreshHeader: Bool = false, topBand: FrameTopBand? = nil) {
        lock.lock()
        noteGearPanel(gearBounds, at: time, previousPanelUnconfirmed: gearPanelUnconfirmed)
        activeContext = resultContext
        if inHack || requiresFreshHeader { headerBaseline = nil }
        // A completion can race the consumer's takeResult() call. Keep that
        // source frame until it is drained rather than overwrite it next read.
        guard resultRead == nil, gearRead == nil, portalRead == nil, commandRead == nil else {
            metrics.droppedBusy += 1
            lock.unlock()
            return
        }
        let busy = schedule.inFlight != nil
        let language = configuration.languages.current
        var signature: HeaderSignature?
        // The schedule calls admission only for an eligible header-only look,
        // before reserving the shared lane. Comparison/counters stay locked.
        guard let request = schedule.take(at: time, panelCandidate: panelCandidate,
                                          resultEligible: resultContext != nil,
                                          minimumInterval: configuration.minimumInterval * (constrained ? 2 : 1),
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
            guard !inHack, !requiresFreshHeader, configuration.skipsUnchangedHeaders else { return true }
            signature = headerSignature(image, topBand: topBand)
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
            lock.unlock(); return
        }
        if request.mode == .header || request.mode == .command {
            // Store on admission, not completion: hack evidence or an
            // invalidation while OCR runs must not allow a late cache refill.
            headerBaseline = signature.map {
                HeaderBaseline(signature: $0, session: session, language: language, sourceTime: time)
            }
        }
        let commandFrame = request.mode == .command ? commands?.take(at: time) : nil
        let cancellation = GearReadCancellation()
        gearCancellation = request.mode == .gear ? (request.id, cancellation) : nil
        let token = generation
        let phaseToken = phaseGeneration
        let gearToken = gearGeneration
        submittedGearGeneration = request.mode == .gear ? gearToken : nil
        let languages = configuration.languages
        metrics.submitted += 1
        if request.mode == .header || request.mode == .command {
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
                if request.mode == .result, let resultContext {
                    let evidence = try resultOperation(image, resultContext, time)
                    self?.finish(request, header: nil, result: ResultRead(evidence: evidence,
                                 image: keepResultImage ? image : nil), session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if request.mode == .gear, let gearBounds {
                    let reading = try gearOperation(image, gearBounds, time, cancellation)
                    self?.finish(request, header: nil, result: nil,
                                 gear: GearRead(evidence: reading.evidence, image: image,
                                                untitledPanel: reading.untitledPanel, passes: reading.passes),
                                 session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if request.mode == .portal {
                    let evidence = try portalOperation(image, time)
                    self?.finish(request, header: nil, result: nil, portal: evidence, session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else if let commandFrame {
                    let header = try await headerOperation(image, time)
                    let read = (try? CommandNoticeReader.read(commandFrame, languages: languages))
                        ?? .init(notice: nil, confidence: 0)
                    self?.finish(request, header: header, result: nil, command: (commandFrame, read), session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                } else {
                    let header = try await headerOperation(image, time)
                    self?.finish(request, header: header, result: nil, session: session,
                                 generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: nil)
                }
            } catch {
                self?.finish(request, header: nil, result: nil, session: session,
                             generation: token, phaseGeneration: phaseToken, gearGeneration: gearToken, started: started, error: error.localizedDescription)
            }
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
            if request.mode == .header || request.mode == .command { headerBaseline = nil }
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
        if let header { reading = header; readingSession = session }
        if let result { resultRead = result; metrics.resultCompleted += 1 }
        if let gear { gearRead = gear; metrics.gearCompleted += 1 }
        if let portal { portalRead = portal; metrics.portalCompleted += 1 }
    }

    /// The same integral, full-width crop as HeaderTextRecognizer. Live capture
    /// supplies its slot-reader band; callers without one decode only the crop
    /// from their existing CGImage. Failure is fail-open (always perform OCR).
    private func headerSignature(_ image: CGImage, topBand: FrameTopBand?) -> HeaderSignature? {
        let layout = configuration.layout
        let height = Double(image.height)
        let rect = CGRect(x: 0, y: layout.headerTextTop * height, width: Double(image.width),
                          height: (layout.headerTextBottom - layout.headerTextTop) * height).integral
        guard !rect.isEmpty, rect.minY >= 0, rect.maxY <= height else { return nil }
        let rows = Int(rect.minY)..<Int(rect.maxY)
        if let topBand, topBand.frameHeight == image.height, topBand.image.width == image.width,
           rows.upperBound <= topBand.image.height {
            let stride = image.width * 3
            return HeaderSignature(width: image.width, frameHeight: image.height, rows: rows,
                pixels: topBand.image.pixels[(rows.lowerBound * stride)..<(rows.upperBound * stride)])
        }
        guard let crop = try? ImageDecoder.decodeColor(image, in: rect) else { return nil }
        return HeaderSignature(width: image.width, frameHeight: image.height, rows: rows,
                               pixels: crop.pixels[...])
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
        lock.lock()
        defer { lock.unlock() }
        guard let reading, readingSession == session else { return nil }
        let age = frameTime - reading.sourceTime
        return age >= 0 && age <= configuration.maximumAge ? reading : nil
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
        headerBaseline = nil
        submittedGearGeneration = nil
        activeContext = nil; reading = nil; readingSession = nil; resultRead = nil; gearRead = nil; portalRead = nil; commandRead = nil
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
        headerBaseline = nil
        reading = nil; readingSession = nil; commandRead = nil
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
