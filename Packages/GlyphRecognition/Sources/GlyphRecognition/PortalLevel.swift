/// What one portal screen showed, before any hack is known. Nothing here
/// names a portal or an agent: only resonator levels, a badge colour and
/// the colour of the resonator bars.
public struct PortalScreenEvidence: Sendable, Equatable, Codable {
    public let sourceTime: Double
    /// Up to eight resonator levels as read, in no particular slot order.
    /// A label that was not read is absent, not zero: it may be an empty
    /// slot or a missed read.
    public let resonators: [Int]
    /// Label rows that were seen but could not be parsed, or were missing
    /// from a column of four.
    public let unreadSlots: Int
    /// Hue of the level badge in degrees, nil when too faint to measure.
    public let badgeHue: Double?
    /// The faction the resonator bars were drawn in; nil in evidence logged
    /// before it was read.
    public let faction: PortalFaction?

    public init(sourceTime: Double, resonators: [Int], unreadSlots: Int, badgeHue: Double?,
                faction: PortalFaction? = nil) {
        self.sourceTime = sourceTime; self.resonators = resonators
        self.unreadSlots = unreadSlots; self.badgeHue = badgeHue; self.faction = faction
    }
}

/// A portal's level with how it was reached. Every source is kept, so a
/// report shows why a level was chosen or why sources disagreed.
public struct PortalLevelEstimate: Sendable, Equatable, Codable {
    public enum Confidence: String, Sendable, Codable, Comparable {
        case low, medium, high
        public static func < (a: Self, b: Self) -> Bool {
            let order: [Self] = [.low, .medium, .high]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }
    /// Nil when the sources leave more than one level.
    public let level: Int?
    public let lowest: Int
    public let highest: Int
    public let confidence: Confidence
    /// The sources allowed no common level; `level` then follows the
    /// strongest source.
    public let conflict: Bool
    public let resonators: [Int]?
    public let unreadSlots: Int?
    public let badgeLevels: [Int]?
    public let glyphCount: Int?
    /// The portal screen's bar colour, as a `PortalFaction` raw value; nil
    /// without a screen and in estimates saved before it was read. Kept as
    /// text so that a faction a later build adds reads as unknown here,
    /// rather than making the saved gear unreadable.
    public var factionCode: String? = nil

    public var faction: PortalFaction? { factionCode.flatMap(PortalFaction.init(rawValue:)) }
}

public enum PortalLevelRules {
    /// Glyphs in a hack by portal level, as the game assigns them. Validated
    /// on eleven complex hacks in the field tests; see the plan.
    public static func levels(forGlyphCount count: Int) -> ClosedRange<Int>? {
        switch count {
        case 1: return 1...1
        case 2: return 2...2
        case 3: return 3...5
        case 4: return 6...7
        case 5: return 8...8
        default: return nil
        }
    }

    /// Badge hues measured on two phones (L5 343–344°, L6 328–330°,
    /// L8 258–260°). Other levels are not calibrated yet: a hue near them
    /// only narrows the level to a range.
    static let calibratedHues: [(level: Int, hue: Double)] = [(5, 343.5), (6, 329), (8, 259)]
    static let calibrationTolerance = 7.0
    /// The uncalibrated range a hue warmer than L5 allows.
    static let warmBadgeLevels = 1...4

    /// The levels a badge hue allows, or nil when it tells nothing.
    public static func levels(forBadgeHue hue: Double) -> ClosedRange<Int>? {
        guard hue.isFinite else { return nil }
        func distance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        if let match = calibratedHues.first(where: { distance($0.hue, hue) <= calibrationTolerance }) {
            return match.level...match.level
        }
        // Between the calibrated L6 and L8 hues lies L7.
        if hue > calibratedHues[2].hue + calibrationTolerance && hue < calibratedHues[1].hue - calibrationTolerance {
            return 7...7
        }
        // Warmer than L5: the reds, oranges and yellows of L1–L4.
        if hue > calibratedHues[0].hue + calibrationTolerance || hue < 60 { return warmBadgeLevels }
        return nil
    }

    /// Portal level is the sum of all eight resonator levels over eight,
    /// rounded down, with an empty slot counting as zero. Unread slots could
    /// be anything from empty to L8.
    public static func levels(forResonators read: [Int], unread: Int) -> ClosedRange<Int>? {
        let known = read.filter { (1...8).contains($0) }
        let missing = max(0, 8 - known.count)
        guard !known.isEmpty || unread > 0 else { return nil }
        let sum = known.reduce(0, +)
        let lowest = max(1, sum / 8), highest = max(1, (sum + missing * 8) / 8)
        return lowest...min(8, highest)
    }

    public static func estimate(screen: PortalScreenEvidence?, glyphCount: Int?,
                                glyphCountSettled: Bool = true) -> PortalLevelEstimate? {
        var estimate = estimate(resonators: screen?.resonators, unreadSlots: screen?.unreadSlots,
                                badgeHue: screen?.badgeHue, glyphCount: glyphCount,
                                glyphCountSettled: glyphCountSettled)
        estimate?.factionCode = screen?.faction?.rawValue
        return estimate
    }

    /// `glyphCountSettled` is false when the hack's presentation command was
    /// not resolved: the Glyph table holds for complex hacks, and a command
    /// can change the count. Then the count never narrows the level, but a
    /// count that contradicts the other sources still flags the conflict, as
    /// it always did. The uncalibrated badge range warmer than L5 (L1–L4)
    /// doesn't narrow it either: with the count it put an L7 portal with 3
    /// Glyphs and its command unread at L3–L4. The resonators, the calibrated
    /// hues and the L7 band narrow as before; the count and the badge read
    /// stay recorded.
    public static func estimate(resonators: [Int]?, unreadSlots: Int?, badgeHue: Double?,
                                glyphCount: Int?, glyphCountSettled: Bool = true) -> PortalLevelEstimate? {
        let ring = resonators.flatMap { levels(forResonators: $0, unread: unreadSlots ?? 0) }
        let ringExact = ring.map { $0.count == 1 } ?? false
        let readBadge = badgeHue.flatMap(levels(forBadgeHue:))
        let badge = !glyphCountSettled && readBadge == warmBadgeLevels ? nil : readBadge
        let count = glyphCount.flatMap(levels(forGlyphCount:))
        let glyphs = glyphCountSettled || count.map({ contradicts($0, [ring, badge].compactMap { $0 }) }) == true
            ? count : nil
        // Strongest first: an exact ring, then the badge, then the count.
        let sources = [ring, badge, glyphs].compactMap { $0 }
        guard !sources.isEmpty else { return nil }
        let lowest = sources.map(\.lowerBound).max()!, highest = sources.map(\.upperBound).min()!
        let conflict = lowest > highest
        let range: ClosedRange<Int> = conflict ? (sources.first!) : lowest...highest
        let level = range.count == 1 ? range.lowerBound : nil
        let agreeing = sources.filter { $0.contains(range.lowerBound) && $0.contains(range.upperBound) }.count
        let confidence: PortalLevelEstimate.Confidence
        if conflict || level == nil { confidence = .low }
        else if ringExact && agreeing >= 2 { confidence = .high }
        else if ringExact || badge.map({ $0.count == 1 }) == true && agreeing >= 2 { confidence = .medium }
        else { confidence = .low }
        return PortalLevelEstimate(level: level, lowest: range.lowerBound, highest: range.upperBound,
            confidence: confidence, conflict: conflict, resonators: resonators, unreadSlots: unreadSlots,
            badgeLevels: readBadge.map(Array.init), glyphCount: glyphCount)
    }

    /// Whether `range` shares no level with what `others` leave, when they
    /// agree among themselves and leave something.
    static func contradicts(_ range: ClosedRange<Int>, _ others: [ClosedRange<Int>]) -> Bool {
        guard let lowest = others.map(\.lowerBound).max(), let highest = others.map(\.upperBound).min(),
              lowest <= highest else { return false }
        return range.upperBound < lowest || range.lowerBound > highest
    }
}

/// Collects portal screens between hacks. The screen shows for a fraction of
/// a second before the command screen and its labels fade in, so within one
/// screen the read with the most labels wins rather than two agreeing ones.
/// A later read beyond that screen replaces it: the player may have opened
/// another portal.
public struct PortalLevelObserver: Sendable {
    public struct Policy: Sendable {
        /// From the last portal-screen read to the hack's first Glyph. The
        /// command screen between them lasted up to about 4 s.
        public var attachWindow = 10.0
        /// Reads this close together are one screen fading in.
        public var sameScreen = 1.5
        public init() {}
    }
    public let policy: Policy
    private var best: PortalScreenEvidence?
    private var badge: Double?
    private var lastReadAt: Double?
    private var claimedThrough: Double?

    public init(policy: Policy = Policy()) { self.policy = policy }

    public mutating func accept(_ evidence: PortalScreenEvidence) {
        guard evidence.sourceTime.isFinite,
              claimedThrough.map({ evidence.sourceTime > $0 }) ?? true,
              lastReadAt.map({ evidence.sourceTime >= $0 }) ?? true else { return }
        lastReadAt = evidence.sourceTime
        // Count labels only within one screen. A new faction proves a
        // boundary even while the new screen's labels are still fading in.
        let sameScreen = best.map { current in
            evidence.sourceTime - current.sourceTime <= policy.sameScreen
                && !(current.faction != nil && evidence.faction != nil && current.faction != evidence.faction)
        } ?? false
        if !sameScreen {
            best = evidence
            badge = evidence.badgeHue
            return
        }
        if let hue = evidence.badgeHue { badge = hue }
        if let current = best, current.resonators.count > evidence.resonators.count { return }
        best = evidence
    }

    /// Called when a hack's Glyphs start: that hack's portal screen, with the
    /// latest badge hue, or nil. The screen is forgotten either way, so the
    /// next hack cannot inherit it. The Glyph count comes later, with input.
    public mutating func claim(at time: Double) -> PortalScreenEvidence? {
        guard time.isFinite else { return nil }
        claimedThrough = max(claimedThrough ?? time, time)
        defer { best = nil; badge = nil; lastReadAt = nil }
        guard let recent = best, recent.sourceTime <= time, time - recent.sourceTime <= policy.attachWindow else { return nil }
        return PortalScreenEvidence(sourceTime: recent.sourceTime, resonators: recent.resonators,
                                    unreadSlots: recent.unreadSlots, badgeHue: badge ?? recent.badgeHue,
                                    faction: recent.faction)
    }
}
