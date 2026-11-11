import Testing
@testable import GlyphRecognition

struct PortalKeyCounterTests {
    /// A fingerprint from a deterministic strip, distinct per seed.
    func fingerprint(_ seed: Int) -> NameRegionFingerprint {
        let image = try! LuminanceImage(width: 96, height: 32, pixels:
            (0..<(96 * 32)).map { UInt8((($0 % 97) * seed + $0 / 89) % 251) })
        return NameRegionFingerprint(image: image)
    }

    func reading(time: Double, seed: Int, count: Int?, name: String?,
                 kind: KeyCardKind = .inventory) -> KeyCardFrameReading {
        KeyCardFrameReading(sourceTime: time,
            card: KeyCardBounds(x: 0, y: 0, width: 100, height: 160, kind: kind),
            fingerprint: fingerprint(seed), count: count, name: name)
    }

    @Test("Repeated frames of one card read once")
    func sameCard() throws {
        var counter = PortalKeyCounter()
        #expect(counter.accept(reading(time: 1, seed: 3, count: 12, name: "Test Portal")) == .accepted)
        #expect(counter.accept(reading(time: 1.05, seed: 3, count: 12, name: "Test Portal")) == .sameCard)
        #expect(counter.accept(reading(time: 1.1, seed: 3, count: 12, name: "Test Portal")) == .sameCard)
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        #expect(summary.readings.map(\.name) == ["TestPortal"])
        #expect(summary.readings.map(\.count) == [12])
    }

    @Test("Different cards each read once, in frame order")
    func distinctCards() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 12, name: "Portal A"))
        counter.accept(reading(time: 1.05, seed: 3, count: 12, name: "Portal A"))
        counter.accept(reading(time: 1.1, seed: 5, count: 3, name: "Portal B"))
        counter.accept(reading(time: 1.15, seed: 7, count: 1, name: "Portal C"))
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        #expect(summary.readings.map(\.name) == ["PortalA", "PortalB", "PortalC"])
        #expect(summary.totals.map(\.name) == ["PortalA", "PortalB", "PortalC"])
        #expect(summary.totalKeys == 16)
    }

    @Test("The same portal browsed twice sums into one total")
    func aggregation() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 12, name: "Portal A"))
        counter.accept(reading(time: 1.05, seed: 5, count: 2, name: "Portal A!"))
        counter.accept(reading(time: 1.1, seed: 7, count: 1, name: "Portal B"))
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        // The name's punctuation cleaned away, both readings are the portal's.
        #expect(summary.totals == [KeyInventorySummary.Entry(name: "PortalA", count: 14),
                                   KeyInventorySummary.Entry(name: "PortalB", count: 1)])
    }

    @Test("Consecutive identical readings collapse; different counts do not")
    func consecutiveDuplicates() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 5, name: "Portal A"))
        counter.accept(reading(time: 1.05, seed: 9, count: 5, name: "Portal A")) // correlation miss
        counter.accept(reading(time: 1.1, seed: 11, count: 7, name: "Portal A")) // a real second stack
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        #expect(summary.readings.count == 2)
        #expect(summary.readings.map(\.count) == [5, 7])
        #expect(summary.totals.first?.count == 12)
    }

    @Test("A card whose name never read drops out of the summary")
    func unnamed() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 4, name: nil))
        counter.accept(reading(time: 1.05, seed: 5, count: 2, name: "Portal B"))
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        #expect(summary.readings.map(\.name) == ["PortalB"])
        #expect(summary.totals.map(\.count) == [2])
    }

    @Test("A count nobody read survives as an unknown")
    func unreadCount() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 2, name: "Portal A"))
        counter.accept(reading(time: 1.05, seed: 5, count: nil, name: "Portal A"))
        counter.accept(reading(time: 1.1, seed: 7, count: nil, name: "Portal B"))
        let summary = try #require(counter.finish(at: 2, reason: "done"))
        #expect(summary.totals == [KeyInventorySummary.Entry(name: "PortalA", count: 2),
                                   KeyInventorySummary.Entry(name: "PortalB", count: nil)])
        #expect(summary.totalKeys == 2)
    }

    @Test("A reading gap breaks the same-card decision")
    func gapBreaks() throws {
        var counter = PortalKeyCounter()
        #expect(PortalKeyCounter.Policy().maximumReadingGap == 2.0)
        counter.accept(reading(time: 1, seed: 3, count: 12, name: "Portal A"))
        // The same strip three seconds later is another look, not the card.
        // The second stack shows a different count, so the collapse of equal
        // consecutive readings does not hide it.
        #expect(counter.accept(reading(time: 4, seed: 3, count: 8, name: "Portal A")) == .accepted)
        let summary = try #require(counter.finish(at: 5, reason: "done"))
        #expect(summary.readings.count == 2)
        #expect(summary.readings.map(\.count) == [12, 8])
        #expect(summary.totals.first?.count == 20)
    }

    @Test("Readings out of frame order are refused")
    func outOfOrder() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 2, seed: 3, count: 1, name: "Portal A"))
        #expect(counter.accept(reading(time: 1.5, seed: 5, count: 2, name: "Portal B")) == .outOfOrder)
        #expect(counter.accept(reading(time: 2, seed: 5, count: 2, name: "Portal B")) == .outOfOrder)
        let summary = try #require(counter.finish(at: 3, reason: "done"))
        #expect(summary.readings.map(\.name) == ["PortalA"])
    }

    @Test("An invalid time is refused and never starts a pass")
    func invalidTime() throws {
        var counter = PortalKeyCounter()
        #expect(counter.accept(reading(time: .infinity, seed: 3, count: 1, name: "Portal A")) == .invalidTime)
        #expect(!counter.isObserving)
        #expect(counter.finish(at: 1, reason: "done") == nil)
    }

    @Test("Finishing closes the pass; a second finish reads nothing")
    func finishOnce() throws {
        var counter = PortalKeyCounter()
        counter.accept(reading(time: 1, seed: 3, count: 1, name: "Portal A"))
        let first = try #require(counter.finish(at: 2, reason: "done"))
        #expect(first.startedAt == 1 && first.closedAt == 2 && first.closeReason == "done")
        #expect(!counter.isObserving)
        #expect(counter.finish(at: 3, reason: "again") == nil)
        // The counter is reusable after a finish.
        counter.accept(reading(time: 4, seed: 5, count: 2, name: "Portal B"))
        let second = try #require(counter.finish(at: 5, reason: "again"))
        #expect(second.startedAt == 4)
    }
}
