import Foundation

/// Where a tap on a widget takes the app. The URL only names a tab and the
/// period to show there, so it resolves the same on a cold launch and needs
/// no record to still exist.
///
/// Shared source: the widget sets it, the app's screens answer it. Widget
/// links reach their own app without a registered URL scheme, so no other
/// app can open these.
enum AppLink: Equatable {
    /// Statistics, on `period` when one is given; as it was otherwise.
    case statistics(StatisticsPeriod?)

    static let scheme = "dynamicglyph"
    private static let statisticsHost = "statistics"
    private static let periodItem = "period"

    /// "dynamicglyph://statistics?period=week"
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .statistics(let period):
            components.host = Self.statisticsHost
            if let period { components.queryItems = [URLQueryItem(name: Self.periodItem, value: period.rawValue)] }
        }
        return components.url!
    }

    /// A period this build doesn't know still opens Statistics.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.statisticsHost else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == Self.periodItem }?.value?.lowercased()
        self = .statistics(value.flatMap(StatisticsPeriod.init(rawValue:)))
    }
}
