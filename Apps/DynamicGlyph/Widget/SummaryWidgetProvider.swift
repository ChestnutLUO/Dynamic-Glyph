import Foundation
import WidgetKit

/// One moment of the Summary widget, its figures worked out in advance.
struct SummaryWidgetEntry: TimelineEntry {
    let date: Date
    let period: StatisticsPeriod
    /// Nil when the app's summary couldn't be read, or, for Today and
    /// 7 days, was cut in another time zone: the widget says the summary is
    /// unavailable rather than show zeros or another zone's days.
    let figures: StatisticsFigures?

    init(date: Date, period: StatisticsPeriod, summary: StatisticsWidgetSummary?, calendar: Calendar = .current) {
        self.date = date
        self.period = period
        figures = summary.flatMap { summary in
            period == .all || summary.knowsDays(at: date, calendar: calendar)
                ? summary.figures(period, at: date, calendar: calendar) : nil
        }
    }

    init(date: Date, period: StatisticsPeriod, figures: StatisticsFigures) {
        self.date = date
        self.period = period
        self.figures = figures
    }
}

/// Reads the totals the app wrote to the App Group; it never opens the
/// results store. Entries are now and each of the next seven midnights,
/// when Today and 7 days move on; after the last it reads the file again.
/// With no readable file, as before the app first runs, the widget says the
/// summary is unavailable. The gallery and the placeholder show made-up
/// figures, never the player's.
struct SummaryWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryWidgetEntry {
        .sample(date: Date(), period: .week)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.sample(date: Date(), period: .week))
        } else {
            completion(SummaryWidgetEntry(date: Date(), period: .widgetChoice, summary: Self.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryWidgetEntry>) -> Void) {
        let summary = Self.read(), period = StatisticsPeriod.widgetChoice
        let entries = StatisticsWidgetSummary.timelineDates(now: Date()).map {
            SummaryWidgetEntry(date: $0, period: period, summary: summary)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func read() -> StatisticsWidgetSummary? {
        StatisticsWidgetSummary.load(from: StatisticsWidgetSummary.fileURL)
    }
}

extension SummaryWidgetEntry {
    /// Made-up figures for the gallery: seven days of hacks of one length,
    /// with gear, so every part of the panel shows.
    static func sample(date: Date, period: StatisticsPeriod, calendar: Calendar = .current) -> SummaryWidgetEntry {
        var tally = HackTally()
        tally.hacks = 42
        tally.hackingTotal = 42 * 112
        tally.hackingCount = 42
        tally.bestHacking = 150
        tally.speedTotal = 42 * 67
        tally.speedCount = 42
        tally.glyphsJudged = 168
        tally.glyphsAccepted = 165
        tally.timedSeconds = 268.8
        tally.timedGlyphs = 168
        var parts = StatisticsParts()
        parts.tally = tally
        parts.resultsComplete = 42
        parts.lengths = [StatisticsParts.LengthPart(glyphs: 4, tally: tally)]
        parts.gearComplete = 42
        let gear: [(String, Int, Int)] = [("Resonator", 140, 20), ("XMP Burster", 120, 16), ("Power Cube", 22, 0),
                                          ("Portal Shield", 12, 0), ("Portal Key", 5, 0)]
        for (item, total, multiplied) in gear {
            parts.gear[item] = StatisticsParts.GearGroup(item: item, total: total, multiplied: multiplied)
        }
        parts.items = gear.map(\.1).reduce(0, +)
        parts.multipliedItems = gear.map(\.2).reduce(0, +)
        let today = calendar.startOfDay(for: date)
        let shape: [(Int, Int, Int)] = [(108, 62, 97), (121, 70, 99), (104, 58, 96), (117, 72, 98), (112, 66, 99),
                                        (125, 71, 100), (99, 69, 97)]
        let points = shape.enumerated().compactMap { index, values -> StatisticsFigures.BonusPoint? in
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: today) else { return nil }
            return StatisticsFigures.BonusPoint(date: day, index: index + 1, hacks: 6, hacking: values.0,
                                                speed: values.1, accepted: values.2)
        }
        return SummaryWidgetEntry(date: date, period: period,
                                  figures: StatisticsFigures(period: period, parts: parts,
                                                             bonusPoints: period == .today ? [] : points,
                                                             change: nil, now: date, calendar: calendar))
    }
}
