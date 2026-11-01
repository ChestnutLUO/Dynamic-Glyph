import Foundation
import GlyphRecognition

/// Bonus and accuracy figures over some hacks, kept as sums and counts so
/// days can be added together: an average of daily averages would weight a
/// day of two hacks like a day of twenty. Only what was read is counted: a
/// value not read is left out, never counted as zero.
///
/// Shared source: the app's Statistics and the Home Screen widget both
/// derive their figures from these, so they cannot disagree.
struct HackTally: Codable, Equatable, Sendable {
    var hacks = 0
    /// Final Hacking Bonuses only: a last-seen value may not be the one the
    /// game settled on.
    var hackingTotal = 0
    var hackingCount = 0
    var bestHacking: Int?
    var speedTotal = 0
    var speedCount = 0
    /// Slots whose verdict was read.
    var glyphsJudged = 0
    var glyphsAccepted = 0
    /// Input time and Glyphs of the hacks whose input was timed.
    var timedSeconds = 0.0
    var timedGlyphs = 0

    mutating func add(_ summary: HackResultSummary) {
        hacks += 1
        if let bonus = summary.hackingBonus, bonus.isFinal {
            hackingTotal += bonus.percent
            hackingCount += 1
            bestHacking = max(bestHacking ?? bonus.percent, bonus.percent)
        }
        if let bonus = summary.speedBonus, bonus.isFinal {
            speedTotal += bonus.percent
            speedCount += 1
        }
        for slot in summary.slots where slot.outcome != .unknown {
            glyphsJudged += 1
            if slot.outcome == .accepted { glyphsAccepted += 1 }
        }
        // A hack whose Glyphs weren't read has no time per Glyph.
        if let seconds = summary.inputSeconds, !summary.slots.isEmpty {
            timedSeconds += seconds
            timedGlyphs += summary.slots.count
        }
    }

    mutating func merge(_ other: HackTally) {
        hacks += other.hacks
        hackingTotal += other.hackingTotal
        hackingCount += other.hackingCount
        if let best = other.bestHacking { bestHacking = max(bestHacking ?? best, best) }
        speedTotal += other.speedTotal
        speedCount += other.speedCount
        glyphsJudged += other.glyphsJudged
        glyphsAccepted += other.glyphsAccepted
        timedSeconds += other.timedSeconds
        timedGlyphs += other.timedGlyphs
    }

    var averageHacking: Int? { Self.average(hackingTotal, of: hackingCount) }
    var averageSpeed: Int? { Self.average(speedTotal, of: speedCount) }
    var acceptedPercent: Int? { Self.percent(glyphsAccepted, of: glyphsJudged) }
    /// Total input time over total Glyphs, so a long hack counts for more.
    var secondsPerGlyph: Double? { timedGlyphs > 0 ? timedSeconds / Double(timedGlyphs) : nil }

    static func average(_ total: Int, of count: Int) -> Int? {
        count > 0 ? Int((Double(total) / Double(count)).rounded()) : nil
    }

    static func percent(_ part: Int, of whole: Int) -> Int? {
        whole > 0 ? Int((Double(part) * 100 / Double(whole)).rounded()) : nil
    }
}

/// Everything the Statistics summary counts over some hacks and drop groups,
/// as parts that add up: one local day's, or several days' merged in order.
struct StatisticsParts: Codable, Equatable, Sendable {
    /// One kind of item, its total split by level, or by rarity for items
    /// with a rarity meter.
    struct GearGroup: Codable, Equatable, Identifiable, Sendable {
        enum Split: Hashable, Codable, Sendable {
            case level(Int), levelUnread
            case rarity(GearDropEntry.Rarity)
            /// Highest level, then rarest, first; unread last.
            var order: Int {
                switch self {
                case .level(let level): return 8 - level
                case .levelUnread: return 9
                case .rarity(.veryRare): return 10
                case .rarity(.rare): return 11
                case .rarity(.common): return 12
                case .rarity(.unreadable): return 13
                }
            }
        }
        struct Chip: Codable, Equatable, Identifiable, Sendable {
            let split: Split
            var quantity: Int
            var id: Split { split }
        }
        /// As the English game prints it, in every language.
        let item: String
        var total = 0
        /// Of the total, from drops the game showed in red.
        var multiplied = 0
        /// Highest level, then rarest, first. Empty for items with neither,
        /// such as Portal Keys.
        var chips: [Chip] = []
        var id: String { item }

        mutating func add(_ split: Split, _ quantity: Int) {
            if let index = chips.firstIndex(where: { $0.split == split }) {
                chips[index].quantity += quantity
            } else {
                chips.append(.init(split: split, quantity: quantity))
                chips.sort { $0.split.order < $1.split.order }
            }
        }
    }

    /// The hacks of one length, and of each portal level the gear test read
    /// under a length several levels share.
    struct LengthPart: Codable, Equatable, Sendable {
        struct LevelPart: Codable, Equatable, Sendable {
            let level: Int
            var tally = HackTally()
        }
        let glyphs: Int
        var tally = HackTally()
        /// Lowest level first.
        var levels: [LevelPart] = []
    }

    var tally = HackTally()
    /// Hacks whose result screen was read in full, in part, or not seen.
    var resultsComplete = 0
    var resultsPartial = 0
    var resultsNotSeen = 0
    /// Our input check against the game, over the Glyphs both judged.
    var checkAgreements = 0
    var checkDisagreements = 0
    /// Fewest Glyphs first; hacks whose Glyphs weren't read have no length.
    var lengths: [LengthPart] = []

    /// Gear readings, of hacks and of drop groups no hack claimed: every
    /// panel read in full, partly read, or a hack's not read at all.
    var gearComplete = 0
    var gearPartial = 0
    var gearNotRead = 0
    /// Hacks with no gear kept: reading was off, or the gear was saved in a
    /// format this build can't read. Unknown, not zero.
    var gearNotKept = 0
    /// Drop groups no Glyph hack claimed.
    var drops = 0
    /// Items with a recognized name, whether or not their level was read.
    var items = 0
    /// Items the game showed with a red quantity: its multiplier applied.
    var multipliedItems = 0
    /// Of the items, those on a Bonus items panel.
    var bonusItems = 0
    /// By item, as the game names it.
    var gear: [String: GearGroup] = [:]

    /// The gear reading of a hack, as far as it went.
    enum HackGear {
        case read(GearDropSummary)
        case notRead
        /// None kept.
        case none
    }

    /// `portalLevel` is the level the gear test read, if any.
    mutating func addHack(_ summary: HackResultSummary, gear: HackGear, portalLevel: Int?) {
        tally.add(summary)
        switch summary.state {
        case .complete: resultsComplete += 1
        case .partial: resultsPartial += 1
        case .notObserved: resultsNotSeen += 1
        case .awaiting: break
        }
        for slot in summary.slots {
            switch slot.comparison {
            case .agreement: checkAgreements += 1
            case .disagreement: checkDisagreements += 1
            case .coverageGap, .unknownAssociation, .unknownGameOutcome: break
            }
        }
        let glyphs = summary.slots.count
        if glyphs > 0 {
            var part = LengthPart(glyphs: glyphs)
            part.tally.add(summary)
            // Only lengths several levels share are split by level.
            if let levels = PortalLevelRules.levels(forGlyphCount: glyphs), levels.count > 1,
               let level = portalLevel, levels.contains(level) {
                var levelPart = LengthPart.LevelPart(level: level)
                levelPart.tally.add(summary)
                part.levels = [levelPart]
            }
            merge(length: part)
        }
        switch gear {
        // The same test as the hack card's "N items recognized".
        case .read(let reading):
            add(reading, complete: reading.bothPanelsRead && reading.unidentifiedQuantity == 0)
        case .notRead: gearNotRead += 1
        case .none: gearNotKept += 1
        }
    }

    /// A drop group no Glyph hack claimed.
    mutating func addDrop(_ summary: GearDropSummary) {
        drops += 1
        // No Bonus panel can be expected of a group no hack claimed.
        add(summary, complete: summary.panelsReadInFull)
    }

    mutating func merge(_ other: StatisticsParts) {
        tally.merge(other.tally)
        resultsComplete += other.resultsComplete
        resultsPartial += other.resultsPartial
        resultsNotSeen += other.resultsNotSeen
        checkAgreements += other.checkAgreements
        checkDisagreements += other.checkDisagreements
        for part in other.lengths { merge(length: part) }
        gearComplete += other.gearComplete
        gearPartial += other.gearPartial
        gearNotRead += other.gearNotRead
        gearNotKept += other.gearNotKept
        drops += other.drops
        items += other.items
        multipliedItems += other.multipliedItems
        bonusItems += other.bonusItems
        for (item, group) in other.gear {
            var merged = gear[item] ?? GearGroup(item: item)
            merged.total += group.total
            merged.multiplied += group.multiplied
            for chip in group.chips { merged.add(chip.split, chip.quantity) }
            gear[item] = merged
        }
    }

    private mutating func merge(length part: LengthPart) {
        guard let index = lengths.firstIndex(where: { $0.glyphs == part.glyphs }) else {
            lengths.append(part)
            lengths.sort { $0.glyphs < $1.glyphs }
            return
        }
        lengths[index].tally.merge(part.tally)
        for level in part.levels {
            if let at = lengths[index].levels.firstIndex(where: { $0.level == level.level }) {
                lengths[index].levels[at].tally.merge(level.tally)
            } else {
                lengths[index].levels.append(level)
                lengths[index].levels.sort { $0.level < $1.level }
            }
        }
    }

    private mutating func add(_ summary: GearDropSummary, complete: Bool) {
        if complete { gearComplete += 1 } else { gearPartial += 1 }
        for panel in summary.panels {
            for entry in panel.entries {
                guard let item = entry.item else { continue }
                items += entry.quantity
                if panel.stage == .bonus { bonusItems += entry.quantity }
                var group = gear[item] ?? GearGroup(item: item)
                group.total += entry.quantity
                if entry.multiplied == true {
                    multipliedItems += entry.quantity
                    group.multiplied += entry.quantity
                }
                let split: GearGroup.Split? = switch entry.levelState {
                case .known: entry.level.map(GearGroup.Split.level)
                case .unreadable: .levelUnread
                // A fixed rarity holds for older records too; a meter not read
                // is an unread rarity.
                case .notApplicable:
                    entry.hasRarityMeter ? .rarity(entry.intrinsicRarity ?? entry.rarity ?? .unreadable) : nil
                }
                if let split { group.add(split, entry.quantity) }
                gear[item] = group
            }
        }
    }
}

/// One local day's parts, from its midnight.
struct StatisticsDay: Codable, Equatable, Sendable {
    let start: Date
    var parts = StatisticsParts()
}
