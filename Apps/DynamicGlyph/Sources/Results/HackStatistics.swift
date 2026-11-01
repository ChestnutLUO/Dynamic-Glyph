import Foundation
import GlyphRecognition

/// Totals over the results in one period, for the Statistics page's summary
/// card and its details. Only what was read is counted: a value that was not
/// read is left out, never counted as zero.
///
/// The summary's figures come from `StatisticsFigures`, built from each local
/// day's `StatisticsParts`, which the Home Screen widget is given too; only
/// what needs every record (Glyphs, commands, activity) is counted here.
struct HackStatistics: Equatable, StatisticsPanelFigures {
    typealias Period = StatisticsPeriod
    typealias BonusPoint = StatisticsFigures.BonusPoint
    typealias LengthRow = StatisticsFigures.LengthRow
    typealias Change = StatisticsFigures.Change
    typealias GearGroup = StatisticsParts.GearGroup

    struct GlyphLine: Equatable, Identifiable {
        /// As the game names it.
        let glyph: String
        /// Slots where the game's verdict was read.
        var judged = 0
        var accepted = 0
        /// Measured drawing times. A hack's last Glyph is never timed, so
        /// the count is shown beside the median.
        var drawTimes: [Double] = []
        var id: String { glyph }
        var acceptedPercent: Int? { HackStatistics.percent(accepted, of: judged) }
        var medianDrawSeconds: Double? {
            guard !drawTimes.isEmpty else { return nil }
            let sorted = drawTimes.sorted(), middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
    }

    /// Which command a hack's row counts under. Drone hacks can't get keys,
    /// so they stay out of the key-command comparison.
    enum CommandGroup: Hashable {
        case command(HackCommand)
        case none, uncertain, drone
        var order: Int {
            switch self {
            case .command(let command): return HackCommand.allCases.firstIndex(of: command) ?? 0
            case .none: return 10
            case .uncertain: return 11
            case .drone: return 12
            }
        }

        /// The key-request group of a hack; nil for history saved before
        /// commands were read.
        static func keys(_ commands: HackCommandSummary?) -> CommandGroup? {
            guard let commands else { return nil }
            if commands.mode == .drone { return .drone }
            return group(commands.gear)
        }

        static func speed(_ commands: HackCommandSummary?) -> CommandGroup? {
            commands.map { group($0.presentation) }
        }

        private static func group(_ selection: HackCommandSummary.Selection) -> CommandGroup {
            switch selection.status {
            case .confirmed: return selection.effective.map(CommandGroup.command) ?? .uncertain
            case .noCommandObserved: return .none
            case .unresolved, .notApplicable: return .uncertain
            }
        }
    }

    /// Gear per hack under one key command. Only hacks whose gear was read in
    /// full, with no multiplied drop, are measured: a partial reading would
    /// undercount, and a first hack of the day would inflate its command.
    struct KeyCommandRow: Equatable, Identifiable {
        let group: CommandGroup
        var hacks = 0
        var measured = 0
        var keys = 0
        var otherItems = 0
        var keysPerHack: Double? { measured > 0 ? Double(keys) / Double(measured) : nil }
        var otherItemsPerHack: Double? { measured > 0 ? Double(otherItems) / Double(measured) : nil }
        var id: CommandGroup { group }
    }

    /// Bonuses and accuracy under one presentation-speed command.
    struct SpeedCommandRow: Equatable, Identifiable {
        let group: CommandGroup
        let hacks: Int
        let hacking: Int?
        let speed: Int?
        let accepted: Int?
        var id: CommandGroup { group }
    }

    /// Hacks in one hour for Today, or in one day otherwise.
    struct ActivityBucket: Equatable, Identifiable {
        let start: Date
        let hacks: Int
        var id: Date { start }
    }

    /// Items read in one hour or day, from hacks' gear and drops alike.
    struct ItemBucket: Equatable, Identifiable {
        let start: Date
        let items: Int
        var id: Date { start }
    }

    /// One bar of the items chart, empty ones too: drawn over its whole
    /// clock hour or day, but covering only `span`, the part inside the
    /// range, which is what VoiceOver says ("4:43 – 5:00 PM, 0 items").
    struct ItemSlot: Equatable, Identifiable {
        /// The hour's or day's start, where the bar sits.
        let start: Date
        /// The part of that hour or day the range covers.
        let span: Range<Date>
        let items: Int
        var id: Date { start }
    }

    /// The smallest sample a Glyph needs before it is ranked.
    static let minimumAttempts = 3

    var hacks = 0
    /// Hacks whose result screen was read in full, in part, or not seen.
    var resultsComplete = 0
    var resultsPartial = 0
    var resultsNotSeen = 0
    /// The period's bonuses and accuracy, as sums.
    private var tally = HackTally()
    var glyphsJudged = 0
    var glyphsAccepted = 0
    /// Most judged first.
    var glyphs: [GlyphLine] = []
    /// Our input check against the game, over the Glyphs both judged.
    var checkAgreements = 0
    var checkDisagreements = 0

    /// Oldest first, one point per day; empty for Today.
    var bonusPoints: [BonusPoint] = []
    /// Oldest first, only hours or days with hacks.
    var activity: [ActivityBucket] = []
    /// The days a day chart spans, through the end of today: all seven for
    /// 7 days, from the first hack for All. Nil for Today.
    var chartDays: Range<Date>?
    /// Against yesterday for Today and the 7 days before for 7 days; nil for
    /// All and when the previous period had no hacks. Bonuses are left out
    /// while lengths are mixed: a different mix of portals would move them.
    var change: Change?
    /// The range's hacks just before it may be only partly kept, so no
    /// change is shown rather than one against missing records.
    var comparisonUnavailable = false
    /// Hacks in the interval compared with, where it is fully kept; nil
    /// where nothing is compared. Zero is a measured zero: the count is
    /// compared with it, the bonuses aren't.
    var previousHacks: Int?
    /// Hours for one day, days otherwise.
    var hourly = false
    /// The period the shared chart and figure views draw for: Today for one
    /// day, 7 days for up to a week, All for longer.
    var chartPeriod = StatisticsPeriod.today
    /// What the hourly charts span: the shown day, or a shorter range out
    /// to whole hours, so the first and last hours' bars fit inside.
    var hours: Range<Date>?
    /// Items by hour for a range up to 48 hours, by day otherwise; oldest
    /// first, only buckets with items. Statistics ranges only.
    var itemBuckets: [ItemBucket] = []
    /// Items against the interval just before; nil for All, where the drops
    /// before aren't all kept, and where that interval's items are unknown
    /// (gear not read or not kept). An interval kept in full with nothing
    /// in it is a measured zero, compared with as such.
    var itemChange: Int?
    /// The drops just before the range may be only partly kept.
    var itemComparisonUnavailable = false
    /// Hack lengths played in the period, fewest Glyphs first.
    var lengths: [Int] = []
    /// Every length played in the period, each followed by its portal levels.
    var lengthRows: [LengthRow] = []
    /// By key command, then no command, uncertain and drone; only hacks whose
    /// commands were read, so older history is left out.
    var keyCommandRows: [KeyCommandRow] = []
    var speedCommandRows: [SpeedCommandRow] = []
    /// Input time over Glyphs, pooled over hacks whose input was timed.
    var secondsPerGlyph: Double?

    /// Gear readings, of hacks and of drop groups no hack claimed: every
    /// panel read in full, partly read, or a hack's not read at all.
    var gearComplete = 0
    var gearPartial = 0
    var gearNotRead = 0
    /// Drop groups no Glyph hack claimed: ordinary hacks', uncertain ones,
    /// and every group read without Glyph assistance. Groups, not hacks: a
    /// queued or missed panel can leave their number off the hacks played.
    var drops = 0
    /// Items with a recognized name, whether or not their level was read.
    var items = 0
    /// Items the game showed with a red quantity: its multiplier applied.
    var multipliedItems = 0
    /// Of the items, those on a Bonus items panel.
    var bonusItems = 0
    /// Hacks with no gear kept: reading was off, or it was saved in a format
    /// this build can't read.
    var gearNotKept = 0
    /// Most first.
    var gear: [GearGroup] = []

    var averageHackingBonus: Int? { tally.averageHacking }
    var bestHackingBonus: Int? { tally.bestHacking }
    var averageSpeedBonus: Int? { tally.averageSpeed }
    var acceptedPercent: Int? { tally.acceptedPercent }
    var hasGear: Bool { gearComplete + gearPartial + gearNotRead > 0 }
    /// Only drop groups: gear read without Glyph hacks.
    var onlyDrops: Bool { hacks == 0 && drops > 0 }
    /// Several lengths are counted together, so bonuses aren't like for like.
    var mixesLengths: Bool { lengths.count > 1 }
    /// One row per length, without the level rows, for a chart.
    var lengthAverages: [LengthRow] { lengthRows.filter { $0.level == nil } }
    /// Readings not complete, so totals may be low. Rows or panels never
    /// seen are not counted here either: this is coverage of what was seen.
    var gearIncomplete: Int { gearPartial + gearNotRead }
    /// Items over the drop groups read, a hack's own or not.
    /// Drops read, in full or in part: a hack's item panels or a group of
    /// them no hack claimed. Not `drops`, which counts only the latter.
    var dropsRead: Int { gearComplete + gearPartial }

    var itemsPerDrop: Double? {
        dropsRead > 0 ? Double(items) / Double(dropsRead) : nil
    }

    /// The Items dropped card's gear row: every kind with five or fewer,
    /// else the top four, which Other follows with the items of all the rest:
    /// a count of items, not of the kinds left out. Other is 0 when none remain.
    var gearRow: (shown: [GearGroup], other: Int) {
        let shown = gear.count <= 5 ? gear : Array(gear.prefix(4))
        return (shown, max(0, items - shown.map(\.total).reduce(0, +)))
    }

    /// Lowest accepted first, then most attempted; up to ten.
    var weakestGlyphs: [GlyphLine] {
        Array(glyphs.filter { $0.judged >= Self.minimumAttempts }
            .sorted { ($0.acceptedPercent ?? 0, $1.judged, $0.glyph) < ($1.acceptedPercent ?? 0, $0.judged, $1.glyph) }
            .prefix(10))
    }

    /// Slowest median first; up to twelve.
    var drawTimeGlyphs: [GlyphLine] {
        Array(glyphs.filter { $0.drawTimes.count >= Self.minimumAttempts }
            .sorted { ($0.medianDrawSeconds ?? 0, $1.glyph) > ($1.medianDrawSeconds ?? 0, $0.glyph) }
            .prefix(12))
    }

    /// The period's first moment; nil for All.
    static func start(of period: Period, now: Date, calendar: Calendar = .current) -> Date? {
        period.start(now: now, calendar: calendar)
    }

    init(records: [HackResultRecord], drops dropRecords: [GearDropRecord] = [], period: Period, now: Date,
         calendar: Calendar = .current) {
        let start = Self.start(of: period, now: now, calendar: calendar)
        // The previous period's days too, for the change against it.
        let earliest = period.previousStart(now: now, calendar: calendar) ?? start
        let figures = StatisticsFigures(period: period, days: Self.days(records: records, drops: dropRecords,
                                                                        from: earliest, calendar: calendar),
                                        now: now, calendar: calendar)
        adopt(figures)
        chartPeriod = period
        hourly = period == .today
        if hourly {
            let today = calendar.startOfDay(for: now)
            hours = calendar.date(byAdding: .day, value: 1, to: today).map { today..<$0 }
        }
        count(records.filter { record in record.summary != nil && start.map { record.date >= $0 } ?? true },
              calendar: calendar)
    }

    /// The Statistics page's range. `history` decides whether the interval
    /// before it is kept well enough to compare with; without it, nothing
    /// is compared.
    init(records: [HackResultRecord], drops dropRecords: [GearDropRecord] = [], range: StatisticsRange,
         history: StatisticsHistory?, now: Date, calendar: Calendar = .current) {
        let (current, currentDrops) = range.filter(records: records, drops: dropRecords)
        let days = range.dayCount(calendar: calendar)
        let oneDay = range.wholeDays ? days == 1
            : range.interval.map { $0.upperBound.timeIntervalSince($0.lowerBound) <= 86_400 } ?? false
        let period: StatisticsPeriod = range.isAll ? .all : oneDay ? .today : (days ?? 0) <= 7 ? .week : .all
        var previousDays: [StatisticsDay]?
        var previousParts: StatisticsParts?
        if let previous = range.comparisonInterval(calendar: calendar) {
            let before = Self.days(records: records.filter { previous.contains($0.date) },
                                   drops: dropRecords.filter { previous.contains($0.date) },
                                   from: nil, calendar: calendar)
            if history?.hacksComparable(range, calendar: calendar) == true {
                previousDays = before
            } else {
                comparisonUnavailable = true
            }
            // Items have their own history: drops kept, not hacks.
            if history?.dropsComparable(range, calendar: calendar) == true {
                var parts = StatisticsParts()
                for day in before { parts.merge(day.parts) }
                previousParts = parts
            } else {
                itemComparisonUnavailable = true
            }
        }
        let currentDays = Self.days(records: current, drops: currentDrops, from: nil, calendar: calendar)
        let chartDays: Range<Date>?
        if period == .today {
            chartDays = nil
        } else if let interval = range.interval {
            chartDays = interval
        } else {
            // All: from the first day with hacks through tonight, as before.
            let today = calendar.startOfDay(for: now)
            let first = currentDays.filter { $0.parts.tally.hacks > 0 }.map(\.start).min()
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            chartDays = first.flatMap { $0 < end ? $0..<end : nil }
        }
        adopt(StatisticsFigures(period: period, current: currentDays, previous: previousDays, chartDays: chartDays))
        if let previousDays {
            let before = previousDays.map(\.parts.tally.hacks).reduce(0, +)
            previousHacks = before
            // Kept in full and empty: the count is compared with zero, as
            // "Up 2 from 1:43 – 4:43 PM"; the bonuses have nothing to compare.
            if change == nil {
                change = Change(hacks: hacks - before, hacking: nil, speed: nil, accepted: nil, secondsPerGlyph: nil)
            }
        }
        if comparisonUnavailable && hacks == 0 { comparisonUnavailable = false }
        if let previousParts {
            if previousParts.gearComplete + previousParts.gearPartial > 0 {
                itemChange = items - previousParts.items
            } else if previousParts.gearNotRead == 0 && previousParts.gearNotKept == 0 {
                // No gear at all before, and none unread: nothing dropped.
                itemChange = items
            }
        }
        if itemComparisonUnavailable && dropsRead == 0 { itemComparisonUnavailable = false }
        chartPeriod = period
        hourly = range.isShort(calendar: calendar)
        if hourly, let interval = range.interval {
            let start = calendar.dateInterval(of: .hour, for: interval.lowerBound)?.start ?? interval.lowerBound
            let end = calendar.dateInterval(of: .hour, for: interval.upperBound.addingTimeInterval(-1))?.end
            hours = start..<max(end ?? interval.upperBound, interval.upperBound)
        }
        itemBuckets = Self.itemBuckets(records: current, drops: currentDrops, unit: hourly ? .hour : .day,
                                       calendar: calendar)
        count(current.filter { $0.summary != nil }, calendar: calendar)
    }

    /// Every hour or day of `domain` the range covers, in order, with its
    /// items, zero included. The first and last may cover part of theirs:
    /// a Last… choice keeps whole clock hours on the chart. Slots ending by
    /// `historyStart` are left out: before the drops kept is unknown, not 0.
    static func itemSlots(buckets: [ItemBucket], domain: Range<Date>, range: Range<Date>?,
                          unit: Calendar.Component, historyStart: Date? = nil,
                          calendar: Calendar = .current) -> [ItemSlot] {
        let items = Dictionary(buckets.map { ($0.start, $0.items) }, uniquingKeysWith: +)
        let lower = max(domain.lowerBound, range?.lowerBound ?? domain.lowerBound)
        let upper = min(domain.upperBound, range?.upperBound ?? domain.upperBound)
        guard lower < upper else { return [] }
        var slots: [ItemSlot] = []
        var cursor = lower
        while cursor < upper, let bucket = calendar.dateInterval(of: unit, for: cursor), bucket.end > cursor {
            let span = max(bucket.start, lower)..<min(bucket.end, upper)
            if historyStart.map({ span.upperBound > $0 }) ?? true {
                slots.append(ItemSlot(start: bucket.start, span: span, items: items[bucket.start] ?? 0))
            }
            cursor = bucket.end
        }
        return slots
    }

    /// Items counted as the totals count them, per hour or day.
    static func itemBuckets(records: [HackResultRecord], drops: [GearDropRecord], unit: Calendar.Component,
                            calendar: Calendar = .current) -> [ItemBucket] {
        var parts: [Date: StatisticsParts] = [:]
        func start(_ date: Date) -> Date { calendar.dateInterval(of: unit, for: date)?.start ?? date }
        for record in records {
            guard let summary = record.summary else { continue }
            let gear: StatisticsParts.HackGear = switch record.gear?.reading {
            case .read(let reading): .read(reading)
            case .notRead: .notRead
            case nil: .none
            }
            parts[start(record.date), default: StatisticsParts()]
                .addHack(summary, gear: gear, portalLevel: record.gear?.portalLevel?.level)
        }
        for record in drops {
            guard let drop = record.drop else { continue }
            parts[start(record.date), default: StatisticsParts()].addDrop(drop.summary)
        }
        return parts.filter { $0.value.items > 0 }.map { ItemBucket(start: $0.key, items: $0.value.items) }
            .sorted { $0.start < $1.start }
    }

    private mutating func adopt(_ figures: StatisticsFigures) {
        let parts = figures.parts
        tally = parts.tally
        hacks = tally.hacks
        resultsComplete = parts.resultsComplete
        resultsPartial = parts.resultsPartial
        resultsNotSeen = parts.resultsNotSeen
        glyphsJudged = tally.glyphsJudged
        glyphsAccepted = tally.glyphsAccepted
        checkAgreements = parts.checkAgreements
        checkDisagreements = parts.checkDisagreements
        bonusPoints = figures.bonusPoints
        chartDays = figures.chartDays
        change = figures.change
        lengths = figures.lengths
        lengthRows = figures.lengthRows
        secondsPerGlyph = tally.secondsPerGlyph
        gearComplete = parts.gearComplete
        gearPartial = parts.gearPartial
        gearNotRead = parts.gearNotRead
        gearNotKept = parts.gearNotKept
        drops = parts.drops
        items = parts.items
        multipliedItems = parts.multipliedItems
        bonusItems = parts.bonusItems
        gear = figures.gear
    }

    /// What needs every record: commands, Glyphs and activity.
    private mutating func count(_ records: [HackResultRecord], calendar: Calendar) {
        let current = records.sorted { $0.date < $1.date }
        keyCommandRows = Self.keyCommandRows(current)
        speedCommandRows = Self.speedCommandRows(current)
        var glyphLines: [String: GlyphLine] = [:]
        for summary in current.compactMap(\.summary) {
            for slot in summary.slots where slot.outcome != .unknown {
                guard let name = slot.glyph else { continue }
                var line = glyphLines[name] ?? GlyphLine(glyph: name)
                line.judged += 1
                if slot.outcome == .accepted { line.accepted += 1 }
                if let seconds = slot.drawSeconds { line.drawTimes.append(seconds) }
                glyphLines[name] = line
            }
        }
        glyphs = glyphLines.values.sorted { ($0.judged, $1.glyph) > ($1.judged, $0.glyph) }
        let unit: Calendar.Component = hourly ? .hour : .day
        activity = Dictionary(grouping: current) { calendar.dateInterval(of: unit, for: $0.date)?.start ?? $0.date }
            .map { ActivityBucket(start: $0.key, hacks: $0.value.count) }
            .sorted { $0.start < $1.start }
    }

    /// Each local day's parts, from `start` on (everything when nil), in no
    /// particular order. Hacks this build can't read and drops in an unknown
    /// format are left out, as they are from every figure.
    static func days(records: [HackResultRecord], drops: [GearDropRecord], from start: Date?,
                     calendar: Calendar = .current) -> [StatisticsDay] {
        var days: [Date: StatisticsDay] = [:]
        func add(at date: Date, _ change: (inout StatisticsParts) -> Void) {
            let day = calendar.startOfDay(for: date)
            var entry = days[day] ?? StatisticsDay(start: day)
            change(&entry.parts)
            days[day] = entry
        }
        let included = { (date: Date) in start.map { date >= $0 } ?? true }
        for record in records.sorted(by: { $0.date < $1.date }) where included(record.date) {
            guard let summary = record.summary else { continue }
            let gear: StatisticsParts.HackGear = switch record.gear?.reading {
            case .read(let reading): .read(reading)
            case .notRead: .notRead
            case nil: .none
            }
            add(at: record.date) { $0.addHack(summary, gear: gear, portalLevel: record.gear?.portalLevel?.level) }
        }
        for record in drops.sorted(by: { $0.date < $1.date }) where included(record.date) {
            guard let drop = record.drop else { continue }
            add(at: record.date) { $0.addDrop(drop.summary) }
        }
        return Array(days.values)
    }

    private static func keyCommandRows(_ records: [HackResultRecord]) -> [KeyCommandRow] {
        var rows: [CommandGroup: KeyCommandRow] = [:]
        for record in records {
            guard let group = CommandGroup.keys(record.summary?.commands) else { continue }
            var row = rows[group] ?? KeyCommandRow(group: group)
            row.hacks += 1
            if case .read(let gear) = record.gear?.reading, gear.bothPanelsRead, gear.unidentifiedQuantity == 0 {
                let entries = gear.panels.flatMap(\.entries)
                if !entries.contains(where: { $0.multiplied == true }) {
                    row.measured += 1
                    for entry in entries where entry.item != nil {
                        if entry.item == "Portal Key" { row.keys += entry.quantity } else { row.otherItems += entry.quantity }
                    }
                }
            }
            rows[group] = row
        }
        return rows.values.sorted { $0.group.order < $1.group.order }
    }

    private static func speedCommandRows(_ records: [HackResultRecord]) -> [SpeedCommandRow] {
        let groups = Dictionary(grouping: records.compactMap { record -> (CommandGroup, HackResultSummary)? in
            guard let summary = record.summary, let group = CommandGroup.speed(summary.commands) else { return nil }
            return (group, summary)
        }, by: \.0)
        return groups.map { group, pairs in
            let summaries = pairs.map(\.1)
            return SpeedCommandRow(group: group, hacks: summaries.count,
                                   hacking: average(summaries.compactMap(finalHacking)),
                                   speed: average(summaries.compactMap(finalSpeed)),
                                   accepted: acceptedPercent(summaries))
        }.sorted { $0.group.order < $1.group.order }
    }

    // A last-seen value may not be the one the game settled on.
    private static func finalHacking(_ summary: HackResultSummary) -> Int? {
        summary.hackingBonus.flatMap { $0.isFinal ? $0.percent : nil }
    }

    private static func finalSpeed(_ summary: HackResultSummary) -> Int? {
        summary.speedBonus.flatMap { $0.isFinal ? $0.percent : nil }
    }

    private static func acceptedPercent(_ summaries: [HackResultSummary]) -> Int? {
        let judged = summaries.flatMap(\.slots).filter { $0.outcome != .unknown }
        return percent(judged.filter { $0.outcome == .accepted }.count, of: judged.count)
    }

    private static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    static func percent(_ part: Int, of whole: Int) -> Int? {
        HackTally.percent(part, of: whole)
    }
}
