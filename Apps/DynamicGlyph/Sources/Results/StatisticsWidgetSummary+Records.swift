import Foundation

/// The widget's summary from the saved results, as Statistics counts them.
extension StatisticsWidgetSummary {
    /// `records` and `drops` are what the store holds: the widget outlives
    /// this run, so it shows only what the app will show at the next launch.
    init(records: [HackResultRecord], drops: [GearDropRecord], now: Date, calendar: Calendar = .current) {
        let days = HackStatistics.days(records: records, drops: drops, from: nil, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let coverageStart = calendar.date(byAdding: .day, value: -(Self.storedDays - 1), to: today) ?? today
        let all = StatisticsFigures(period: .all, days: days, now: now, calendar: calendar)
        self.init(coverageStart: coverageStart,
                  days: days.filter { $0.start >= coverageStart }.sorted { $0.start < $1.start },
                  all: all.parts, allPoints: all.bonusPoints, timeZone: calendar.timeZone.identifier)
    }
}
