import Foundation
import GlyphRecognition

/// The Statistics summary's figures for one period, from local days' parts.
/// The app's Statistics page and the Home Screen widget both build them
/// here, from the same days merged in the same order, so their numbers are
/// the same to the last digit.
///
/// Shared source: the app and the widget extension.
struct StatisticsFigures: Equatable, Sendable {
    /// One day's average Hacking and Speed Bonus and accepted share. Nil
    /// where nothing final was read.
    struct BonusPoint: Codable, Equatable, Identifiable, Sendable {
        /// The start of the day.
        let date: Date
        /// Days in order from 1.
        let index: Int
        let hacks: Int
        let hacking: Int?
        let speed: Int?
        /// Glyphs the game accepted, of those judged.
        let accepted: Int?
        var id: Int { index }
    }

    /// One hack length, or one portal level within it: lengths shared by
    /// several levels have different time limits.
    struct LengthRow: Equatable, Identifiable, Sendable {
        let glyphs: Int
        /// Only for a level read by the gear test, under its length's row.
        let level: Int?
        let hacks: Int
        let secondsPerGlyph: Double?
        let hacking: Int?
        let speed: Int?
        let accepted: Int?
        var id: String { "\(glyphs)-\(level ?? 0)" }

        init(glyphs: Int, level: Int?, tally: HackTally) {
            self.glyphs = glyphs
            self.level = level
            hacks = tally.hacks
            secondsPerGlyph = tally.secondsPerGlyph
            hacking = tally.averageHacking
            speed = tally.averageSpeed
            accepted = tally.acceptedPercent
        }
    }

    /// Current minus previous period, in points for percentages. Nil where
    /// either side has nothing read.
    struct Change: Equatable, Sendable {
        let hacks: Int
        let hacking: Int?
        let speed: Int?
        let accepted: Int?
        /// Seconds; lower is better.
        let secondsPerGlyph: Double?
    }

    let period: StatisticsPeriod
    /// The period's days merged, oldest first.
    let parts: StatisticsParts
    /// Oldest first, one point per day with hacks; empty for Today.
    let bonusPoints: [BonusPoint]
    /// The days a day chart spans, through the end of today: all seven for
    /// 7 days, from the first hack for All. Nil for Today.
    let chartDays: Range<Date>?
    /// Against yesterday for Today and the 7 days before for 7 days; nil for
    /// All and when the previous period had no hacks. Bonuses are left out
    /// while lengths are mixed: a different mix of portals would move them.
    let change: Change?

    /// `days` in any order; each day's parts counted once. Days before the
    /// previous period's start aren't needed except for All.
    init(period: StatisticsPeriod, days: [StatisticsDay], now: Date, calendar: Calendar = .current) {
        let start = period.start(now: now, calendar: calendar)
        let ordered = days.sorted { $0.start < $1.start }
        let current = ordered.filter { day in start.map { day.start >= $0 } ?? true }
        var parts = StatisticsParts()
        for day in current { parts.merge(day.parts) }
        let points = period == .today ? [] : Self.points(current)
        var change: Change?
        if let start, let previousStart = period.previousStart(now: now, calendar: calendar) {
            var previous = StatisticsParts()
            for day in ordered where day.start >= previousStart && day.start < start { previous.merge(day.parts) }
            change = Self.change(parts, previous)
        }
        self.init(period: period, parts: parts, bonusPoints: points, change: change, now: now, calendar: calendar)
    }

    /// The app's Statistics ranges: `current` holds only the range's days,
    /// `previous` only those of the interval compared with, nil where there
    /// is no comparison. `chartDays` is what a day chart spans.
    init(period: StatisticsPeriod, current: [StatisticsDay], previous: [StatisticsDay]?, chartDays: Range<Date>?) {
        let ordered = current.sorted { $0.start < $1.start }
        var parts = StatisticsParts()
        for day in ordered { parts.merge(day.parts) }
        var change: Change?
        if let previous {
            var before = StatisticsParts()
            for day in previous.sorted(by: { $0.start < $1.start }) { before.merge(day.parts) }
            change = Self.change(parts, before)
        }
        self.period = period
        self.parts = parts
        bonusPoints = period == .today ? [] : Self.points(ordered)
        self.change = change
        self.chartDays = chartDays
    }

    /// From parts already merged, as the widget keeps All.
    init(period: StatisticsPeriod, parts: StatisticsParts, bonusPoints: [BonusPoint], change: Change?,
         now: Date, calendar: Calendar = .current) {
        self.period = period
        self.parts = parts
        self.bonusPoints = bonusPoints
        self.change = change
        let today = calendar.startOfDay(for: now)
        if period != .today, let first = period.start(now: now, calendar: calendar) ?? bonusPoints.first?.date,
           let end = calendar.date(byAdding: .day, value: 1, to: today), first < end {
            chartDays = first..<end
        } else {
            chartDays = nil
        }
    }

    static func points(_ days: [StatisticsDay]) -> [BonusPoint] {
        days.filter { $0.parts.tally.hacks > 0 }.enumerated().map { index, day in
            let tally = day.parts.tally
            return BonusPoint(date: day.start, index: index + 1, hacks: tally.hacks, hacking: tally.averageHacking,
                              speed: tally.averageSpeed, accepted: tally.acceptedPercent)
        }
    }

    static func change(_ current: StatisticsParts, _ previous: StatisticsParts) -> Change? {
        guard previous.tally.hacks > 0 else { return nil }
        func difference<Value: Numeric>(_ now: Value?, _ before: Value?) -> Value? {
            guard let now, let before else { return nil }
            return now - before
        }
        // A hack whose Glyphs weren't read has no known length.
        let lengths = Set(current.lengths.map(\.glyphs)), lengthsBefore = Set(previous.lengths.map(\.glyphs))
        let mixed = lengths.count > 1 || lengthsBefore != lengths
        let now = current.tally, before = previous.tally
        return Change(hacks: now.hacks - before.hacks,
                      hacking: mixed ? nil : difference(now.averageHacking, before.averageHacking),
                      speed: mixed ? nil : difference(now.averageSpeed, before.averageSpeed),
                      accepted: difference(now.acceptedPercent, before.acceptedPercent),
                      secondsPerGlyph: difference(now.secondsPerGlyph, before.secondsPerGlyph))
    }

    // MARK: - What the summary card shows

    var hacks: Int { parts.tally.hacks }
    var drops: Int { parts.drops }
    var items: Int { parts.items }
    /// Hack lengths played in the period, fewest Glyphs first.
    var lengths: [Int] { parts.lengths.map(\.glyphs) }
    /// Several lengths are counted together, so bonuses aren't like for like.
    var mixesLengths: Bool { parts.lengths.count > 1 }
    /// Every length played, each followed by its portal levels.
    var lengthRows: [LengthRow] {
        parts.lengths.flatMap { part in
            [LengthRow(glyphs: part.glyphs, level: nil, tally: part.tally)]
                + part.levels.map { LengthRow(glyphs: part.glyphs, level: $0.level, tally: $0.tally) }
        }
    }
    /// One row per length, without the level rows, for a chart.
    var lengthAverages: [LengthRow] {
        parts.lengths.map { LengthRow(glyphs: $0.glyphs, level: nil, tally: $0.tally) }
    }
    /// Most first, then by name.
    var gear: [StatisticsParts.GearGroup] {
        parts.gear.values.sorted { ($0.total, $1.item) > ($1.total, $0.item) }
    }
    var hasGear: Bool { parts.gearComplete + parts.gearPartial + parts.gearNotRead > 0 }
    /// Some gear was read: without it, the items are unknown, not zero.
    var hasGearReading: Bool { parts.gearComplete + parts.gearPartial > 0 }
    /// Only drop groups: gear read without Glyph hacks.
    var onlyDrops: Bool { hacks == 0 && drops > 0 }
    /// Readings not complete, so totals may be low. Rows or panels never
    /// seen are not counted here either: this is coverage of what was seen.
    var gearIncomplete: Int { parts.gearPartial + parts.gearNotRead }
    /// Items over the drop groups read, a hack's own or not.
    var itemsPerDrop: Double? {
        hasGearReading ? Double(parts.items) / Double(parts.gearComplete + parts.gearPartial) : nil
    }
}

/// What the Statistics summary panel shows, which the app's `HackStatistics`
/// and the widget's `StatisticsFigures` both give: the panel's views are
/// shared, so they draw either the same way.
protocol StatisticsPanelFigures {
    var hacks: Int { get }
    var drops: Int { get }
    var items: Int { get }
    var multipliedItems: Int { get }
    var itemsPerDrop: Double? { get }
    var averageHackingBonus: Int? { get }
    var averageSpeedBonus: Int? { get }
    var acceptedPercent: Int? { get }
    var secondsPerGlyph: Double? { get }
    var change: StatisticsFigures.Change? { get }
    var mixesLengths: Bool { get }
    var onlyDrops: Bool { get }
    var hasGear: Bool { get }
    var gear: [StatisticsParts.GearGroup] { get }
    var bonusPoints: [StatisticsFigures.BonusPoint] { get }
    var chartDays: Range<Date>? { get }
    var lengthAverages: [StatisticsFigures.LengthRow] { get }
}

extension StatisticsFigures: StatisticsPanelFigures {
    var multipliedItems: Int { parts.multipliedItems }
    var averageHackingBonus: Int? { parts.tally.averageHacking }
    var averageSpeedBonus: Int? { parts.tally.averageSpeed }
    var acceptedPercent: Int? { parts.tally.acceptedPercent }
    var secondsPerGlyph: Double? { parts.tally.secondsPerGlyph }
}
