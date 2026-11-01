import Foundation

/// The periods Open Statistics offers in Shortcuts and Siri: the Summary
/// widget's three, opened the way the widget's link opens them. Its own
/// type so the raw values saved in a player's shortcuts never change with
/// `StatisticsPeriod`'s; the `AppEnum` conformance is beside the intent.
enum StatisticsShortcutPeriod: String, CaseIterable, Sendable {
    case today, last7Days, all

    /// The Statistics page's period this stands for.
    var period: StatisticsPeriod {
        switch self {
        case .today: return .today
        case .last7Days: return .week
        case .all: return .all
        }
    }
}
