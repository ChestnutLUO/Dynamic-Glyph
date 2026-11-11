/// The key counts one pass over a key inventory produced.
///
/// `readings` holds one entry per distinct card, in the order the frames
/// showed them — the original script's first two columns. `totals` holds one
/// entry per distinct cleaned portal name, sorted by name, with a key's
/// copies from different surfaces (a capsule and the inventory) summed — the
/// last two columns' purpose: two readings of one portal under slightly
/// different names stand out side by side.
public struct KeyInventorySummary: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let name: String
        /// The sum of this name's known counts; nil when none of its cards'
        /// quantities were read.
        public let count: Int?

        public init(name: String, count: Int?) {
            self.name = name; self.count = count
        }
    }

    /// One entry per distinct card, in observation order. Consecutive
    /// entries of the same name with the same count are collapsed — a
    /// correlation miss of the same card, not a second one.
    public let readings: [Entry]
    /// One entry per distinct name, sorted by name, counts summed.
    public let totals: [Entry]
    /// The sum of every known count, across all names.
    public var totalKeys: Int {
        readings.compactMap(\.count).reduce(0, +)
    }
    public let startedAt: Double
    public let closedAt: Double
    public let closeReason: String

    public init(readings: [Entry], totals: [Entry], startedAt: Double, closedAt: Double, closeReason: String) {
        self.readings = readings; self.totals = totals
        self.startedAt = startedAt; self.closedAt = closedAt; self.closeReason = closeReason
    }
}
