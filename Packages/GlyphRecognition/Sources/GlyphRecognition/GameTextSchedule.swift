/// One budget for header, result, gear-panel and portal-screen OCR, shared by
/// live capture and replay.
/// A rejected panel candidate gets one probe until its geometry disappears. A
/// confirmed panel keeps the lane through a few failed reads: a spark flash or
/// a low-confidence label must not forfeit the rest of a 2.5-second conclusion.
public struct GameTextSchedule: Sendable {
    public enum Mode: String, Sendable { case header, result, gear, portal, command }
    /// A lane's spacing: between any two reads, and between two gear reads.
    public struct Pace: Sendable, Equatable {
        public var minimumInterval: Double
        public var gearInterval: Double
        public init(minimumInterval: Double, gearInterval: Double) {
            self.minimumInterval = minimumInterval; self.gearInterval = gearInterval
        }
    }
    public struct Request: Sendable, Equatable {
        public let id: Int
        public let mode: Mode
        public let sourceTime: Double
    }
    public private(set) var inFlight: Request?
    private var lastSubmission = -Double.infinity
    private var nextID = 0
    private var resultConfirmed = false
    private var rejectedCandidate = false
    private var confirmedMisses = 0
    private var lastGearSubmission = -Double.infinity
    private var gearMisses = 0
    /// The last gear read found a panel (a portal or Bonus title), and panel
    /// geometry has been on every frame since.
    public private(set) var readsGearPanel = false
    /// Panel geometry has been on every frame since the last gear request.
    private var gearGeometryStayed = false
    private var lastPortalSubmission = -Double.infinity
    private var lastHeaderSubmission = -Double.infinity
    /// Consecutive failed reads after which a confirmed panel returns the lane
    /// to the header, so a persistent false candidate cannot starve it.
    private let maximumConfirmedMisses = 3
    /// A new gear panel (`observeGearPanel`): bounds this far (a fraction of
    /// the frame's height, top or bottom) from where the panel the last gear
    /// read started on was still. A new panel slides in about 0.03 below its settled place
    /// (2026-10-28: top 0.3147–0.3162 on its first frame, 0.2847 settled);
    /// pickup sparks over a border move the detected bounds by about 2 px
    /// (0.0015), a settled panel by at most 0.0007.
    public static let newPanelShift = 0.01
    /// A panel is still when its bounds are within this of the previous
    /// analysed frame's: sparks jitter a resting panel's by up to 0.003
    /// between two frames; a sliding panel moves 0.0058–0.0143 a 20-fps
    /// frame until its last 0.0036.
    public static let stillPanelTolerance = 0.003
    /// The last analysed frame's panel bounds, as `observeGearPanel` saw them.
    private var observedGearBounds: GearDropPanelBounds?
    /// That frame's time, and whether its panel was still.
    private var observedGearTime = -Double.infinity
    private var observedGearStill = false
    /// The bounds the last gear read started on (once still, where its
    /// panel came to rest), while that read can still be followed by a new
    /// panel: an event uses it up.
    private var gearReadBounds: GearDropPanelBounds?
    /// Those bounds are a still panel's.
    private var gearReadStill = false
    /// An analysed frame without panel geometry came after that read started.
    private var gearAbsentSinceRead = false
    /// The last gear read is the first after a cancelled one: no geometry
    /// stops it, so a panel always gets a read through.
    private var gearReadProtected = false
    private var cancelledSinceGearRead = false
    /// A new panel has appeared and its first read hasn't started.
    public private(set) var newGearPanel = false
    /// The gear request `observeGearPanel` asked to stop. It keeps the lane
    /// until its one completion: two OCR requests never run at once.
    public private(set) var cancelledGearRequest: Request?
    public init() {}

    /// Called on every analysed frame, before `take`, with the frame's gear
    /// panel bounds (nil when none shows). Returns the in-flight gear request
    /// to stop when a new panel has replaced the one it reads, else nil.
    /// `previousPanelUnconfirmed`: reads found the panel being replaced and
    /// its rows aren't all confirmed (an open drop group whose current panel
    /// isn't settled). The read in flight may be the one that confirms them,
    /// so it runs on: stopping it would trade that panel's rows for the new
    /// one's. The new panel's first read still has no spacing.
    ///
    /// A new panel's first read otherwise waited behind the previous panel's
    /// read, then behind its spacing: a 0.45-s Bonus panel then got one read
    /// and lost its rows.
    ///
    /// A new panel: bounds more than `newPanelShift` from where the panel
    /// the last gear read started on was still (its start bounds, or, for a
    /// read started while the panel slid in, where it came to rest), or from
    /// its start bounds after an analysed frame without any panel. For a read
    /// started while its panel slid in, also a top more than `newPanelShift`
    /// further down the screen than where it started, before the panel rests:
    /// its own settling only moves the top up. Each read
    /// is followed by at most one such event; the read that follows a
    /// cancelled one is never cancelled itself, so flicker and sparks can
    /// stop at most every other read of one panel. A candidate backed off by
    /// misses gets none, as before.
    public mutating func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double,
                                          previousPanelUnconfirmed: Bool = false) -> Request? {
        let previous = observedGearBounds
        observedGearBounds = bounds; observedGearTime = time
        guard let bounds else {
            observedGearStill = false
            if gearReadBounds != nil { gearAbsentSinceRead = true }
            return nil
        }
        observedGearStill = previous.map { !Self.differs(bounds, $0, by: Self.stillPanelTolerance) } ?? false
        guard let start = gearReadBounds else { return nil }
        let moved: Bool
        if !gearReadStill, !gearAbsentSinceRead {
            // The read started on a sliding panel: it reads that panel, and
            // its geometry is where the panel comes to rest. A panel slides
            // in from below and settles upwards, so a top more than
            // `newPanelShift` further down than where the read started is a
            // new panel sliding in, even before the old one rests.
            if bounds.top - start.top > Self.newPanelShift {
                moved = true
            } else {
                if observedGearStill { gearReadBounds = bounds; gearReadStill = true }
                return nil
            }
        } else {
            moved = Self.differs(bounds, start, by: Self.newPanelShift)
        }
        guard moved, gearMisses < 3 else { return nil }
        gearReadBounds = nil
        newGearPanel = true
        guard let request = inFlight, request.mode == .gear, cancelledGearRequest == nil,
              !gearReadProtected, !previousPanelUnconfirmed else { return nil }
        // Its finding is the old panel's: no pace for the new one.
        cancelledGearRequest = request
        cancelledSinceGearRead = true
        readsGearPanel = false
        return request
    }

    static func differs(_ a: GearDropPanelBounds, _ b: GearDropPanelBounds, by tolerance: Double) -> Bool {
        abs(a.top - b.top) > tolerance || abs(a.bottom - b.bottom) > tolerance
    }

    public mutating func take(at time: Double, panelCandidate: Bool, resultEligible: Bool,
                              minimumInterval: Double = 0.1, gearCandidate: Bool = false,
                              headerPriority: Bool = false, portalCandidate: Bool = false, commandCandidate: Bool = false,
                              readsHeader: Bool = true, headerInterval: Double? = nil,
                              gearInterval: Double = 0.2, gearPanelPace: Pace? = nil,
                              admitsHeader: () -> Bool = { true }) -> Request? {
        guard time.isFinite else { return nil }
        if !panelCandidate || !resultEligible {
            resultConfirmed = false; rejectedCandidate = false; confirmedMisses = 0
        }
        // Checked before the lane is free: a panel that leaves while its read
        // runs must not lend that read's finding to the next panel.
        if !gearCandidate { gearGeometryStayed = false; readsGearPanel = false }
        guard inFlight == nil else { return nil }
        // Header cadence stays exactly as before. Result observations allow the
        // same 2-ms timestamp jitter used by the Activity scheduler.
        let wantsResult = resultEligible && panelCandidate && (resultConfirmed || !rejectedCandidate)
        if !gearCandidate { gearMisses = 0 }
        let gearBackedOff = gearMisses >= 3
        // `gearPanelPace`, when given, is the cadence a panel keeps once a read
        // has found it there, while `minimumInterval` and `gearInterval` are
        // slowed (Low Power Mode, a hot phone). A row needs two agreeing
        // reads, and a portal panel tapped on can last well under a second:
        // at the slow cadence it got one read and lost every row. Until a read
        // finds a panel, and as soon as its geometry leaves, the caller's own
        // spacing applies again.
        let panelPace = gearCandidate && readsGearPanel ? gearPanelPace : nil
        // A new panel's first read has no spacing from the last panel's reads
        // (`observeGearPanel`), unless the candidate has backed off.
        let firstOfNewPanel = gearCandidate && newGearPanel && !gearBackedOff
        // `gearInterval` is the panel's own cadence (doubled by Low Power Mode);
        // a failing candidate backs off to at least a second.
        let gearSpacing = firstOfNewPanel ? 0 : gearBackedOff ? max(1.0, gearInterval)
            : panelPace?.gearInterval ?? gearInterval
        let wantsGear = gearCandidate && !headerPriority && !wantsResult
            && time - lastGearSubmission >= gearSpacing - 0.002
        // The portal screen lasts a fraction of a second before a hack, so it
        // gets the gear cadence, but never over a panel being read.
        let wantsPortal = portalCandidate && !headerPriority && !wantsResult && !wantsGear
            && time - lastPortalSubmission >= 0.2 - 0.002
        // While a panel shows, the header waits for it. A header read between
        // two gear reads holds the lane for as long as its OCR takes, so on a
        // phone a panel got about one read a second and its rows never found
        // two reads close enough to agree. The lane idles instead until gear's
        // next turn; input (`headerPriority`) and result reads keep theirs,
        // and portal and command reads still fit between. A candidate that
        // keeps failing has backed off and no longer holds the lane, so a
        // false panel can't starve the header.
        let headerWaitsForGear = gearCandidate && !headerPriority && !gearBackedOff
        // A header-only cadence slower than the lane's, for while no hack is
        // on screen. It never delays a result, gear, portal or command read.
        let headerDue = headerInterval.map {
            time < lastHeaderSubmission || time - lastHeaderSubmission >= $0 - 0.002
        } ?? true
        // Gear-only capture follows no phase: the lane idles between panel reads.
        guard (readsHeader && headerDue && !headerWaitsForGear) || wantsResult || wantsGear || wantsPortal
                || commandCandidate
        else { return nil }
        let tolerance = wantsResult ? 0.002 : 0
        let spacing = !wantsResult && wantsGear
            ? firstOfNewPanel ? 0 : panelPace?.minimumInterval ?? minimumInterval : minimumInterval
        guard time < lastSubmission || time - lastSubmission >= spacing - tolerance else { return nil }
        let mode: Mode = wantsResult ? .result : wantsGear ? .gear : wantsPortal ? .portal : commandCandidate ? .command : .header
        // Content suppression applies only to an otherwise eligible header.
        // Keep candidate bookkeeping above, but consume no cadence, ID or
        // lane ownership on a skip. Panels and commands never ask this gate.
        guard mode != .header || admitsHeader() else { return nil }
        lastSubmission = time; nextID += 1
        let request = Request(id: nextID, mode: mode, sourceTime: time)
        if wantsGear {
            lastGearSubmission = time; gearGeometryStayed = true
            // The geometry this read starts on, if this frame's was observed.
            let observed = observedGearTime == time ? observedGearBounds : nil
            gearReadBounds = observed; gearReadStill = observed != nil && observedGearStill
            gearAbsentSinceRead = false; newGearPanel = false
            gearReadProtected = cancelledSinceGearRead; cancelledSinceGearRead = false
        }
        if wantsPortal { lastPortalSubmission = time }
        if mode == .header || mode == .command { lastHeaderSubmission = time }
        inFlight = request
        return request
    }

    /// `untitledPanel`: a gear read that found no panel title, though its
    /// body showed a drop panel (`GearPanelReading.untitledPanel`). It is not
    /// a miss: a portal panel with a CJK-only name must not back off the
    /// Bonus panel that replaces it in the same place. It finds no panel
    /// either, so it gives no panel pace.
    public mutating func finish(_ request: Request, panelPresent: Bool = false, untitledPanel: Bool = false) {
        guard inFlight == request else { return }
        inFlight = nil
        if request.mode == .gear, request == cancelledGearRequest {
            // Stopped for a new panel: no pace from the old panel, and no
            // miss, unless the reads before it were misses: a failing
            // candidate backs off after as many reads as before.
            cancelledGearRequest = nil
            readsGearPanel = false
            if gearMisses > 0 { gearMisses = min(3, gearMisses + 1) }
            return
        }
        if request.mode == .gear {
            if panelPresent { gearMisses = 0 } else if !untitledPanel { gearMisses = min(3, gearMisses + 1) }
            readsGearPanel = panelPresent && gearGeometryStayed
            return
        }
        guard request.mode == .result else { return }
        if panelPresent {
            resultConfirmed = true; rejectedCandidate = false; confirmedMisses = 0
        } else if resultConfirmed {
            confirmedMisses += 1
            if confirmedMisses >= maximumConfirmedMisses { resultConfirmed = false; rejectedCandidate = true }
        } else {
            rejectedCandidate = true
        }
    }
}
