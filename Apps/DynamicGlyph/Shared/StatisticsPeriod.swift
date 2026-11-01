import Foundation

/// The Statistics page's periods, which the Home Screen widget offers too.
/// Local days: Today starts at midnight, 7 days are today and the six days
/// before it (a rolling window, not a calendar week), All is everything kept.
///
/// Shared source: the app's Statistics and the widget count the same days.
enum StatisticsPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case today, week, all
    var id: Self { self }

    /// The period's first moment; nil for All.
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .all: return nil
        }
    }

    /// The first moment of the period compared with: yesterday for Today, the
    /// 7 days before for 7 days. Nil for All, which has nothing before it.
    func previousStart(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return calendar.date(byAdding: .day, value: -1, to: today)
        case .week: return calendar.date(byAdding: .day, value: -13, to: today)
        case .all: return nil
        }
    }

    /// Today, 7 days, All, then Today again.
    var next: StatisticsPeriod {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
