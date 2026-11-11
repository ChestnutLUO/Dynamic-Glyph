/// Counts portal keys from consecutive key-card frames.
///
/// The port of CountIngressKeys' counting loop. Each frame's reading is
/// compared with the previous one by the correlation of their name-strip
/// fingerprints: 0.75 or more is the same card seen again, and only the
/// fingerprint is refreshed — the strip is not OCR'd again. Below it, the
/// frame is a new card, and its count and cleaned name are recorded.
///
/// `finish` produces the summary: entries with no readable name are dropped
/// (as the original drops empty names), consecutive same-name same-count
/// entries are collapsed (the original deletes the first of every adjacent
/// equal pair, which would lose a count when two real stacks of one portal
/// were browsed in a row), and totals are summed per name.
public struct PortalKeyCounter: Sendable {
    public struct Policy: Sendable {
        /// At or above this name-strip correlation, two frames are the same
        /// card. CountIngressKeys compares raw crops at 0.75.
        public var sameCardCorrelation = 0.75
        /// A gap this long between analyzed frames is not scroll: the same
        /// fingerprint across it is a new look at a new card, never the old
        /// one.
        public var maximumReadingGap = 2.0
        public init() {}
    }

    /// What the last `accept` did with its reading.
    public enum Disposition: String, Sendable {
        case accepted, sameCard, invalidTime, outOfOrder
    }

    public let policy: Policy
    public private(set) var disposition: Disposition?
    private var readings: [(name: String?, count: Int?)] = []
    private var previous: (fingerprint: NameRegionFingerprint, time: Double)?
    private var startedAt: Double?
    private var lastReadingTime: Double = -.infinity

    /// True once a reading has been accepted and not finished.
    public var isObserving: Bool { startedAt != nil }

    public init(policy: Policy = Policy()) { self.policy = policy }

    public mutating func reset() {
        readings = []; previous = nil; startedAt = nil
        lastReadingTime = -.infinity
        disposition = nil
    }

    public mutating func accept(_ reading: KeyCardFrameReading) -> Disposition {
        let time = reading.sourceTime
        guard time.isFinite else { disposition = .invalidTime; return .invalidTime }
        guard time > lastReadingTime else { disposition = .outOfOrder; return .outOfOrder }
        lastReadingTime = time
        if startedAt == nil { startedAt = time }
        let sameCard: Bool
        if let previous, time - previous.time <= policy.maximumReadingGap + 1e-9,
           reading.fingerprint.correlation(with: previous.fingerprint) >= policy.sameCardCorrelation {
            sameCard = true
        } else {
            sameCard = false
        }
        previous = (reading.fingerprint, time)
        if sameCard {
            disposition = .sameCard
            return .sameCard
        }
        readings.append((name: reading.name, count: reading.count))
        disposition = .accepted
        return .accepted
    }

    /// Closes the pass and produces its summary, once per observation. A
    /// second call, or one with nothing observed, reads nothing.
    public mutating func finish(at time: Double, reason: String) -> KeyInventorySummary? {
        guard let startedAt, time.isFinite else { return nil }
        let closedAt = max(startedAt, time)
        let entries = readings.map { reading -> KeyInventorySummary.Entry in
            let name = reading.name.map { KeyNameCleaning.cleaned($0) } ?? ""
            return KeyInventorySummary.Entry(name: name, count: reading.count)
        }
        var distinct: [KeyInventorySummary.Entry] = []
        for entry in entries where !entry.name.isEmpty {
            if let last = distinct.last, last.name == entry.name, last.count == entry.count { continue }
            distinct.append(entry)
        }
        var counts: [String: [Int?]] = [:]
        for entry in distinct { counts[entry.name, default: []].append(entry.count) }
        let totals = counts
            .map { name, values -> KeyInventorySummary.Entry in
                let known = values.compactMap { $0 }
                return KeyInventorySummary.Entry(name: name, count: known.isEmpty ? nil : known.reduce(0, +))
            }
            .sorted { $0.name < $1.name }
        let summary = KeyInventorySummary(readings: distinct, totals: totals,
                                          startedAt: startedAt, closedAt: closedAt, closeReason: reason)
        reset()
        return summary
    }
}
