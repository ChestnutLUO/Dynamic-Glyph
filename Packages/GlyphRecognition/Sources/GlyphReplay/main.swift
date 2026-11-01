import CoreGraphics
import Foundation
import GlyphRecognition
import GlyphRecognitionImages

/// Replays a directory of captured frames through the whole live pipeline:
/// shape recognition, the slot-indicator reader, header text recognition and
/// the presentation tracker.
///
/// The point is that the boundaries come from the pixels. The expected
/// sequence passed with `--expect` is a manual annotation of what the screen
/// showed, and it is compared against, never fed in.
struct ReplayOptions {
    var glyphs: URL?
    var sequences: URL?
    var interval = 0.05
    var expected: [String] = []
    var expectedSlotCount: Int?
    var frames: [URL] = []
    var quiet = false
    var expectCorrectInput = false
    var timestamps: URL?
    var ablations: Set<Ablation> = []
    var probes: URL?
    var commandMode = "off"
    var gearMode = "off"
    /// Nil reads the game language automatically, starting from English.
    var gameLanguage: GameLanguage? = .english
    /// Recordings keep no unchanged frames, so a still screen looks like a
    /// hole in the timeline; only a longer hole is treated as a break.
    var gearGap = 5.0
    var resultMode = "live"
    var ocrLatency = 0.0
    var expectedBonuses: [Int] = []
    /// As the app with power saving on and the phone constrained (Low Power
    /// Mode, a serious or critical thermal state): frames analysed every
    /// 0.099 s outside a hack, the lane's and gear's spacings doubled with
    /// the panel pace until a panel's rows are confirmed, headers every 1 s
    /// outside a hack and 0.2 s in one, and gear reads without retries.
    var constrained = false
    /// How long a live gear read holds the lane (tool only): `flat` is
    /// `ocrLatency` for every read (build 102's replay, the default);
    /// `perPass` is `ocrLatency` x (1 + the read's title passes): its panel
    /// pass plus each title pass, panel-crop or title-zone fallback, so a
    /// constrained read with both title passes costs 3 x `ocrLatency`; row and
    /// quantity rereads are not charged, as in `flat`. `measured` is the sum
    /// of the read's own measured pass times (panel, title, row, quantity) on
    /// this machine, ignoring `ocrLatency`.
    var titlePassCost = "flat"
    /// Title-pass cost sweep (tool only; both nil = unchanged behaviour).
    /// `extraTitleSeconds` X: a live gear read holds the lane `ocrLatency`
    /// exactly as `flat`, plus X for every title pass beyond the read's first
    /// (constrained reads: the title-zone fallback pass; unconstrained reads:
    /// each further family's pass). `titleSeconds` X: `ocrLatency` plus X for
    /// every title pass, the first included. Only with `titlePassCost` flat;
    /// at most one of the two.
    var extraTitleSeconds: Double?
    var titleSeconds: Double?
    /// The gear lane's new-panel rules (build 103, the default): a new panel
    /// (`GameTextSchedule.observeGearPanel`) stops the gear read in flight,
    /// which frees the lane `cancelLatency` later (or at its own completion,
    /// if sooner) and delivers nothing; the new panel's first read has no
    /// spacing; constrained analysis is every 0.049 s while a panel shows.
    /// "102" replays build 102's lane, for comparison.
    var gearLane = "103"
    var cancelLatency = 0.05
}

func parseArguments() throws -> ReplayOptions {
    var options = ReplayOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--commands":
            guard !arguments.isEmpty else { throw ReplayError.usage("--commands needs off, live, or exhaustive") }
            options.commandMode = arguments.removeFirst()
            guard ["off", "live", "exhaustive"].contains(options.commandMode) else { throw ReplayError.usage("invalid commands mode") }
        case "--game-language":
            guard !arguments.isEmpty else { throw ReplayError.usage("--game-language needs auto or a language code") }
            let value = arguments.removeFirst()
            if value == "auto" { options.gameLanguage = nil }
            else if let language = GameLanguage(rawValue: value) { options.gameLanguage = language }
            else { throw ReplayError.usage("--game-language needs auto, en, zh-Hans, zh-Hant, ja or ko") }
        case "--gear":
            guard !arguments.isEmpty else { throw ReplayError.usage("--gear needs off, live, exhaustive, or only") }
            options.gearMode = arguments.removeFirst()
            guard ["off", "live", "exhaustive", "only"].contains(options.gearMode) else { throw ReplayError.usage("invalid gear mode") }
        case "--gear-gap":
            guard !arguments.isEmpty, let gap = Double(arguments.removeFirst()), gap > 0, gap.isFinite else { throw ReplayError.usage("invalid gear gap") }
            options.gearGap = gap
        case "--frames-manifest":
            guard !arguments.isEmpty else { throw ReplayError.usage("--frames-manifest needs a JSON file") }
            let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments.removeFirst())))
            options.frames += paths.map { URL(fileURLWithPath: $0) }
        case "--results":
            guard !arguments.isEmpty else { throw ReplayError.usage("--results needs off, live, or exhaustive") }
            options.resultMode = arguments.removeFirst()
            guard ["off", "live", "exhaustive"].contains(options.resultMode) else { throw ReplayError.usage("invalid result mode") }
        case "--constrained":
            options.constrained = true
        case "--title-pass-cost":
            guard !arguments.isEmpty else { throw ReplayError.usage("--title-pass-cost needs flat, perPass or measured") }
            options.titlePassCost = arguments.removeFirst()
            guard ["flat", "perPass", "measured"].contains(options.titlePassCost) else {
                throw ReplayError.usage("--title-pass-cost needs flat, perPass or measured")
            }
        case "--extra-title-seconds", "--title-seconds":
            guard !arguments.isEmpty, let seconds = Double(arguments.removeFirst()), seconds >= 0, seconds.isFinite else {
                throw ReplayError.usage("\(argument) needs a number of seconds, 0 or more")
            }
            if argument == "--extra-title-seconds" { options.extraTitleSeconds = seconds } else { options.titleSeconds = seconds }
        case "--gear-lane":
            guard !arguments.isEmpty else { throw ReplayError.usage("--gear-lane needs 103 or 102") }
            options.gearLane = arguments.removeFirst()
            guard ["103", "102"].contains(options.gearLane) else { throw ReplayError.usage("--gear-lane needs 103 or 102") }
        case "--cancel-latency":
            guard !arguments.isEmpty, let latency = Double(arguments.removeFirst()), latency >= 0, latency.isFinite else {
                throw ReplayError.usage("--cancel-latency needs a number of seconds, 0 or more")
            }
            options.cancelLatency = latency
        case "--ocr-latency":
            guard !arguments.isEmpty, let latency = Double(arguments.removeFirst()), latency >= 0, latency.isFinite else { throw ReplayError.usage("invalid OCR latency") }
            options.ocrLatency = latency
        case "--expect-bonuses":
            guard !arguments.isEmpty else { throw ReplayError.usage("--expect-bonuses needs hacking,speed") }
            options.expectedBonuses = arguments.removeFirst().split(separator: ",").compactMap { Int($0) }
            guard options.expectedBonuses.count == 2 else { throw ReplayError.usage("expected two bonuses") }
        case "--glyphs":
            options.glyphs = URL(fileURLWithPath: arguments.removeFirst())
        case "--sequences":
            options.sequences = URL(fileURLWithPath: arguments.removeFirst())
        case "--interval":
            options.interval = Double(arguments.removeFirst()) ?? 0.05
        case "--expect":
            options.expected = arguments.removeFirst().split(separator: ",").map(String.init)
        case "--expect-slots":
            options.expectedSlotCount = Int(arguments.removeFirst())
        case "--expect-correct-input":
            options.expectCorrectInput = true
        case "--quiet":
            options.quiet = true
        case "--timestamps":
            guard !arguments.isEmpty else {
                throw NSError(domain: "GlyphReplay", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "--timestamps requires a JSON file of frame times"])
            }
            options.timestamps = URL(fileURLWithPath: arguments.removeFirst())
        case "--ablate":
            guard !arguments.isEmpty else { throw ReplayError.usage("--ablate requires a list of components") }
            options.ablations = try Ablation.parse(arguments.removeFirst())
        case "--probes":
            guard !arguments.isEmpty else { throw ReplayError.usage("--probes requires a JSON file of times") }
            options.probes = URL(fileURLWithPath: arguments.removeFirst())
        default:
            options.frames.append(URL(fileURLWithPath: argument))
        }
    }
    if options.extraTitleSeconds != nil, options.titleSeconds != nil {
        throw ReplayError.usage("--extra-title-seconds and --title-seconds are exclusive")
    }
    if options.extraTitleSeconds != nil || options.titleSeconds != nil, options.titlePassCost != "flat" {
        throw ReplayError.usage("--extra-title-seconds and --title-seconds need --title-pass-cost flat (the default)")
    }
    return options
}

let options: ReplayOptions
do {
    options = try parseArguments()
} catch let error as ReplayError {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
guard let glyphsURL = options.glyphs, !options.frames.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: glyph-replay --glyphs <glyph_line.csv> [--sequences <glyph.csv>]
                        [--interval 0.05] [--expect a,b,c] [--expect-slots n]
                        [--timestamps <seconds.json>] [--probes <seconds.json>]
                        [--results live|exhaustive|off] [--ocr-latency seconds] [--constrained]
                        [--title-pass-cost flat|perPass|measured]
                        [--extra-title-seconds seconds | --title-seconds seconds]
                        [--gear-lane 103|102] [--cancel-latency seconds]
                        [--game-language auto|en|zh-Hans|zh-Hant|ja|ko] [--commands off|live|exhaustive] [--gear off|live|exhaustive|only] [--gear-gap seconds] [--frames-manifest paths.json]
                        [--expect-bonuses hacking,speed]
                        [--ablate a,b,...] [--expect-correct-input] [--quiet] <frame.png> ...

    Frames must be in capture order. Every frame goes through the same
    recognition, slot-indicator and header-text code the app runs, less any
    component named in --ablate: \(Ablation.allCases.map(\.rawValue).joined(separator: ", ")).
    --probes records the tracker's state as it stood at each given time.
    --results live shares the bounded header/result OCR lane (default).
    exhaustive reads every candidate; off retains legacy per-frame header OCR.
    --ocr-latency simulates completion delay on the source timeline in live mode.
    --constrained replays the app's power-constrained path (power saving on, Low
    Power Mode or a hot phone): analysis cadence, lane and gear pacing, and
    gear reads without retries. Analysis never rests or goes quiet here.
    --title-pass-cost charges a live gear read's lane time: flat (--ocr-latency,
    the default), perPass (--ocr-latency x (1 + title passes); row and quantity
    rereads uncharged), or measured (the sum of the read's measured OCR pass
    times on this machine).
    --extra-title-seconds X (title-pass cost sweep; flat only): a live gear read
    holds the lane --ocr-latency, exactly as flat, plus X seconds for every
    title pass beyond the read's first, i.e. --ocr-latency + X x max(0, title
    passes - 1). In a constrained read that is the title-zone fallback pass
    (at most one); in an unconstrained read each further family's pass.
    --title-seconds X (flat only): --ocr-latency + X x title passes, the first
    title pass included (the conservative model). Absent: flat, unchanged.
    The two are exclusive; neither works with perPass or measured. Header,
    result and command reads are unaffected. gearSampling reports both
    values (null when absent), titlePasses, extraTitlePasses (passes beyond
    each read's first) and chargedGearSeconds.
    --gear-lane 103 (default) replays build 103's gear lane: a new panel
    (geometry, GameTextSchedule.observeGearPanel) stops the gear read in
    flight, which delivers nothing and frees the lane --cancel-latency seconds
    later (default 0.05) or at its own completion if sooner; the new panel's
    first read has no spacing; with --constrained, analysis is every 0.049 s
    while the last analysed frame showed a panel. 102 replays build 102's lane.
    gearSampling reports gearLane, cancelLatency, gearCancels and
    gearPanelFrameTimes (analysed frames with panel geometry; times only).

    """.utf8))
    exit(2)
}

/// Availability is checked once, around the whole run: text recognition needs
/// macOS 15, while the recognition core itself still supports older systems and
/// the package's declared minimum is left alone.
@available(macOS 15.0, iOS 18.0, *)
func replay(_ options: ReplayOptions, glyphsURL: URL) async throws {
    let table = try GlyphTable.parse(csv: String(contentsOf: glyphsURL, encoding: .utf8))
    let predictor = try options.sequences.map {
        SequencePredictor(table: try SequenceTable.parse(csv: String(contentsOf: $0, encoding: .utf8)))
    }
    let layout = GameUILayout()
    let slotReader = SlotStripReader(layout: layout)
    let languages = GameLanguageMemory(language: options.gameLanguage ?? .english, isAutomatic: options.gameLanguage == nil)
    // The header follows the language found on other screens.
    var headerRecognizer: HeaderTextRecognizer { HeaderTextRecognizer(layout: layout, language: languages.current) }
    let sessionID = CaptureSessionID(rawValue: 1)
    let sourceTimes = try options.timestamps.map {
        try JSONDecoder().decode([Double].self, from: Data(contentsOf: $0))
    }
    if let sourceTimes {
        guard sourceTimes.count == options.frames.count,
              sourceTimes.allSatisfy({ $0.isFinite }),
              zip(sourceTimes, sourceTimes.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw NSError(domain: "GlyphReplay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "timestamps must be finite, increasing, and match the frame count"])
        }
    }

    let probeTimes = try options.probes.map {
        try JSONDecoder().decode([Double].self, from: Data(contentsOf: $0)).sorted()
    } ?? []
    guard probeTimes.allSatisfy(\.isFinite) else {
        throw ReplayError.usage("probe times must be finite")
    }
    let ablations = options.ablations
    let shapeAblator = ShapeAblator(ablations: ablations)
    let freshFitRecognizer = GlyphFrameRecognizer(table: table)

    var session = GlyphFrameSession(table: table)
    var tracker = PresentationTracker(sessionID: sessionID, policy: Ablation.policy(for: ablations))
    var validator = PlayerInputValidator(table: table, sessionID: sessionID)
    var resultSession = ResultObservationSession()
    let commands = CommandNoticeCapture()
    var commandScreen = CommandScreenWatch()
    var pendingCommand: (CommandNoticeFrame, CommandNoticeReading)?
    var commandReadings: [[String: Any]] = []
    func acceptCommand(_ frame: CommandNoticeFrame, _ read: CommandNoticeReading) {
        commands.accept(read, frame: frame)
        commandReadings.append(["sourceTime": frame.sourceTime, "noticeID": frame.id,
                                "notice": read.notice?.rawValue ?? "unreadable",
                                "confidence": read.confidence, "language": read.language ?? "unknown"])
    }
    var textSchedule = GameTextSchedule()
    let gearReader = GearDropScreenReader()
    let gearTitleMemory = GearTitleLanguageMemory()
    var gearTracker = GearDropTracker()
    var gearSession = GearDropObservationSession()
    var gearReadings: [GearDropFrameEvidence] = []
    var gearGroups: [GearDropSummary] = []
    func acceptGear(_ evidence: GearDropFrameEvidence) {
        gearReadings.append(evidence)
        if let closed = gearTracker.accept(evidence) { gearGroups.append(gearSession.close(closed)) }
    }
    // What the pending gear read says beyond its evidence, and each read's
    // OCR passes (counts and confidences only), as the app's session log has.
    var pendingUntitledPanel = false
    var gearReadPasses: [[String: Any]] = []
    // The pending gear read's lane time (`titlePassCost`).
    var pendingGearLatency = options.ocrLatency
    // Build 103's lane: the frame time a new panel stopped the pending gear
    // read at, and every such stop (times only).
    let lane103 = options.gearLane == "103"
    var pendingCancelledAt: Double?
    var gearCancels: [[String: Any]] = []
    var lastAnalysedShowedGear = false
    // Source times of analysed frames that showed panel geometry: frame work
    // per hack, for either lane (times only).
    var gearPanelFrameTimes: [Double] = []
    var titlePassCount = 0, chargedGearSeconds = 0.0, extraTitlePassCount = 0
    func readGear(_ image: CGImage, bounds: GearDropPanelBounds, at time: Double) throws -> GearDropFrameEvidence {
        let reading = try GearDropScreenReader.reading(image, bounds: bounds, sourceTime: time, titleMemory: gearTitleMemory,
                                                       languages: languages, retries: !options.constrained,
                                                       rereadsUnreadableRows: true)
        pendingUntitledPanel = reading.untitledPanel
        let titlePasses = reading.passes.filter { $0.purpose == .title }.count
        titlePassCount += titlePasses
        switch options.titlePassCost {
        case "perPass": pendingGearLatency = options.ocrLatency * Double(1 + titlePasses)
        case "measured": pendingGearLatency = reading.passes.reduce(0) { $0 + $1.milliseconds } / 1000
        default:
            pendingGearLatency = options.ocrLatency
            if let extra = options.extraTitleSeconds {
                pendingGearLatency += extra * Double(max(0, titlePasses - 1))
            } else if let each = options.titleSeconds {
                pendingGearLatency += each * Double(titlePasses)
            }
        }
        extraTitlePassCount += max(0, titlePasses - 1)
        chargedGearSeconds += pendingGearLatency
        gearReadPasses.append(["sourceTime": time, "untitledPanel": reading.untitledPanel,
                               "chargedSeconds": pendingGearLatency,
                               "passes": reading.passes.map(\.logRow)])
        return reading.evidence
    }
    // The app's constrained spacings (GameHeaderReader): doubled, except the
    // panel pace while a found panel's rows are still unconfirmed.
    let laneInterval = options.constrained ? 0.2 : 0.1, gearInterval = options.constrained ? 0.4 : 0.2
    func gearPanelPace() -> GameTextSchedule.Pace? {
        options.constrained && !gearTracker.currentPanelSettled
            ? .init(minimumInterval: 0.1, gearInterval: 0.2) : nil
    }
    func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    var cachedHeader: HeaderReading?
    var pending: (GameTextSchedule.Request, HeaderReading?, ResultFrameEvidence?, GearDropFrameEvidence?,
                  PortalScreenEvidence?)?
    // The portal screen before each hack, for its level; read with gear.
    let portalReader = PortalScreenReader()
    var portalObserver = PortalLevelObserver()
    var portalScreens: [Int: PortalScreenEvidence] = [:]
    var glyphCounts: [Int: Int] = [:]
    var portalReadings: [PortalScreenEvidence] = []
    var resultReadings: [[String: Any]] = []
    var resultSummaries: [[String: Any]] = []
    var ocrCounts: [String: Int] = [:]
    func summary(_ result: HackResult, comparison: ValidatorResultComparison?) -> [String: Any] {
        var row = result.diagnosticRow
        row["commands"] = result.context.commands.flatMap { try? encoded($0) }
        row["comparisons"] = comparison?.compare(result).map(\.diagnosticRow) ?? []
        row["supersededAttemptIDs"] = comparison?.supersededAttemptIDs.sorted() ?? []
        return row
    }
    func consumePending(at time: Double) {
        guard let ready = pending else { return }
        var done = ready.0.sourceTime + (ready.0.mode == .gear ? pendingGearLatency : options.ocrLatency)
        if let cancelledAt = pendingCancelledAt { done = min(done, cancelledAt + options.cancelLatency) }
        guard time + 1e-9 >= done else { return }
        if let cancelledAt = pendingCancelledAt {
            // Stopped for a new panel: no evidence, no miss; the lane is free.
            pendingCancelledAt = nil
            gearCancels.append(["sourceTime": ready.0.sourceTime, "requestedAt": cancelledAt, "freedAt": done])
            textSchedule.finish(ready.0)
            pendingUntitledPanel = false
            pending = nil
            return
        }
        textSchedule.finish(ready.0, panelPresent: ready.2?.panelPresent == true || ready.3?.stage == .portal || ready.3?.stage == .bonus,
                            untitledPanel: ready.0.mode == .gear && pendingUntitledPanel)
        pendingUntitledPanel = false
        if let value = ready.1 { cachedHeader = value }
        if let value = ready.2 {
            resultSession.accept(value)
            resultReadings.append(value.diagnosticRow)
        }
        if let value = ready.3 { acceptGear(value) }
        if let value = ready.4 { portalObserver.accept(value); portalReadings.append(value) }
        if let (frame, read) = pendingCommand { acceptCommand(frame, read); pendingCommand = nil }
        pending = nil
    }
    var inputEvents: [[String: Any]] = []
    var inputResults: [InputCheckResult] = []
    var probes: [[String: Any]] = []
    var lastTimerVisible = false
    func probe(at probeTime: Double, frameTime: Double?) -> [String: Any] {
        func outlook(_ observed: [GlyphID], _ length: Int?) -> [String: Any] {
            let result = predictor?.outlook(observed: observed, expectedLength: length) ?? .unavailable
            return ["state": result.state.rawValue, "candidates": result.candidateCount,
                    "predictedSuffix": result.predictedSuffix.map(\.name)]
        }
        let prefix = tracker.confirmedPrefix
        let time = frameTime ?? 0
        let snapshot = GlyphDisplaySnapshot(captureSessionID: sessionID, hackID: tracker.hackID,
            revision: tracker.revision, liveness: .live, state: tracker.state,
            phaseSource: tracker.phaseSource, acceptance: .trackingSequence,
            sourceFrameTime: time, evidenceArrivalUptime: time,
            expectedSlotCount: tracker.expectedSlotCount, slots: tracker.slots,
            currentSlotIndex: tracker.currentSlotIndex, inputSlotIndex: tracker.inputSlotIndex,
            inputSlotObservedTime: tracker.lastIndicatorTime,
            indicatorsObstructed: tracker.indicatorsObstructed,
            slotCountConflict: tracker.slotCountConflict, isFrozen: tracker.isFrozen,
            provisionalGlyph: nil, provisionalExtensionCount: 0,
            outlook: predictor?.outlook(observed: prefix, expectedLength: tracker.expectedSlotCount) ?? .unavailable,
            calibrationSummary: "replay")
        let guidance = snapshot.upcomingGuidance()
        return [
            "probeTime": probeTime,
            "frameTime": frameTime ?? NSNull(),
            "hackID": tracker.hackID,
            "trackingState": tracker.state.rawValue,
            "phaseSource": tracker.phaseSource.rawValue,
            "inputTimerVisible": lastTimerVisible,
            "inputSlotIndex": tracker.inputSlotIndex ?? NSNull(),
            "guidanceFirstSlotIndex": guidance?.firstSlotIndex ?? NSNull(),
            "guidanceGlyphs": guidance?.styles.map { $0.glyph?.name ?? "?" } ?? [],
            "expectedSlotCount": tracker.expectedSlotCount ?? NSNull(),
            "slots": tracker.slots.map { slot -> [String: Any] in
                ["index": slot.index, "status": slot.status.rawValue, "glyph": slot.glyph?.name ?? NSNull(),
                 "alternatives": slot.alternatives.map(\.name)]
            },
            "confirmedPrefix": prefix.map(\.name),
            // How early the table would have answered, one confirmed Glyph at a time.
            "prefixOutlooks": prefix.indices.map { end -> [String: Any] in
                let observed = Array(prefix[...end])
                return ["observed": observed.count,
                        "withSlotCount": outlook(observed, tracker.expectedSlotCount),
                        "withoutSlotCount": outlook(observed, nil)]
            }
        ]
    }
    var lastFrameTime: Double?
    var events: [TrackingEvent] = []
    var headerCounts: [String: Int] = [:]
    var slotRejections: [String: Int] = [:]
    var phaseSources: [String: Int] = [:]
    var obstructedFrames = 0
    // As the app without Glyph assistance: panels only, no Glyph hack followed.
    let gearOnly = options.gearMode == "only"
    // Constrained analysis cadence, as LiveGlyphOutput: a 20-Hz look, then the
    // pace's interval, the full one only inside a hack.
    var lastLooked = -Double.infinity, lastSample = -Double.infinity
    /// Build 103's new-panel check, on every analysed frame before `take`.
    func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double) {
        guard lane103, let request = textSchedule.observeGearPanel(bounds, at: time,
                  previousPanelUnconfirmed: gearTracker.isObserving && !gearTracker.currentPanelSettled),
              pending?.0 == request else { return }
        pendingCancelledAt = time
    }
    func inHack(at time: Double) -> Bool {
        let phaseAge = time - (tracker.lastPhaseTime ?? -.infinity)
        return tracker.state == .presenting || tracker.state == .input || tracker.state == .command
            || commandScreen.watching
            || tracker.state == .interrupted && phaseAge.isFinite && phaseAge >= 0 && phaseAge < 5
    }
    var analysedFrames = 0

    for (index, url) in options.frames.enumerated() {
        let time = sourceTimes?[index] ?? Double(index) * options.interval
        if options.constrained {
            let policy = AnalysisRateController.Policy()
            guard time < lastLooked || time - lastLooked >= policy.activeInterval else { continue }
            lastLooked = time
            // Build 103: the full rate while a gear panel shows (rejected
            // candidates are not modelled).
            let interval = (!gearOnly && inHack(at: time)) || (lane103 && lastAnalysedShowedGear)
                ? policy.activeInterval : policy.constrainedActiveInterval
            guard time < lastSample || time - lastSample >= interval else { continue }
            lastSample = time
        }
        analysedFrames += 1
        let gearGap = lastFrameTime.map { time - $0 > options.gearGap } ?? false
        if options.gearMode != "off", gearSession.prepareFrame(at: time, continuityLost: gearGap) {
            // Match live invalidation before draining a pre-gap OCR result.
            if let request = pending?.0, request.mode == .gear {
                textSchedule.finish(request)
                pending = nil; pendingUntitledPanel = false; pendingCancelledAt = nil
            }
            if let closed = gearTracker.loseContinuity(at: time) {
                gearGroups.append(gearSession.close(closed))
            }
        }
        while probes.count < probeTimes.count, probeTimes[probes.count] < time {
            probes.append(probe(at: probeTimes[probes.count], frameTime: lastFrameTime))
        }
        lastFrameTime = time
        let data = try Data(contentsOf: url)
        guard let image = ImageDecoder.cgImage(from: data) else {
            FileHandle.standardError.write(Data("cannot decode \(url.lastPathComponent)\n".utf8))
            continue
        }
        if gearOnly {
            consumePending(at: time)
            let gearBounds = try gearReader.bounds(in: image)
            lastAnalysedShowedGear = gearBounds != nil
            if gearBounds != nil { gearPanelFrameTimes.append(time) }
            if let closed = gearTracker.observe(at: time, panelCandidate: gearBounds != nil,
                                                pendingReadSourceTime: pending?.3?.sourceTime) {
                gearGroups.append(gearSession.close(closed))
            }
            observeGearPanel(gearBounds, at: time)
            if let gearBounds, let request = textSchedule.take(at: time, panelCandidate: false, resultEligible: false,
                                                               minimumInterval: laneInterval,
                                                               gearCandidate: true, readsHeader: false,
                                                               gearInterval: gearInterval, gearPanelPace: gearPanelPace()) {
                ocrCounts[request.mode.rawValue, default: 0] += 1
                pending = (request, nil, nil, try readGear(image, bounds: gearBounds, at: time), nil)
                consumePending(at: time)
            }
            gearSession.observe(at: time, hackID: 0, inputVisible: false, gameProgressVisible: gearBounds != nil)
            continue
        }
        if options.commandMode != "off" {
            // As live: a gap may hide a notice, so it makes commands uncertain.
            if gearGap { commands.interrupt(at: time); commandScreen.stop() }
            if commandScreen.watching, let band = image.cropping(to: CommandNoticeDetector.band(width: image.width, height: image.height)) {
                try commands.observe(band: band, at: time)
            }
            if options.commandMode == "exhaustive" {
                while let frame = commands.take(at: time) { acceptCommand(frame, try CommandNoticeReader.read(frame, languages: languages)) }
            }
        }
        let luminance = try ImageDecoder.decode(image)
        let observation = ablations.contains(.calibrationCache)
            ? freshFitRecognizer.calibrateAndObserve(luminance)
            : session.observe(luminance, at: time)

        var slots: SlotStripReading?
        var rejection: SlotStripRejection?
        var timerVisible = false
        let band = try? ImageDecoder.topBand(image, layout: layout)
        if let band {
            timerVisible = !ablations.contains(.timer) && slotReader.hasTimerBar(band)
        }
        if let band, !ablations.contains(.strip) {
            switch slotReader.read(band) {
            case .success(let reading): slots = Ablation.reading(reading, under: ablations)
            case .failure(let failure):
                rejection = failure
                slotRejections[failure.rawValue, default: 0] += 1
            }
        }
        let panelCandidate = ResultPanelDetector().isCandidate(luminance)
        consumePending(at: time)
        let gearBounds = options.gearMode == "off" ? nil : try gearReader.bounds(in: image)
        lastAnalysedShowedGear = gearBounds != nil
        if gearBounds != nil { gearPanelFrameTimes.append(time) }
        let portalCandidate = try options.gearMode != "off" && portalReader.isCandidate(image)
        if options.gearMode != "off" {
            if let closed = gearTracker.observe(at: time, panelCandidate: gearBounds != nil,
                                                pendingReadSourceTime: pending?.3?.sourceTime) {
                gearGroups.append(gearSession.close(closed))
            }
            if options.gearMode == "exhaustive", let gearBounds {
                acceptGear(try GearDropScreenReader.read(image, bounds: gearBounds, sourceTime: time, titleMemory: gearTitleMemory,
                                                   languages: languages, retries: !options.constrained,
                                                   rereadsUnreadableRows: true))
            }
            if options.gearMode == "exhaustive", portalCandidate {
                let screen = try portalReader.read(image, sourceTime: time)
                portalObserver.accept(screen); portalReadings.append(screen)
            }
        }
        var header: HeaderReading?
        if options.resultMode == "off" && options.gearMode != "live" && options.commandMode != "live" {
            if !ablations.contains(.header) { header = try await headerRecognizer.read(image, sourceTime: time) }
        } else if options.resultMode == "exhaustive" && options.gearMode != "live" && options.commandMode != "live" {
            if !ablations.contains(.header) { header = try await headerRecognizer.read(image, sourceTime: time) }
            if panelCandidate, let context = resultSession.context {
                let result = try ResultScreenReader.read(image, context: context, sourceTime: time, languages: languages)
                resultSession.accept(result); resultReadings.append(result.diagnosticRow)
            }
        } else {
            // Constrained, as the app with power saving: headers every 1 s
            // outside a hack and 0.2 s in one (AnalysisRateController).
            let headerInterval = options.constrained
                ? AnalysisRateController.headerInterval(mode: .active, inHack: inHack(at: time), constrained: true) : nil
            if options.gearMode == "live" { observeGearPanel(gearBounds, at: time) }
            if let request = textSchedule.take(at: time, panelCandidate: panelCandidate,
                                               resultEligible: options.resultMode != "off" && resultSession.context != nil,
                                               minimumInterval: laneInterval,
                                               gearCandidate: options.gearMode == "live" && gearBounds != nil,
                                               headerPriority: tracker.state == .presenting || tracker.state == .input,
                                               portalCandidate: options.gearMode == "live" && portalCandidate,
                                               commandCandidate: options.commandMode == "live" && !commands.queue.isEmpty
                                                   && tracker.state != .presenting && tracker.state != .input,
                                               headerInterval: headerInterval,
                                               gearInterval: gearInterval, gearPanelPace: gearPanelPace()) {
                ocrCounts[request.mode.rawValue, default: 0] += 1
                if request.mode == .result, let context = resultSession.context {
                    pending = (request, nil, try ResultScreenReader.read(image, context: context, sourceTime: time, languages: languages), nil, nil)
                } else if request.mode == .gear, let gearBounds {
                    pending = (request, nil, nil, try readGear(image, bounds: gearBounds, at: time), nil)
                } else if request.mode == .portal {
                    pending = (request, nil, nil, nil, try portalReader.read(image, sourceTime: time))
                } else {
                    if request.mode == .command, let frame = commands.take(at: time) {
                        pendingCommand = (frame, try CommandNoticeReader.read(frame, languages: languages))
                    }
                    pending = (request, ablations.contains(.header) ? nil : try await headerRecognizer.read(image, sourceTime: time), nil, nil, nil)
                }
                consumePending(at: time)
            }
            if let cachedHeader, time - cachedHeader.sourceTime <= 0.35 { header = cachedHeader }
        }
        if let header { headerCounts[header.phase.rawValue, default: 0] += 1 }

        let layoutConsistent = ablations.contains(.layoutCheck)
            || (observation?.calibration.map(layout.isConsistent) ?? false)
        let evidence = FrameEvidence(
            sessionID: sessionID, time: time, header: header, slots: slots, slotRejection: rejection,
            shape: observation.map(shapeAblator.evidence) ?? .unavailable,
            hasValidCalibration: observation?.calibration != nil && layoutConsistent,
            hasInputTimerBar: timerVisible)
        let produced = tracker.accept(evidence)
        if options.commandMode != "off" {
            for event in produced where event.kind == .hackStarted { commands.bind(hackID: event.hackID) }
            switch commandScreen.observe(at: time, calibrated: evidence.hasValidCalibration,
                                         commandPhase: !evidence.hasInputTimerBar
                                            && tracker.state != .presenting && tracker.state != .input,
                                         complete: true) {
            case .interrupt: commands.interrupt(at: time)
            case .cancel: commands.cancel()
            case .none: break
            }
            if !evidence.hasValidCalibration { try commands.observeMode(in: image, at: time) }
        }
        if options.gearMode != "off" {
            for event in produced where event.kind == .hackStarted {
                if let screen = portalObserver.claim(at: event.time) { portalScreens[event.hackID] = screen }
            }
            if tracker.state == .input, tracker.hackID > 0, let count = tracker.expectedSlotCount, count > 0 {
                glyphCounts[tracker.hackID] = count
            }
            gearSession.observe(at: time, hackID: tracker.hackID,
                inputVisible: timerVisible || slots?.highlightedIndex != nil,
                gameProgressVisible: panelCandidate || gearBounds != nil, inputPhase: tracker.state)
            if let result = resultSession.tracker?.result { gearSession.accept(result) }
        }
        lastTimerVisible = timerVisible
        let oldComparison = resultSession.comparison
        if let retired = resultSession.observe(evidence, presentation: tracker, panelCandidate: panelCandidate,
                                               commands: options.commandMode == "off" ? nil : commands.summary(hackID: tracker.hackID)) {
            resultSummaries.append(summary(retired, comparison: oldComparison))
        }
        let checks = validator.accept(evidence, tracker: tracker, edgeEvidence: observation?.evidence ?? [])
        resultSession.accept(checks)
        inputEvents += checks.map(\.diagnosticRow)
        for check in checks {
            guard let result = check.result else { continue }
            // A verdict shown while the window is open is reported again,
            // possibly withdrawn, when the window ends. Count each attempt once.
            if check.kind == .finished { inputResults.append(result) }
            if !options.quiet {
                print("input slot \(result.slotIndex + 1) \(check.kind.rawValue): \(result.verdict.rawValue) \(result.reason?.rawValue ?? "")")
            }
        }
        events += produced
        phaseSources[tracker.phaseSource.rawValue, default: 0] += 1
        if tracker.indicatorsObstructed { obstructedFrames += 1 }
        if !options.quiet {
            for event in produced {
                let slot = event.slotIndex.map { " slot \($0 + 1)" } ?? ""
                let glyph = event.glyph.map { " \($0.name)" } ?? ""
                print(String(format: "%7.3f  %-22@%@%@  %@", time, event.kind.rawValue as NSString,
                             slot, glyph, event.reason))
            }
        }
    }

    consumePending(at: lastFrameTime ?? 0)
    if options.gearMode != "off" {
        if let closed = gearTracker.finish(at: lastFrameTime ?? 0, reason: "endOfStream") {
            gearGroups.append(gearSession.close(closed))
        }
        gearSession.invalidate(at: lastFrameTime ?? 0, reason: "endOfStream")
    }
    let finalChecks = validator.finish(at: lastFrameTime ?? 0)
    resultSession.accept(finalChecks)
    resultSession.finish(at: lastFrameTime ?? 0, reason: "endOfStream")
    if let result = resultSession.tracker?.result { resultSummaries.append(summary(result, comparison: resultSession.comparison)) }
    inputEvents += finalChecks.map(\.diagnosticRow)
    inputResults += finalChecks.filter { $0.kind == .finished }.compactMap(\.result)

    while probes.count < probeTimes.count {
        probes.append(probe(at: probeTimes[probes.count], frameTime: lastFrameTime))
    }

    let observed = tracker.slots.map { $0.glyph?.name }
    let outlook = predictor?.outlook(observed: tracker.confirmedPrefix,
                                     expectedLength: tracker.expectedSlotCount) ?? .unavailable
    var report: [String: Any] = [
        "resultSampling": ["mode": options.resultMode, "simulatedLatency": options.ocrLatency, "requests": ocrCounts],
        "resultReadings": resultReadings, "results": resultSummaries,
        "inputChecks": inputResults.map(\.diagnosticRow),
        "inputEvents": inputEvents,
        "inputSummary": [
            "matched": inputResults.filter { $0.verdict == .matched }.count,
            "differs": inputResults.filter { $0.verdict == .differs }.count,
            "unavailable": inputResults.filter { $0.verdict == .unavailable }.count,
            "unavailableReasons": Dictionary(grouping: inputResults.compactMap { $0.reason?.rawValue }, by: { $0 }).mapValues(\.count)
        ],
        "frames": options.frames.count,
        "trackingState": tracker.state.rawValue,
        "hacks": tracker.hackID,
        "expectedSlotCount": tracker.expectedSlotCount ?? -1,
        "slots": tracker.slots.map { slot -> [String: Any] in
            var row: [String: Any] = ["index": slot.index, "status": slot.status.rawValue,
                                      "samples": slot.sampleCount]
            if let glyph = slot.glyph { row["glyph"] = glyph.name }
            if !slot.alternatives.isEmpty { row["alternatives"] = slot.alternatives.map(\.name) }
            if let reason = slot.boundaryReason { row["boundaryReason"] = reason }
            return row
        },
        "confirmedPrefix": tracker.confirmedPrefix.map(\.name),
        "prediction": ["state": outlook.state.rawValue, "candidates": outlook.candidateCount,
                       "predictedSuffix": outlook.predictedSuffix.map(\.name)],
        "headerPhases": headerCounts,
        "phaseSources": phaseSources, "commandReadings": commandReadings,
        "gameLanguage": languages.current.rawValue,
        "indicatorsObstructedFrames": obstructedFrames,
        "usesSourceTimestamps": sourceTimes != nil,
        "slotRejections": slotRejections,
        "commits": events.filter { $0.kind == .slotCommitted }.count,
        "inferredEntries": events.filter { $0.kind == .slotInferred }.count,
        "ablations": ablations.map(\.rawValue).sorted(),
        "probes": probes,
        "events": events.map { event -> [String: Any] in
            ["time": event.time, "kind": event.kind.rawValue, "hackID": event.hackID,
             "slotIndex": event.slotIndex ?? NSNull(), "glyph": event.glyph?.name ?? NSNull(),
             "reason": event.reason]
        }
    ]

    if options.gearMode != "off" {
        report["gearSampling"] = ["mode": options.gearMode, "simulatedLatency": options.ocrLatency,
                                  "constrained": options.constrained, "analysedFrames": analysedFrames,
                                  "titlePassCost": options.titlePassCost, "titlePasses": titlePassCount,
                                  "chargedGearSeconds": chargedGearSeconds,
                                  "extraTitleSeconds": options.extraTitleSeconds ?? NSNull(),
                                  "titleSeconds": options.titleSeconds ?? NSNull(),
                                  "extraTitlePasses": extraTitlePassCount,
                                  "gearLane": options.gearLane, "cancelLatency": options.cancelLatency,
                                  "gearCancels": gearCancels, "gearPanelFrameTimes": gearPanelFrameTimes]
        report["gearReadPasses"] = gearReadPasses
        report["gearGroups"] = try gearGroups.map { group -> [String: Any] in
            guard var row = try encoded(group) as? [String: Any] else {
                throw NSError(domain: "GlyphReplay", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "a gear group did not encode as a JSON object"])
            }
            row["recognizedQuantity"] = group.recognizedQuantity
            row["unidentifiedQuantity"] = group.unidentifiedQuantity
            row["bothPanelsRead"] = group.bothPanelsRead
            return row
        }
        report["gearReadings"] = try encoded(gearReadings)
        report["gearEvents"] = try encoded(gearSession.events)
        report["portalReadings"] = try encoded(portalReadings)
        report["portalLevels"] = try Set(portalScreens.keys).union(glyphCounts.keys).sorted().compactMap { hack -> [String: Any]? in
            // As live when commands are read; without them, as before.
            let settled = options.commandMode == "off" || commands.summary(hackID: hack).settlesGlyphCount
            guard let estimate = PortalLevelRules.estimate(screen: portalScreens[hack], glyphCount: glyphCounts[hack],
                                                           glyphCountSettled: settled),
                  var row = try encoded(estimate) as? [String: Any] else { return nil }
            row["hackID"] = hack
            return row
        }
    }
    var failures: [String] = []
    if !options.expectedBonuses.isEmpty {
        let result = resultSession.tracker?.result
        if result?.finalHackingBonus != options.expectedBonuses[0] || result?.finalSpeedBonus != options.expectedBonuses[1] {
            failures.append("final bonuses do not match annotation")
        }
    }
    if options.expectCorrectInput, inputResults.isEmpty {
        failures.append("correct-input baseline produced no input checks")
    }
    if options.expectCorrectInput, inputResults.contains(where: { $0.verdict == .differs }) {
        failures.append("correct-input baseline produced a differs verdict")
    }
    if !options.expected.isEmpty {
        let actual = observed.map { $0 ?? "?" }
        if actual != options.expected {
            failures.append("sequence: expected \(options.expected.joined(separator: ",")), "
                            + "got \(actual.joined(separator: ","))")
        }
    }
    if let expectedSlots = options.expectedSlotCount, tracker.expectedSlotCount != expectedSlots {
        failures.append("slot count: expected \(expectedSlots), got "
                        + (tracker.expectedSlotCount.map(String.init) ?? "unknown"))
    }
    report["failures"] = failures

    let json = try JSONSerialization.data(withJSONObject: report,
                                          options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: json, as: UTF8.self))
    exit(failures.isEmpty ? 0 : 1)
}

if #available(macOS 15.0, iOS 18.0, *) {
    try await replay(options, glyphsURL: glyphsURL)
} else {
    FileHandle.standardError.write(Data("glyph-replay needs macOS 15 or later for text recognition\n".utf8))
    exit(3)
}
