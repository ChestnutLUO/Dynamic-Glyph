import Foundation
import Testing
@testable import GlyphRecognition
@testable import GlyphRecognitionCxx

/// Two confirmed values of one cell that contradict each other are settled
/// by how many reads support each, in both logic arms. The read sequences are
/// the ones logged for the red "x2 Portal Shield" cell of a field recording's
/// hack 12.
@Suite("Gear tracker: contradicting values settled by read support")
struct GearConflictSupportTests {
    enum Arm: String, CaseIterable, CustomStringConvertible {
        case swift, cpp
        var description: String { rawValue }
        func tracker() -> any GearDropTracking {
            switch self {
            case .swift: GearDropTracker()
            case .cpp: CxxGearDropTracker()
            }
        }
    }

    /// One read of the cell: quantity, and optionally a lost name or rarity.
    struct Read {
        var quantity = 2
        var item: String? = "Portal Shield"
        var rarity: GearDropEntry.Rarity? = .common
        var multiplied: Bool? = true
        var effect: String?
    }

    static func right(_ count: Int) -> [Read] { Array(repeating: Read(), count: count) }
    static func misread(_ count: Int) -> [Read] {
        Array(repeating: Read(quantity: 21, multiplied: nil), count: count)
    }

    /// Feeds the reads 0.2 s apart, the phone's gear pace, to one panel and
    /// returns that panel when the group closes.
    static func panel(_ reads: [Read], arm: Arm, stage: GearDropStage = .portal, start: Double = 465.278,
                      step: Double = 0.2) throws -> GearDropSummary.Panel {
        var tracker = arm.tracker()
        for (index, read) in reads.enumerated() {
            let entry = GearDropEntry(column: 0, row: 0, item: read.item, levelState: .notApplicable, level: nil,
                                      quantity: read.quantity, rarity: read.rarity, multiplied: read.multiplied)
            _ = tracker.accept(.init(sourceTime: start + Double(index) * step, stage: stage, entries: [entry],
                                     effects: read.effect.map { [$0] }))
        }
        let finished = tracker.finish(at: start + Double(reads.count) * step, reason: "test")
        let summary = try #require(finished)
        return try #require(summary.panels.first)
    }

    static func expectShield(_ panel: GearDropSummary.Panel, quantity: Int = 2, multiplied: Bool? = true,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let entry = panel.entries.first
        #expect(panel.partial == false && panel.entries.count == 1, sourceLocation: sourceLocation)
        #expect(entry?.item == "Portal Shield" && entry?.quantity == quantity && entry?.rarity == .common
                && entry?.multiplied == multiplied, sourceLocation: sourceLocation)
    }

    static func expectLost(_ panel: GearDropSummary.Panel, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(panel.partial && panel.entries.isEmpty, sourceLocation: sourceLocation)
    }

    @Test("Two adjacent misreads among six right reads keep the red x2 cell, as on a phone",
          arguments: Arm.allCases)
    func phoneCase(_ arm: Arm) throws {
        try Self.expectShield(Self.panel(Self.right(4) + Self.misread(2) + Self.right(2), arm: arm))
    }

    @Test("An adjacent misread pair at the start, middle or end does not cost the cell", arguments: Arm.allCases)
    func pairAnywhere(_ arm: Arm) throws {
        for reads in [Self.misread(2) + Self.right(4), Self.right(2) + Self.misread(2) + Self.right(2),
                      Self.right(4) + Self.misread(2)] {
            try Self.expectShield(Self.panel(reads, arm: arm))
        }
    }

    @Test("The Bonus panel's logged frames at the phone's pace: three misreads, seven right reads",
          arguments: Arm.allCases)
    func loggedBonusFrames(_ arm: Arm) throws {
        // glyph-replay --gear exhaustive on that recording (Mac Vision, zh-Hans,
        // lean off), every fourth frame from 467.278 s: x21 at 467.478,
        // 467.878 and 468.078, so 467.878 and 468.078 confirm it.
        let quantities = [2, 21, 2, 21, 21, 2, 2, 2, 2, 2]
        let reads = quantities.map { $0 == 2 ? Read() : Read(quantity: 21, multiplied: nil) }
        try Self.expectShield(Self.panel(reads, arm: arm, stage: .bonus, start: 467.278))
    }

    @Test("Close support leaves the cell out and the panel partial, in any order", arguments: Arm.allCases)
    func closeSupport(_ arm: Arm) throws {
        for reads in [Self.right(2) + Self.misread(2), Self.misread(2) + Self.right(2),
                      Self.right(3) + Self.misread(2), Self.misread(2) + Self.right(3),
                      Self.right(2) + Self.misread(2) + Self.right(1),
                      Self.right(3) + Self.misread(3), Self.right(5) + Self.misread(3)] {
            try Self.expectLost(Self.panel(reads, arm: arm))
        }
    }

    @Test("The answer does not depend on where the misread pair falls", arguments: Arm.allCases)
    func orderIndependent(_ arm: Arm) throws {
        // From three right reads, every split leaves a run of two that
        // confirms x2, so both values are always confirmed.
        for right in 3...6 {
            var outcomes = Set<Bool>()
            for split in 0...right {
                let panel = try Self.panel(Self.right(split) + Self.misread(2) + Self.right(right - split), arm: arm)
                outcomes.insert(panel.partial)
            }
            // Four or more right reads against two settle; three never do.
            #expect(outcomes == [right < 4], "right reads: \(right)")
        }
    }

    @Test("A refinement read after the contradiction still settles the cell with its detail",
          arguments: Arm.allCases)
    func refinementAfterContradiction(_ arm: Arm) throws {
        let unread = Read(rarity: .unreadable)
        try Self.expectShield(Self.panel(Array(repeating: unread, count: 4) + Self.misread(2) + Self.right(2),
                                         arm: arm))
    }

    @Test("Reads that lost the name support the quantity they read, but not a name", arguments: Arm.allCases)
    func generalizations(_ arm: Arm) throws {
        // Quantity 2 was read four times, two of them without a name.
        let nameless = Read(item: nil, rarity: nil)
        try Self.expectShield(Self.panel(Self.right(2) + Array(repeating: nameless, count: 2) + Self.misread(2),
                                         arm: arm))
        // Two names read twice each: nameless reads take neither side.
        let other = Read(item: "Heat Sink")
        try Self.expectLost(Self.panel(Self.right(2) + Array(repeating: other, count: 2)
                                       + Array(repeating: nameless, count: 4), arm: arm))
    }

    @Test("A late single misread unseats a value only two reads support, not three", arguments: Arm.allCases)
    func lateMinority(_ arm: Arm) throws {
        try Self.expectShield(Self.panel(Self.right(3) + Self.misread(1), arm: arm))
        try Self.expectLost(Self.panel(Self.right(2) + Self.misread(1), arm: arm))
    }

    @Test("Colour is voted only by reads of the settled quantity", arguments: Arm.allCases)
    func colourVote(_ arm: Arm) throws {
        // The misreads were red too; they do not vote on quantity 2's colour.
        let redMisread = Array(repeating: Read(quantity: 21, multiplied: true), count: 2)
        try Self.expectShield(Self.panel(Self.right(4) + redMisread + Self.right(2), arm: arm))
        let white = Array(repeating: Read(multiplied: false), count: 2)
        try Self.expectShield(Self.panel(Self.right(4) + Self.misread(2) + white, arm: arm), multiplied: nil)
    }

    @Test("The effect line follows the same rule", arguments: Arm.allCases)
    func effect(_ arm: Arm) throws {
        func reads(_ effects: [String]) -> [Read] { effects.map { Read(effect: $0) } }
        let plus = "ITO EN (+)", minus = "ITO EN (-)"
        let settled = try Self.panel(reads([plus, plus, plus, plus, minus, minus, plus, plus]), arm: arm)
        #expect(settled.effects == [plus] && settled.partial == false)
        let close = try Self.panel(reads([plus, plus, minus, minus]), arm: arm)
        #expect(close.effects == nil && close.partial)
    }
}
