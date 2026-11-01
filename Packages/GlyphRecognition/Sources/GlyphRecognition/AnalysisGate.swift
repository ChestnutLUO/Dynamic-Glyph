/// A cheap look at a frame's luminance, taken before anything is converted,
/// decoded or read. It answers two questions: could this be a game screen the
/// readers care about, and has anything changed since the last look?
///
/// Every Glyph hack screen, command channel, result dialog, portal screen and
/// item panel in the fixtures has little bright content over the array area
/// (at most 15% brighter than 60), and most are near-black there (at least 77%
/// darker than 20). The map is the opposite: roads, labels and particles make
/// 30% or more of it bright. Brightness is what separates them; darkness only
/// widens the net. Both screens' backgrounds sit right at the dark level (the
/// map's at 20-23, some portal screens' at 16-19), so a capture's luma, which
/// differs a little from a decoded image's, moves a large share of either
/// across it: the dark test therefore needs a share no map reaches even then.
/// A frame must fail *both* tests before it counts as quiet, so a dark or a
/// dim frame always passes. A wrong "candidate" costs power; a wrong "quiet"
/// could cost a Glyph, so the thresholds lean far toward candidate.
public struct LumaGateReading: Sendable, Equatable {
    /// Over the array area: share of samples darker than `LumaGate.darkLevel`.
    public let darkFraction: Double
    /// Over the array area: share of samples brighter than `LumaGate.brightLevel`.
    public let brightFraction: Double
    /// Mean luminance of each cell of a coarse grid over the whole frame,
    /// row-major. Only compared with another reading's.
    public let cells: [UInt8]
    /// Whether the frame may show a screen any reader cares about.
    public let isCandidate: Bool

    /// The largest change of any cell's mean; `Int.max` for readings of
    /// different shapes, which are never the same screen.
    public func difference(from other: LumaGateReading) -> Int {
        guard cells.count == other.cells.count, !cells.isEmpty else { return .max }
        var largest = 0
        for index in cells.indices { largest = max(largest, abs(Int(cells[index]) - Int(other.cells[index]))) }
        return largest
    }

    /// The mean of the cells' means: the frame's overall brightness. Panning
    /// or animating the same screen hardly moves it; replacing the screen with
    /// another does (see `AnalysisRateController.Policy.switchMeanJump`).
    public var meanLuma: Double {
        guard !cells.isEmpty else { return 0 }
        var total = 0
        for value in cells { total += Int(value) }
        return Double(total) / Double(cells.count)
    }
}

public struct LumaGate: Sendable {
    public static let darkLevel: UInt8 = 20
    public static let brightLevel: UInt8 = 60
    /// Either one makes a frame a candidate. Fixtures, decoded or as Rec. 709
    /// luma: game screens at most 0.15 bright; map frames at least 0.30
    /// bright, and at most 0.44 dark even with their background shifted ten
    /// levels darker.
    public static let minimumDarkFraction = 0.6
    public static let maximumBrightFraction = 0.25
    /// Where the hack draws its array: the area least likely to be covered by
    /// the header, the slot strip, a banner or the keyboard.
    public static let arrayRows = 0.30..<0.85
    public static let arrayColumns = 0.03..<0.97
    public static let gridColumns = 12
    public static let gridRows = 24

    /// Distance between samples in pixels. 4 keeps a 3-pixel line from
    /// slipping between samples in both directions at once.
    public let step: Int

    public init(step: Int = 4) {
        self.step = max(1, step)
    }

    /// `luma` returns full-range luminance (0 black, 255 white) for a pixel.
    public func read(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> LumaGateReading? {
        guard width > 0, height > 0 else { return nil }
        let columns = Self.gridColumns, rows = Self.gridRows
        var sums = [Int](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        let top = Int(Self.arrayRows.lowerBound * Double(height)), bottom = Int(Self.arrayRows.upperBound * Double(height))
        let left = Int(Self.arrayColumns.lowerBound * Double(width)), right = Int(Self.arrayColumns.upperBound * Double(width))
        var dark = 0, bright = 0, area = 0
        var y = step / 2
        while y < height {
            let row = min(rows - 1, y * rows / height) * columns
            let inArrayRows = y >= top && y < bottom
            var x = step / 2
            while x < width {
                let value = luma(x, y)
                let cell = row + min(columns - 1, x * columns / width)
                sums[cell] += Int(value); counts[cell] += 1
                if inArrayRows, x >= left, x < right {
                    area += 1
                    if value < Self.darkLevel { dark += 1 } else if value > Self.brightLevel { bright += 1 }
                }
                x += step
            }
            y += step
        }
        let cells = zip(sums, counts).map { UInt8(clamping: $1 > 0 ? $0 / $1 : 0) }
        let darkFraction = area > 0 ? Double(dark) / Double(area) : 1
        let brightFraction = area > 0 ? Double(bright) / Double(area) : 0
        return LumaGateReading(
            darkFraction: darkFraction, brightFraction: brightFraction, cells: cells,
            isCandidate: darkFraction >= Self.minimumDarkFraction || brightFraction <= Self.maximumBrightFraction)
    }

    public func read(_ image: LuminanceImage) -> LumaGateReading? {
        image.pixels.withUnsafeBufferPointer { pixels in
            read(width: image.width, height: image.height) { x, y in pixels[y * image.width + x] }
        }
    }

    /// An 8-bit luma plane, such as plane 0 of a biplanar 4:2:0 buffer. Video
    /// range (16-235) is stretched to full range first, so black is 0 either way.
    public func read(plane: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                     videoRange: Bool) -> LumaGateReading? {
        let bytes = plane.assumingMemoryBound(to: UInt8.self)
        guard videoRange else {
            return read(width: width, height: height) { x, y in bytes[y * bytesPerRow + x] }
        }
        let table = Self.videoRangeTable
        return table.withUnsafeBufferPointer { table in
            read(width: width, height: height) { x, y in table[Int(bytes[y * bytesPerRow + x])] }
        }
    }

    /// Packed 32-bit BGRA, little-endian: blue first.
    public func read(bgra: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> LumaGateReading? {
        let bytes = bgra.assumingMemoryBound(to: UInt8.self)
        return read(width: width, height: height) { x, y in
            let pixel = bytes + y * bytesPerRow + x * 4
            // BT.601 weights in fixed point; close enough for a gate.
            return UInt8(truncatingIfNeeded: (29 * Int(pixel[0]) + 150 * Int(pixel[1]) + 77 * Int(pixel[2])) >> 8)
        }
    }

    static let videoRangeTable: [UInt8] = (0..<256).map { value in
        UInt8(clamping: ((value - 16) * 255 + 109) / 219)
    }
}

/// Decides how often frames are analyzed and how much of the work they get.
///
/// Slow unless there is positive evidence of a hack screen. `active` is the
/// full pipeline at the full rate, and it needs a reason: `inHack` (a phase
/// the tracker follows, or the command screen being watched) or `busy` (the
/// caller saw the node array calibrated, the slot strip, the input timer bar,
/// a command notice, or a panel being read). After `settle` seconds without
/// one, analysis slows to a few frames a second: `quiet` when the last gate
/// reading was no candidate (the map), which also skips the node-array search
/// and header text recognition; `resting` when it was a candidate, which keeps
/// the whole pipeline, array search and header included, so the slow looks
/// can still find the evidence that wakes it. Evidence returns to `active` on
/// the look it is reported: the gate runs at the active rate, so the return
/// costs no extra latency once a slow look has found it.
///
/// A dark or dim screen that keeps changing is no evidence: the game map at
/// night is both, all the time. Luma only chooses between `resting` and
/// `quiet`, and one thing more: a frame that turns from no candidate into a
/// candidate (the bright map replaced by a game screen) is analyzed at once,
/// a single `active` look that needs no settling, so the array search sees a
/// hack screen's first frame rather than one up to a slow interval later.
/// A candidate after a candidate (the night map, or a portal screen, replaced
/// by the hack) gets the same through its brightness: a candidate whose
/// overall luma moved by `switchMeanJump` within `switchWindow` is a switch of
/// screens. That look is analyzed at once and the `switchBurst` after it at
/// the active rate, long enough for the array search to fit an empty array
/// before the first Glyph is drawn; the burst does not restart settling.
///
/// A still screen delivers no new frames: a broadcast sends none, and
/// ScreenCaptureKit only idle frames that repeat the last timestamp. The
/// capture source then calls `advanceStill(at:busy:inHack:constrained:)` instead, so
/// the controller's clock keeps running and it settles as it would on
/// unchanged frames.
public struct AnalysisRateController: Sendable {
    public enum Mode: String, Sendable, Equatable { case active, resting, quiet }

    public struct Policy: Sendable, Equatable {
        /// 20 Hz less a millisecond of timestamp jitter: the rate the tracker's
        /// blank-between-Glyphs rule was measured at.
        public var activeInterval = 0.049
        /// About 4 Hz, resting or quiet.
        public var quietInterval = 0.249
        /// Halved, for Low Power Mode or a hot device, outside a hack only.
        public var constrainedActiveInterval = 0.099
        public var constrainedQuietInterval = 0.499
        /// How long nothing must happen before analysis slows down.
        public var settle = 2.0
        /// A larger change in any cell's mean luminance counts as a change of
        /// the screen (see `LumaGateReading.difference`). It no longer paces
        /// analysis: a changing screen is not a hack screen. Kept so tools and
        /// tests share one measure of change.
        public var changeThreshold = 3
        /// A candidate whose `meanLuma` differs by this much from any look in
        /// the last `switchWindow` seconds shows another screen. Fixtures, on
        /// the 12×24 grid: within a hack (empty array, Glyph drawn, command
        /// channel to blank, input) it moves at most 4.2; the map panned 8 to
        /// 120 px, at most 0.25; map to hack screen at least 40; the hack
        /// screens are at most 10.3, the redacted maps 47 and 59, a synthetic
        /// night map 32.
        public var switchMeanJump = 8.0
        /// Covers a fade that spreads the change over a few 20-Hz looks.
        public var switchWindow = 0.3
        /// Seconds at the active rate after a switch of screens.
        public var switchBurst = 1.0
        public init() {}
    }

    /// What one frame should get.
    public struct Decision: Sendable, Equatable {
        public let mode: Mode
        /// Minimum source-time spacing between analyzed frames.
        public let interval: Double

        public init(mode: Mode, interval: Double) {
            self.mode = mode
            self.interval = interval
        }
    }

    public let policy: Policy
    public private(set) var mode: Mode = .active
    /// The last look was a single `active` one for a frame that had just
    /// turned into a candidate. For diagnostics.
    public private(set) var enteredCandidate = false
    /// The last look was at the active rate only because a candidate's
    /// screen switched less than `switchBurst` ago. For diagnostics.
    public private(set) var switchedScreen = false
    /// Overall luma of the looks in the last `switchWindow`, oldest first.
    private var recentMeans: [(time: Double, mean: Double)] = []
    private var burstUntil = -Double.infinity
    private var quietSince: Double?
    /// Some frame with pixels has been read since the last reset.
    private var hasReading = false
    /// Whether the last frame with pixels was a candidate.
    private var lastCandidate = true
    private var lastTime = -Double.infinity

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// `gate` is nil when the frame carried no readable pixels: it neither
    /// shows a candidate nor proves a quiet screen. `busy` is positive
    /// evidence of a hack screen or of a panel being read; `inHack` a hack
    /// being followed: never slow down then. `inHack` keeps the full rate
    /// even when `constrained` (Low Power Mode or a hot device) halves the
    /// rest: the blank between two Glyphs lasts about 100 ms and needs two
    /// samples.
    public mutating func decide(at time: Double, gate: LumaGateReading?, busy: Bool, inHack: Bool,
                                constrained: Bool) -> Decision {
        if time < lastTime { reset() }
        lastTime = time
        var entered = false, switched = false
        if let gate {
            entered = hasReading && !lastCandidate && gate.isCandidate
            hasReading = true
            lastCandidate = gate.isCandidate
            let mean = gate.meanLuma, window = policy.switchWindow, jump = policy.switchMeanJump
            recentMeans.removeAll { time - $0.time > window }
            switched = gate.isCandidate && recentMeans.contains { abs($0.mean - mean) >= jump }
            // One switch is one burst: the looks before it are no reference.
            if switched { recentMeans = []; burstUntil = time + policy.switchBurst }
            recentMeans.append((time, mean))
        }
        let decision = pace(at: time, interesting: busy || inHack, evidence: gate != nil, inHack: inHack,
                            constrained: constrained)
        // A screen that just became a candidate, or switched to another, gets
        // this one frame analyzed in full, whatever the slow interval says; it
        // does not restart the settling, so a map hovering around the gate's
        // levels costs a frame per crossing, not two seconds at the full rate.
        enteredCandidate = entered && decision.mode != .active
        // The burst is for the screen switched to: the map returning ends it.
        switchedScreen = !enteredCandidate && lastCandidate && time < burstUntil && decision.mode != .active
        if enteredCandidate || (switchedScreen && switched) {
            return Decision(mode: .active, interval: policy.activeInterval)
        }
        // The rest of the burst, at the active rate, halved when constrained.
        if switchedScreen {
            return Decision(mode: .active, interval: constrained && !inHack ? policy.constrainedActiveInterval
                                                                            : policy.activeInterval)
        }
        return decision
    }

    /// A look at a screen the capture source vouches is unchanged since its
    /// last frame, at `time` on the frames' own clock: a source that delivers
    /// nothing, or only idle frames, while nothing changes. It counts as an
    /// unchanged frame with pixels, using the same settling window: without
    /// `busy` or `inHack`, the pace slows `settle` after the last reason to
    /// stay active. Before any frame with pixels it proves nothing, like a
    /// frame without them.
    ///
    /// `time` is extrapolated by the caller and may run a little ahead of the
    /// next frame's own timestamp. So it never restarts the clock, nor sets the
    /// time a frame's step back is measured from; one before the last frame
    /// is out of date and changes nothing.
    public mutating func advanceStill(at time: Double, busy: Bool, inHack: Bool, constrained: Bool) -> Decision {
        enteredCandidate = false; switchedScreen = false
        guard time.isFinite, time >= lastTime else { return decision(inHack: inHack, constrained: constrained) }
        return pace(at: time, interesting: busy || inHack, evidence: hasReading, inHack: inHack,
                    constrained: constrained)
    }

    /// `evidence`: the look showed what the screen is. Without it an
    /// active pace stays active, since nothing proved the screen quiet.
    private mutating func pace(at time: Double, interesting: Bool, evidence: Bool, inHack: Bool,
                               constrained: Bool) -> Decision {
        if interesting {
            quietSince = nil
            mode = .active
        } else if evidence || mode != .active {
            // A look timed a little ahead may have started this, so `time`
            // can be before `since`: then it simply has not settled yet.
            let since = quietSince ?? time
            quietSince = since
            if time - since >= policy.settle { mode = lastCandidate ? .resting : .quiet }
        }
        return decision(inHack: inHack, constrained: constrained)
    }

    private func decision(inHack: Bool, constrained: Bool) -> Decision {
        // Halved rates, except inside a hack.
        let halved = constrained && !inHack
        let interval = mode == .active ? (halved ? policy.constrainedActiveInterval : policy.activeInterval)
                                       : (halved ? policy.constrainedQuietInterval : policy.quietInterval)
        return Decision(mode: mode, interval: interval)
    }

    public mutating func reset() {
        mode = .active; quietSince = nil; hasReading = false; lastCandidate = true
        lastTime = -.infinity; enteredCandidate = false; switchedScreen = false
        recentMeans = []; burstUntil = -.infinity
    }

    /// How often the header may be read, or nil for not at all (a quiet
    /// screen). Waiting for a hack only needs to notice the command channel,
    /// which lasts seconds; inside one the header decides presentation and
    /// input and keeps 10 Hz.
    public static func headerInterval(mode: Mode, inHack: Bool, constrained: Bool) -> Double? {
        guard mode != .quiet || inHack else { return nil }
        let interval = inHack ? 0.1 : 0.5
        return constrained ? interval * 2 : interval
    }
}
