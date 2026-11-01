import Foundation
import os
import GlyphRecognition
import GlyphRecognitionImages

/// What the Power section of the Diagnostics page counts and times.
enum PowerMetric: Int, CaseIterable {
    // Frames
    case framesDelivered, framesAnalysed, backlogDropped
    // Shared by the broadcast extension through the frame ring's header, and
    // the app's own losses reading it.
    case extensionPublished, extensionDropped, extensionOverwritten, ringLost
    // Vision text requests, timed where they are performed.
    case headerFast, headerAccurate, resultPanel, commandNotice, droneFooter, gearPanel, portalScreen
    // Steps of frame analysis.
    case frameWork, conversion, decode, gearCheck, portalCheck, resultCheck, gridHunt, glyphRead
    case slotStrip, commandBand, footerProbe, recordingOffer
    // Added after the steps so the raw values above keep their order.
    case droneFooterFast
    /// A delivered frame's handling before its analysis begins, and the
    /// whole handling of a frame that is not analysed: facts, the telemetry
    /// row's hand-off, the throttle, the gate's read and the recorders' offer.
    case frameIntake, skippedFrame
    /// The floating window: each 15-Hz tick of its render loop, and the
    /// redraws within them.
    case pipTick, pipDraw
    /// On the main actor: an analysed frame's update of the displays, the
    /// Live Activity's share of it, and the session log's per-frame row.
    case displayUpdate, liveActivity, telemetryRow
    /// Header OCR submissions (including a command's header), and eligible
    /// header-only looks suppressed for unchanged pixels. Counts, not timers.
    case headerInHack, headerOutside, headerUnchanged

    init(_ kind: TextReadKind) {
        switch kind {
        case .headerFast: self = .headerFast
        case .headerAccurate: self = .headerAccurate
        case .resultPanel: self = .resultPanel
        case .commandNotice: self = .commandNotice
        case .droneFooter: self = .droneFooter
        case .droneFooterFast: self = .droneFooterFast
        case .gearPanel: self = .gearPanel
        case .portalScreen: self = .portalScreen
        }
    }

    static let headerWork: [PowerMetric] = [.headerInHack, .headerOutside, .headerUnchanged]
    static let textReads: [PowerMetric] = [.headerFast, .headerAccurate, .resultPanel, .commandNotice,
                                           .droneFooterFast, .droneFooter, .gearPanel, .portalScreen]
    static let steps: [PowerMetric] = [.frameWork, .conversion, .decode, .gearCheck, .portalCheck, .resultCheck,
                                       .gridHunt, .glyphRead, .slotStrip, .commandBand, .footerProbe, .recordingOffer,
                                       .frameIntake, .skippedFrame, .displayUpdate, .liveActivity, .telemetryRow,
                                       .pipTick, .pipDraw]
    /// Timed work that never runs inside another timed run, so their times
    /// add up without counting anything twice: the rest of the CPU time is
    /// untimed. Text reads run on their own tasks; every other step runs
    /// inside one of these.
    static let topLevel: [PowerMetric] = textReads + [.frameWork, .frameIntake, .skippedFrame, .displayUpdate,
                                                      .telemetryRow, .pipTick]

    /// Raw labels, like the rest of the page: not localized.
    var label: String {
        switch self {
        case .headerInHack: return "header hack"
        case .headerOutside: return "header out"
        case .headerUnchanged: return "hdr skipped"
        case .framesDelivered: return "delivered"
        case .framesAnalysed: return "analysed"
        case .backlogDropped: return "backlog drop"
        case .extensionPublished: return "ext sent"
        case .extensionDropped: return "ext dropped"
        case .extensionOverwritten: return "overwritten"
        case .ringLost: return "ring lost"
        case .headerFast: return "header fast"
        case .headerAccurate: return "header acc."
        case .resultPanel: return "result"
        case .commandNotice: return "command"
        case .droneFooter: return "drone foot."
        case .droneFooterFast: return "drone fast"
        case .gearPanel: return "gear panel"
        case .portalScreen: return "portal"
        case .frameWork: return "whole frame"
        case .conversion: return "CI->CG"
        case .decode: return "luminance"
        case .gearCheck: return "gear check"
        case .portalCheck: return "portal chk"
        case .resultCheck: return "result chk"
        case .gridHunt: return "grid hunt"
        case .glyphRead: return "Glyph read"
        case .slotStrip: return "slot strip"
        case .commandBand: return "cmd band"
        case .footerProbe: return "footer prb"
        case .recordingOffer: return "rec offer"
        case .frameIntake: return "frame intake"
        case .skippedFrame: return "skipped frm"
        case .pipTick: return "PiP tick"
        case .pipDraw: return "PiP draw"
        case .displayUpdate: return "UI update"
        case .liveActivity: return "Live Act."
        case .telemetryRow: return "log row"
        }
    }
}

/// A count with the time it took, in nanoseconds.
struct PowerTally: Equatable, Sendable {
    var count: UInt64 = 0
    var nanoseconds: UInt64 = 0
    var maxNanoseconds: UInt64 = 0
    /// When the longest run ended, on the meter's clock; 0 before any.
    var maxAt: UInt64 = 0

    mutating func add(count: UInt64, nanoseconds: UInt64, at time: UInt64) {
        self.count &+= count
        self.nanoseconds &+= nanoseconds
        if nanoseconds > maxNanoseconds { maxNanoseconds = nanoseconds; maxAt = time }
    }

    mutating func merge(_ other: PowerTally) {
        count &+= other.count
        nanoseconds &+= other.nanoseconds
        if other.maxNanoseconds > maxNanoseconds { maxNanoseconds = other.maxNanoseconds; maxAt = other.maxAt }
    }

    var averageMilliseconds: Double? { count > 0 ? Double(nanoseconds) / Double(count) / 1e6 : nil }
    var maxMilliseconds: Double? { count > 0 ? Double(maxNanoseconds) / 1e6 : nil }
}

/// Session totals and a rolling window of one-second buckets for a fixed set
/// of metrics. All storage is allocated up front: recording never allocates.
struct PowerWindow: Sendable {
    static let seconds = 60
    let metrics: Int
    private(set) var totals: [PowerTally]
    private var buckets: [PowerTally]
    /// The second each bucket slot holds, or `Int64.min` for none yet.
    private var stamps: [Int64]

    init(metrics: Int) {
        self.metrics = metrics
        totals = Array(repeating: PowerTally(), count: metrics)
        buckets = Array(repeating: PowerTally(), count: metrics * Self.seconds)
        stamps = Array(repeating: Int64.min, count: Self.seconds)
    }

    static func slot(_ second: Int64) -> Int { Int(((second % Int64(seconds)) + Int64(seconds)) % Int64(seconds)) }

    /// `time` is when the run ended, on the meter's clock; by default the
    /// start of `second`.
    mutating func record(_ metric: Int, count: UInt64 = 1, nanoseconds: UInt64 = 0, second: Int64,
                         at time: UInt64? = nil) {
        let time = time ?? UInt64(max(0, second)) &* 1_000_000_000
        totals[metric].add(count: count, nanoseconds: nanoseconds, at: time)
        let slot = Self.slot(second)
        if stamps[slot] != second {
            // The slot holds a newer second: this record came too late for
            // the window, though it still counts in the totals.
            guard stamps[slot] < second else { return }
            stamps[slot] = second
            for index in slot * metrics..<(slot + 1) * metrics { buckets[index] = PowerTally() }
        }
        buckets[slot * metrics + metric].add(count: count, nanoseconds: nanoseconds, at: time)
    }

    /// One second's own count, or zero when the window holds none for it.
    func count(_ metric: Int, second: Int64) -> UInt64 {
        let slot = Self.slot(second)
        return stamps[slot] == second ? buckets[slot * metrics + metric].count : 0
    }

    /// The last `seconds` seconds up to and including `now`'s.
    func recent(_ metric: Int, second now: Int64) -> PowerTally {
        var tally = PowerTally()
        let oldest = now - Int64(Self.seconds)
        for slot in 0..<Self.seconds where stamps[slot] <= now && stamps[slot] > oldest {
            tally.merge(buckets[slot * metrics + metric])
        }
        return tally
    }

    /// Seconds the window covers at `now`, in nanoseconds of uptime, never
    /// reaching back before `start`.
    static func span(now: UInt64, start: UInt64) -> Double {
        let second = Int64(now / 1_000_000_000)
        let windowStart = UInt64(max(0, second - Int64(seconds) + 1)) * 1_000_000_000
        let from = max(start, windowStart)
        return now > from ? Double(now - from) / 1e9 : 0
    }

    /// A count over `span` seconds as a rate per minute; nil under a second.
    static func perMinute(_ count: UInt64, span: Double) -> Double? {
        span >= 1 ? Double(count) * 60 / span : nil
    }
}

/// The first sample of an ever-growing value, such as CPU time, in each of
/// the last `PowerWindow.seconds` seconds, for its rate over that window.
struct CumulativeWindow: Sendable {
    private struct Sample: Sendable { var second: Int64 = .min; var time: UInt64 = 0; var value: UInt64 = 0 }
    private var samples = Array(repeating: Sample(), count: PowerWindow.seconds)

    mutating func note(_ value: UInt64, at time: UInt64) {
        let second = Int64(time / 1_000_000_000)
        let slot = PowerWindow.slot(second)
        guard samples[slot].second < second else { return }
        samples[slot] = Sample(second: second, time: time, value: value)
    }

    /// Growth per nanosecond since the oldest sample in the window; nil
    /// without one at least a second old.
    func rate(_ value: UInt64, at time: UInt64) -> Double? {
        let now = Int64(time / 1_000_000_000)
        var oldest: Sample?
        for sample in samples where sample.second <= now && sample.second > now - Int64(PowerWindow.seconds) {
            if sample.time < oldest?.time ?? .max { oldest = sample }
        }
        guard let oldest, time >= oldest.time + 1_000_000_000, value >= oldest.value else { return nil }
        return Double(value - oldest.value) / Double(time - oldest.time)
    }
}

/// How long the analysis gate kept each pace, in the frames' own seconds.
/// Each 20-Hz look's mode holds until the next look; a gap is credited to the
/// mode before it, at most `maximumGap`, so a paused capture is not counted
/// as time in any mode. A step back in time (a new stream) only restarts the
/// clock. Without power saving every look is `active`.
struct AnalysisModeClock: Equatable, Sendable {
    static let maximumGap = 2.0
    static let modes: [AnalysisRateController.Mode] = [.quiet, .resting, .active]
    private var totals: [Double] = [0, 0, 0]
    private var last: (time: Double, index: Int)?

    static func index(_ mode: AnalysisRateController.Mode) -> Int {
        switch mode {
        case .quiet: return 0
        case .resting: return 1
        case .active: return 2
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.totals == rhs.totals && lhs.last?.time == rhs.last?.time && lhs.last?.index == rhs.last?.index
    }

    mutating func note(_ mode: AnalysisRateController.Mode, at time: Double) {
        guard time.isFinite else { return }
        if let last, time >= last.time {
            totals[last.index] += min(time - last.time, Self.maximumGap)
        }
        last = (time, Self.index(mode))
    }

    func seconds(_ mode: AnalysisRateController.Mode) -> Double { totals[Self.index(mode)] }
    var total: Double { totals.reduce(0, +) }
    /// Share of the counted time, 0...100; nil before any time was counted.
    func percent(_ mode: AnalysisRateController.Mode) -> Double? {
        total > 0 ? seconds(mode) / total * 100 : nil
    }
}

/// Raw inputs to the gate, not mutually exclusive causes. Dark and dim
/// candidates never keep the full pace: they only choose resting over quiet.
/// A candidate entry is the one full look at a screen that just became a
/// candidate. Gear bounds keep the pace; rejected gear bounds (reads keep
/// finding no panel) do not. Array fit, slots, timer and command notice are
/// the hack-screen evidence. Panel/slot cues are from the last analyzed frame
/// and therefore deliberately survive a still-screen tick. No text or pixels
/// are retained. Keep this separate from the controller: diagnostics cannot pace it.
enum AnalysisGateReason: Int, CaseIterable, Sendable {
    case darkCandidate, dimCandidate, candidateEntry, screenSwitch, noPixels, savingOff
    case resultPanel, gearPanel, gearRejected, portalPanel, calibration, slots, timer, commandNotice
    case resultContext, gearGroup, gearObserver
    case commandWatch, command, presenting, input, interrupted

    var label: String {
        switch self {
        case .darkCandidate: return "dark cand."
        case .dimCandidate: return "dim cand."
        case .candidateEntry: return "cand. entry"
        case .screenSwitch: return "scr. switch"
        case .noPixels: return "no pixels"
        case .savingOff: return "saving off"
        case .resultPanel: return "result pnl"
        case .gearPanel: return "gear bounds"
        case .gearRejected: return "gear reject"
        case .portalPanel: return "portal cand"
        case .calibration: return "array fit"
        case .slots: return "slot strip"
        case .timer: return "input timer"
        case .commandNotice: return "cmd notice"
        case .resultContext: return "result ctx"
        case .gearGroup: return "gear group"
        case .gearObserver: return "gear watch"
        case .commandWatch: return "cmd watch"
        case .command: return "phase cmd"
        case .presenting: return "phase glyph"
        case .input: return "phase input"
        case .interrupted: return "phase grace"
        }
    }
}

struct AnalysisGateReasons: OptionSet, Equatable, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(_ reason: AnalysisGateReason) { rawValue = 1 << reason.rawValue }
    func has(_ reason: AnalysisGateReason) -> Bool { contains(Self(reason)) }
    mutating func set(_ reason: AnalysisGateReason, _ present: Bool) {
        if present { insert(Self(reason)) } else { remove(Self(reason)) }
    }
}

/// Fixed-size scalar counters, on the same source clock and gap rules as the
/// mode split. Input seconds overlap; they are not percentages of CPU work.
/// Samples count actual analysis, not gate looks or the tint's rate cap.
struct AnalysisGateOccupancy: Sendable {
    private(set) var looks: UInt64 = 0
    private(set) var stillLooks: UInt64 = 0
    private(set) var current = AnalysisGateReasons()
    private(set) var seconds = Array(repeating: 0.0, count: AnalysisGateReason.allCases.count)
    private(set) var counts = Array(repeating: UInt64(0), count: AnalysisGateReason.allCases.count)
    private(set) var samples = [UInt64](repeating: 0, count: 3)
    private var lastTime: Double?
    private(set) var dark: Double?
    private(set) var bright: Double?
    private(set) var minimumDark = 1.0, maximumDark = 0.0
    private(set) var minimumBright = 1.0, maximumBright = 0.0

    mutating func note(_ reasons: AnalysisGateReasons, at time: Double, still: Bool,
                       gate: LumaGateReading?) {
        guard time.isFinite else { return }
        if let lastTime, time >= lastTime {
            let span = min(time - lastTime, AnalysisModeClock.maximumGap)
            for reason in AnalysisGateReason.allCases where current.has(reason) { seconds[reason.rawValue] += span }
        }
        lastTime = time
        current = reasons
        looks &+= 1
        if still { stillLooks &+= 1 }
        for reason in AnalysisGateReason.allCases where reasons.has(reason) { counts[reason.rawValue] &+= 1 }
        if let gate {
            dark = gate.darkFraction; bright = gate.brightFraction
            minimumDark = min(minimumDark, gate.darkFraction); maximumDark = max(maximumDark, gate.darkFraction)
            minimumBright = min(minimumBright, gate.brightFraction); maximumBright = max(maximumBright, gate.brightFraction)
        }
    }

    mutating func analyzed(_ mode: AnalysisRateController.Mode) { samples[AnalysisModeClock.index(mode)] &+= 1 }
}

/// What the Power section shows, read at once.
struct PowerSnapshot {
    var hasSession = false
    /// Stopped: the figures are those at Stop.
    var ended = false
    /// Seconds since the session began, and the seconds the window covers.
    var elapsed = 0.0
    var span = 0.0
    /// The session's start on the meter's clock, for when maximums happened.
    var startedAt: UInt64 = 0
    var totalTallies: [PowerTally] = Array(repeating: PowerTally(), count: PowerMetric.allCases.count)
    var recentTallies: [PowerTally] = Array(repeating: PowerTally(), count: PowerMetric.allCases.count)
    var cpuSeconds = 0.0
    /// Of one core, over the window.
    var cpuPercentRecent: Double?
    var thermal = 0
    var worstThermal = 0
    var lowPower = false
    var queueDepth = 0
    var maxQueueDepth = 0
    /// Frames that may wait: the old backlog's 40, or 1 when only the
    /// newest frame waits (power saving).
    var queueCapacity = 0
    var usesQueue = false
    var extensionSeen = false
    var modes = AnalysisModeClock()
    var gateOccupancy = AnalysisGateOccupancy()
    /// The gate's pace at its latest look, and frames analysed in the last
    /// whole second, the measured rate beside it.
    var readingMode: ReadingMode?
    var analysedLastSecond: UInt64 = 0
    var language: GameLanguage?
    var languageAutomatic = false
    var languageConfirmed = false

    func total(_ metric: PowerMetric) -> PowerTally { totalTallies[metric.rawValue] }
    func recent(_ metric: PowerMetric) -> PowerTally { recentTallies[metric.rawValue] }
    func perMinute(_ metric: PowerMetric) -> Double? { PowerWindow.perMinute(recent(metric).count, span: span) }
    /// Seconds into the session when the metric's longest run ended; nil
    /// before any timed run.
    func maxAt(_ metric: PowerMetric) -> Double? {
        let tally = total(metric)
        guard tally.maxNanoseconds > 0 else { return nil }
        return tally.maxAt > startedAt ? Double(tally.maxAt - startedAt) / 1e9 : 0
    }
    /// Seconds of the session's timed work that never overlaps other timed
    /// work.
    var timedSeconds: Double {
        Double(PowerMetric.topLevel.reduce(UInt64(0)) { $0 &+ total($1).nanoseconds }) / 1e9
    }
}

/// Counts and times where the phone's power goes during a capture session:
/// frames, text reads, analysis steps, the process's CPU time and the
/// thermal state. Measurement only. Recording is a clock read and an
/// uncontended `os_unfair_lock`, with no allocation and no logging; CPU time
/// and the thermal state are sampled at most once a second.
final class PowerMeter: @unchecked Sendable {
    static let shared = PowerMeter()

    private struct ExtensionCounts: Equatable {
        var published: UInt64, dropped: UInt64, overwritten: UInt64, lost: UInt64
    }

    private struct State {
        var window = PowerWindow(metrics: PowerMetric.allCases.count)
        var cpu = CumulativeWindow()
        var hasSession = false
        var startedAt: UInt64 = 0
        var cpuAtStart: UInt64 = 0
        /// Set by `end()`: the session's figures stay as they were at Stop.
        var endedAt: UInt64?
        var cpuAtEnd: UInt64 = 0
        var lastSecond = Int64.min
        var queueDepth = 0
        var maxQueueDepth = 0
        var queueCapacity = 0
        var usesQueue = false
        var modes = AnalysisModeClock()
        var gateOccupancy = AnalysisGateOccupancy()
        var readingMode: ReadingMode?
        var extensionSeen = false
        /// The ring's counts at the last look. Nil after a reset or a new
        /// reader: the next look only sets it, so a session counts only what
        /// came after it.
        var extensionBaseline: ExtensionCounts?
        var worstThermal = 0
        var languages: GameLanguageMemory?
    }

    // Guarded by `lock`. The clock, CPU and thermal readers are immutable.
    private var state = State()
    private let lock: os_unfair_lock_t
    private let clock: () -> UInt64
    private let cpuTime: () -> UInt64
    private let thermalState: () -> Int

    init(clock: @escaping () -> UInt64 = PowerMeter.uptimeNanoseconds,
         cpuTime: @escaping () -> UInt64 = PowerMeter.processCPUNanoseconds,
         thermalState: @escaping () -> Int = { ProcessInfo.processInfo.thermalState.rawValue }) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        self.clock = clock
        self.cpuTime = cpuTime
        self.thermalState = thermalState
        state.startedAt = clock()
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    static func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// User and system time of every thread of this process, ended ones
    /// included. The broadcast extension is a process of its own.
    static func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func nanoseconds(_ time: timeval) -> UInt64 {
            UInt64(max(0, time.tv_sec)) * 1_000_000_000 + UInt64(max(0, time.tv_usec)) * 1_000
        }
        return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
    }

    /// Sends Vision's text requests here. Once, at launch.
    func observeTextReads() {
        TextReadProbe.setObserver { [weak self] kind, nanoseconds in
            self?.record(PowerMetric(kind), nanoseconds: nanoseconds)
        }
    }

    /// A capture session begins: everything counts from now. `languages` is
    /// the session's game language, which the text readers follow. Work that
    /// began before now, such as a text read still running, is not counted.
    func reset(languages: GameLanguageMemory? = nil) {
        let time = clock(), cpu = cpuTime(), thermal = thermalState()
        os_unfair_lock_lock(lock)
        state = State()
        state.hasSession = true
        state.startedAt = time
        state.cpuAtStart = cpu
        state.worstThermal = thermal
        state.languages = languages
        state.lastSecond = Int64(time / 1_000_000_000)
        state.cpu.note(cpu, at: time)
        os_unfair_lock_unlock(lock)
    }

    /// The session stopped: its figures stay as they were now, and nothing
    /// is counted until the next reset.
    func end() {
        let time = clock(), cpu = cpuTime()
        os_unfair_lock_lock(lock)
        if state.endedAt == nil {
            state.cpu.note(cpu, at: time)
            state.endedAt = time
            state.cpuAtEnd = cpu
        }
        os_unfair_lock_unlock(lock)
    }

    /// The frame ring's reader was replaced, and its own counts with it.
    func restartExtensionCounts() {
        os_unfair_lock_lock(lock)
        state.extensionBaseline = nil
        os_unfair_lock_unlock(lock)
    }

    // MARK: Recording

    @inline(__always)
    func now() -> UInt64 { clock() }

    func count(_ metric: PowerMetric, _ count: UInt64 = 1) {
        add(metric, count: count, nanoseconds: 0, at: clock())
    }

    /// One run of `metric` that began at `started`, a `now()` reading.
    func finish(_ metric: PowerMetric, since started: UInt64) {
        let end = clock()
        add(metric, count: 1, nanoseconds: end &- started, at: end)
    }

    /// One run of `metric` that just ended and took `nanoseconds`.
    func record(_ metric: PowerMetric, nanoseconds: UInt64) {
        add(metric, count: 1, nanoseconds: nanoseconds, at: clock())
    }

    /// Frames waiting for recognition, of at most `capacity`.
    func setQueueDepth(_ depth: Int, capacity: Int = 40) {
        os_unfair_lock_lock(lock)
        state.usesQueue = true
        state.queueCapacity = capacity
        state.queueDepth = depth
        state.maxQueueDepth = max(state.maxQueueDepth, depth)
        os_unfair_lock_unlock(lock)
    }

    /// The analysis gate's pace for the frame at `time` (presentation
    /// seconds), for the time split, and as it is now (`current`), for the
    /// readout. Once per 20-Hz look.
    func noteAnalysisMode(_ mode: AnalysisRateController.Mode, at time: Double, current: ReadingMode? = nil,
                          reasons: AnalysisGateReasons = [], still: Bool = false, gate: LumaGateReading? = nil) {
        os_unfair_lock_lock(lock)
        if state.endedAt == nil, state.hasSession {
            state.modes.note(mode, at: time)
            state.gateOccupancy.note(reasons, at: time, still: still, gate: gate)
            if let current { state.readingMode = current }
        }
        os_unfair_lock_unlock(lock)
    }

    /// Called at the actual analysis throttle, never for a still-screen look.
    func noteAnalysisSample(_ mode: AnalysisRateController.Mode) {
        os_unfair_lock_lock(lock)
        if state.endedAt == nil, state.hasSession { state.gateOccupancy.analyzed(mode) }
        os_unfair_lock_unlock(lock)
    }

    /// The frame ring's running counts. Each is counted by how much it grew
    /// since the last call; a count that went down started over. The first
    /// call of a session or of a new reader only takes the baseline.
    func noteExtension(published: UInt64, dropped: UInt64, overwritten: UInt64, lost: UInt64) {
        let time = clock()
        let second = Int64(time / 1_000_000_000)
        let current = ExtensionCounts(published: published, dropped: dropped, overwritten: overwritten, lost: lost)
        os_unfair_lock_lock(lock)
        guard state.endedAt == nil else { os_unfair_lock_unlock(lock); return }
        let previous = state.extensionBaseline
        state.extensionBaseline = current
        state.extensionSeen = true
        if let previous {
            func grow(_ metric: PowerMetric, _ value: UInt64, _ old: UInt64) {
                let grown = value >= old ? value - old : value
                if grown > 0 { state.window.record(metric.rawValue, count: grown, second: second) }
            }
            grow(.extensionPublished, published, previous.published)
            grow(.extensionDropped, dropped, previous.dropped)
            grow(.extensionOverwritten, overwritten, previous.overwritten)
            grow(.ringLost, lost, previous.lost)
        }
        let newSecond = advance(to: second)
        os_unfair_lock_unlock(lock)
        if newSecond { sampleGauges() }
    }

    /// Work that ended at `time` after `nanoseconds`. Dropped when it began
    /// before the session did, or the session has ended.
    private func add(_ metric: PowerMetric, count: UInt64, nanoseconds: UInt64, at time: UInt64) {
        let second = Int64(time / 1_000_000_000)
        os_unfair_lock_lock(lock)
        guard state.endedAt == nil, time &- nanoseconds >= state.startedAt else {
            os_unfair_lock_unlock(lock)
            return
        }
        state.window.record(metric.rawValue, count: count, nanoseconds: nanoseconds, second: second, at: time)
        let newSecond = advance(to: second)
        os_unfair_lock_unlock(lock)
        if newSecond { sampleGauges() }
    }

    /// Under the lock: whether `second` is the first record of a new second.
    private func advance(to second: Int64) -> Bool {
        guard second > state.lastSecond else { return false }
        state.lastSecond = second
        return true
    }

    /// Once a second at most, outside the lock. The clock and CPU time are
    /// read together, so a sample's rate is not skewed by a delay between them.
    private func sampleGauges() {
        let time = clock(), cpu = cpuTime(), thermal = thermalState()
        os_unfair_lock_lock(lock)
        if state.endedAt == nil {
            state.cpu.note(cpu, at: time)
            state.worstThermal = max(state.worstThermal, thermal)
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: Reading

    func snapshot() -> PowerSnapshot {
        var time = clock(), cpu = cpuTime()
        let thermal = thermalState()
        os_unfair_lock_lock(lock)
        if let endedAt = state.endedAt {
            // Frozen at Stop; only the thermal state and Low Power are live.
            time = endedAt
            cpu = state.cpuAtEnd
        } else {
            state.cpu.note(cpu, at: time)
            state.worstThermal = max(state.worstThermal, thermal)
        }
        var snapshot = PowerSnapshot()
        snapshot.ended = state.endedAt != nil
        let second = Int64(time / 1_000_000_000)
        snapshot.hasSession = state.hasSession
        snapshot.elapsed = time > state.startedAt ? Double(time - state.startedAt) / 1e9 : 0
        snapshot.span = PowerWindow.span(now: time, start: state.startedAt)
        snapshot.startedAt = state.startedAt
        snapshot.totalTallies = state.window.totals
        snapshot.recentTallies = (0..<state.window.metrics).map { state.window.recent($0, second: second) }
        snapshot.cpuSeconds = cpu > state.cpuAtStart ? Double(cpu - state.cpuAtStart) / 1e9 : 0
        snapshot.cpuPercentRecent = state.cpu.rate(cpu, at: time).map { $0 * 100 }
        snapshot.thermal = thermal
        snapshot.worstThermal = state.worstThermal
        snapshot.queueDepth = state.queueDepth
        snapshot.maxQueueDepth = state.maxQueueDepth
        snapshot.queueCapacity = state.queueCapacity
        snapshot.usesQueue = state.usesQueue
        snapshot.modes = state.modes
        snapshot.gateOccupancy = state.gateOccupancy
        snapshot.readingMode = state.readingMode
        snapshot.analysedLastSecond = state.window.count(PowerMetric.framesAnalysed.rawValue, second: second - 1)
        snapshot.extensionSeen = state.extensionSeen
        let languages = state.languages
        os_unfair_lock_unlock(lock)
        snapshot.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let languages {
            let read = languages.state
            snapshot.language = read.language
            snapshot.languageConfirmed = read.isConfirmed
            snapshot.languageAutomatic = languages.isAutomatic
        }
        return snapshot
    }
}

/// The Power section's text: short monospaced lines, not localized.
enum PowerReport {
    static func lines(_ s: PowerSnapshot) -> [String] {
        var lines: [String] = []
        guard s.hasSession else { return ["No capture session since the app started."] }
        let minutes = Int(s.elapsed) / 60, seconds = Int(s.elapsed) % 60
        // Every line stays within 42 characters, a phone's width at 11 pt.
        lines.append(String(format: "%@ %d:%02d · CPU %@ s · 60 s: %@",
                            s.ended ? "stopped" : "session", minutes, seconds,
                            String(format: s.cpuSeconds < 100 ? "%.1f" : "%.0f", s.cpuSeconds),
                            s.cpuPercentRecent.map { String(format: "%.0f%%", $0) } ?? "-"))
        lines.append(String(format: "thermal %@ (worst %@)", thermalName(s.thermal), thermalName(s.worstThermal)))
        lines.append("Low Power Mode " + (s.lowPower ? "on" : "off"))
        if let language = s.language {
            // Two lines, each well under 42 characters for every language.
            lines.append(String(format: "game language %@ (%@)", language.rawValue,
                                s.languageAutomatic ? (s.languageConfirmed ? "auto, found" : "auto, guess") : "chosen"))
            lines.append(String(format: "header OCR %@ %@", language.needsAccurateRecognition ? "accurate" : "fast",
                                language.recognitionLanguages.joined(separator: "+")))
        }

        // Frames
        lines.append(row("frames", "session", "/min"))
        let delivered = s.total(.framesDelivered).count, analysed = s.total(.framesAnalysed).count
        let recentSkipped = s.recent(.framesDelivered).count &- min(s.recent(.framesDelivered).count,
                                                                    s.recent(.framesAnalysed).count)
        lines.append(row(PowerMetric.framesDelivered.label, "\(delivered)", rate(s.perMinute(.framesDelivered))))
        lines.append(row(PowerMetric.framesAnalysed.label, "\(analysed)", rate(s.perMinute(.framesAnalysed))))
        lines.append(row("skipped", "\(delivered &- min(delivered, analysed))",
                         rate(PowerWindow.perMinute(recentSkipped, span: s.span))))
        if s.usesQueue {
            // Newest frame only: a frame replaced before analysis took it.
            lines.append(row(s.queueCapacity == 1 ? "superseded" : PowerMetric.backlogDropped.label,
                             "\(s.total(.backlogDropped).count)", rate(s.perMinute(.backlogDropped))))
            lines.append(String(format: "queue now %d · max %d of %d", s.queueDepth, s.maxQueueDepth,
                                s.queueCapacity))
        }
        if let line = readingModeLine(s) { lines.append(line) }
        lines.append(contentsOf: modeLines(s.modes))
        lines.append(contentsOf: gateLines(s.gateOccupancy))
        if s.extensionSeen {
            for metric in [PowerMetric.extensionPublished, .extensionDropped, .extensionOverwritten, .ringLost] {
                lines.append(row(metric.label, "\(s.total(metric).count)", rate(s.perMinute(metric))))
            }
            lines.append("extension CPU and scaling time not shared")
        }

        // Submission counts are separate from Vision timings. An unchanged
        // look neither performs OCR nor refreshes the old reading's timestamp.
        lines.append(row("header work", "n", "/min"))
        for metric in PowerMetric.headerWork {
            lines.append(row(metric.label, "\(s.total(metric).count)", rate(s.perMinute(metric))))
        }
        lines.append("header skip: unchanged, age <1s")
        // Text reads
        lines.append(row("text read", "n", "/min", "avg ms", "max ms"))
        for metric in PowerMetric.textReads {
            let total = s.total(metric)
            lines.append(row(metric.label, "\(total.count)", rate(s.perMinute(metric)),
                             milliseconds(total.averageMilliseconds), milliseconds(total.maxMilliseconds)))
        }

        // Steps, per analysed frame
        lines.append(row("step", "runs", "ms/run", "ms/frm", "60 s"))
        let recentAnalysed = s.recent(.framesAnalysed).count
        for metric in PowerMetric.steps where metric == .frameWork || s.total(metric).count > 0 {
            let total = s.total(metric), recent = s.recent(metric)
            lines.append(row(metric.label, "\(total.count)", milliseconds(total.averageMilliseconds),
                             milliseconds(perFrame(total.nanoseconds, analysed)),
                             milliseconds(perFrame(recent.nanoseconds, recentAnalysed))))
        }

        // Each read's and step's longest run, and when it ended, in session
        // time ("2:14" is 2 min 14 s after Start).
        lines.append(row("longest", "max ms", "at"))
        for metric in PowerMetric.textReads + PowerMetric.steps where s.total(metric).count > 0 {
            lines.append(row(metric.label, milliseconds(s.total(metric).maxMilliseconds), clock(s.maxAt(metric))))
        }

        // The CPU time no step or read accounts for. Timed work is wall
        // time, so a read waiting on Vision's own threads can make it exceed
        // the CPU time; the split is a pointer, not a balance.
        let timed = s.timedSeconds
        lines.append(String(format: "timed %@ s · untimed %@ s", secondsText(timed), secondsText(s.cpuSeconds - timed)))
        return lines
    }

    /// Session time as m:ss, or whole minutes once that no longer fits.
    static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "-" }
        let whole = Int(seconds)
        return whole < 6_000 ? String(format: "%d:%02d", whole / 60, whole % 60) : "\(whole / 60)m"
    }

    static func secondsText(_ value: Double) -> String {
        String(format: abs(value) < 100 ? "%.1f" : "%.0f", value)
    }

    /// The gate's pace now, in the words of the floating window's colours
    /// legend: its rate cap and the frames analysed in the last whole second.
    /// The text equivalent of the window's debug fill.
    static func readingModeLine(_ s: PowerSnapshot) -> String? {
        guard let mode = s.readingMode else { return nil }
        return String(format: "%@ %@ %ld/s · last s %llu", s.ended ? "last" : "now", mode.label,
                      mode.ratePerSecond, s.analysedLastSecond)
    }

    /// The gate's time split: seconds and share in each pace.
    static func modeLines(_ modes: AnalysisModeClock) -> [String] {
        guard modes.total > 0 else { return [] }
        var lines = [row("gate time", "s", "%")]
        for mode in AnalysisModeClock.modes {
            lines.append(row(mode.rawValue, String(format: "%.1f", modes.seconds(mode)),
                             modes.percent(mode).map { String(format: "%.0f", $0) } ?? "-"))
        }
        return lines
    }

    /// English report only: formatting happens on copy/read, never per frame.
    static func gateLines(_ gate: AnalysisGateOccupancy) -> [String] {
        guard gate.looks > 0 else { return [] }
        var lines = ["gate looks \(gate.looks) · still \(gate.stillLooks)", row("gate samples", "quiet", "rest", "active"),
                     row("analysed", "\(gate.samples[0])", "\(gate.samples[1])", "\(gate.samples[2])"),
                     "gate inputs overlap; * = latest", row("input", "s", "looks")]
        for reason in AnalysisGateReason.allCases where gate.counts[reason.rawValue] > 0 {
            let label = (gate.current.has(reason) ? "*" : " ") + reason.label
            lines.append(row(label, secondsText(gate.seconds[reason.rawValue]), "\(gate.counts[reason.rawValue])"))
        }
        if let dark = gate.dark, let bright = gate.bright {
            lines.append(String(format: "luma dark/bright %.0f%% / %.0f%%", dark * 100, bright * 100))
            lines.append(String(format: "dark range %.0f...%.0f%% (cand >=60%%)", gate.minimumDark * 100, gate.maximumDark * 100))
            lines.append(String(format: "bright range %.0f...%.0f%% (cand <=25%%)", gate.minimumBright * 100, gate.maximumBright * 100))
        }
        return lines
    }

    static func thermalName(_ raw: Int) -> String {
        switch ProcessInfo.ThermalState(rawValue: raw) {
        case .nominal?: return "nominal"
        case .fair?: return "fair"
        case .serious?: return "serious"
        case .critical?: return "critical"
        default: return "?"
        }
    }

    static func perFrame(_ nanoseconds: UInt64, _ frames: UInt64) -> Double? {
        frames > 0 ? Double(nanoseconds) / Double(frames) / 1e6 : nil
    }

    static func rate(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "-" }
    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: value < 10 ? "%.2f" : value < 100 ? "%.1f" : "%.0f", value)
    }

    /// A label and right-aligned columns, 42 characters at most.
    static func row(_ label: String, _ columns: String...) -> String {
        var line = label.count < 12 ? label + String(repeating: " ", count: 12 - label.count) : String(label.prefix(12))
        for (index, column) in columns.enumerated() {
            let width = index == 0 ? 7 : 6
            line += column.count < width ? String(repeating: " ", count: width - column.count) + column : " " + column
        }
        return line
    }
}
