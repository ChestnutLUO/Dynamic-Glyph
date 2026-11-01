import Foundation
import GlyphRecognition

/// What the Home Screen Summary widget reads: the saved results as local
/// days' parts, so the widget builds each period's figures exactly as the
/// Statistics page does, and can turn Today and the 7 days over at midnight
/// while the app isn't running. The app writes it to the App Group after
/// every change to the saved results; the widget never opens the store.
///
/// Shared source: the app writes it, the widget extension reads it.
struct StatisticsWidgetSummary: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// The widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    static let kind = "org.szres.DynamicGlyph.SummaryWidget"
    /// Today and 14 days before it: 7 days and the 7 days before them, which
    /// 7 days is compared with, and a day to spare. Days after the one it was
    /// written on have no saved hacks yet, so the widget stays right through
    /// the following days too.
    static let storedDays = 15

    /// A file of another version is not read: the widget shows zeros rather
    /// than misreading it.
    var version = Self.currentVersion
    /// The first day `days` covers, at midnight.
    var coverageStart: Date
    /// The days from `coverageStart` with hacks or drops, oldest first. A day
    /// missing is a day with neither.
    var days: [StatisticsDay]
    /// Everything kept, merged day by day as All is on the Statistics page:
    /// rebuilt from the store at every write, so a deletion leaves nothing.
    var all: StatisticsParts
    /// All's daily averages.
    var allPoints: [StatisticsFigures.BonusPoint]
    /// The time zone `days` were cut in, as "Europe/Paris". Optional, so a
    /// file from before it is still read; nil is taken to be the widget's.
    var timeZone: String?

    static let empty = StatisticsWidgetSummary(coverageStart: .distantPast, days: [], all: StatisticsParts(),
                                               allPoints: [])

    /// Whether Today and 7 days can be worked out at `date` in `calendar`'s
    /// zone: the days were cut in it, or in one whose midnights fall at the
    /// same moments over the stored days and up to `date`. Otherwise, as
    /// after a change of time zone the app hasn't seen yet, those figures
    /// would count the wrong hours, and the widget says the summary is
    /// unavailable for them until the app writes it again. All has no days.
    func knowsDays(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let timeZone, timeZone != calendar.timeZone.identifier else { return true }
        guard let zone = TimeZone(identifier: timeZone) else { return false }
        var day = max(coverageStart, Date(timeIntervalSince1970: 0))
        let end = max(date, day)
        // Each midnight from the first stored day to `date`, a few weeks at most.
        for _ in 0..<64 {
            guard zone.secondsFromGMT(for: day) == calendar.timeZone.secondsFromGMT(for: day) else { return false }
            if day >= end { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { break }
            day = min(calendar.startOfDay(for: next), end)
        }
        return zone.secondsFromGMT(for: date) == calendar.timeZone.secondsFromGMT(for: date)
    }

    /// The figures Statistics would show for `period` at `date`.
    func figures(_ period: StatisticsPeriod, at date: Date, calendar: Calendar = .current) -> StatisticsFigures {
        guard period != .all else {
            return StatisticsFigures(period: .all, parts: all, bonusPoints: allPoints, change: nil, now: date,
                                     calendar: calendar)
        }
        let figures = StatisticsFigures(period: period, days: days, now: date, calendar: calendar)
        // Before the stored days, as after the clock is set back, the period
        // compared with isn't all here: say nothing rather than a wrong change.
        guard let previous = period.previousStart(now: date, calendar: calendar), previous < coverageStart else {
            return figures
        }
        return StatisticsFigures(period: period, parts: figures.parts, bonusPoints: figures.bonusPoints, change: nil,
                                 now: date, calendar: calendar)
    }

    /// When the widget's figures change without new data: now, and the
    /// start of each of the next seven local days, by which 7 days holds only
    /// days after the last write. A day whose midnight a clock change skips
    /// starts later, at 1:00; the day after it still starts at midnight.
    static func timelineDates(now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [now], day = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
            dates.append(day)
        }
        return dates
    }
}

// MARK: - The file

extension StatisticsWidgetSummary {
    static let appGroup = "group.org.szres.DynamicGlyph"

    /// Nil where the App Group isn't available, as in the test bundle.
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("SummaryWidget.json")
    }

    /// Sorted keys, so the same summary always encodes to the same bytes and
    /// the app can skip a write that changes nothing.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// What the widget shows: nil when there is no App Group or the file is
    /// missing, unreadable or of another version, and the widget says the
    /// summary is unavailable rather than show zeros it doesn't know.
    static func load(from url: URL?) -> StatisticsWidgetSummary? {
        url.flatMap(read(from:))
    }

    /// Nil when missing, unreadable or of another version.
    static func read(from url: URL) -> StatisticsWidgetSummary? {
        guard let data = try? Data(contentsOf: url),
              let summary = try? JSONDecoder().decode(StatisticsWidgetSummary.self, from: data),
              summary.version == currentVersion else { return nil }
        return summary
    }
}
