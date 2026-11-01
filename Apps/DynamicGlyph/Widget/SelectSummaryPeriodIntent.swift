import AppIntents
import Foundation
import WidgetKit

/// What the Summary widget's period buttons run, in the widget extension:
/// it keeps the period and asks WidgetKit to reload every Summary widget.
/// The choice is one for every Summary widget: a static widget can't tell
/// its copies apart.
struct SelectSummaryPeriodIntent: AppIntent {
    static let title = LocalizedStringResource("Change period",
                                               comment: "Summary widget: the action of its period buttons, and the name of the small widget's one button.")
    /// Only the widget's buttons run it, not Shortcuts or Spotlight.
    static let isDiscoverable = false

    /// A `StatisticsPeriod` raw value.
    @Parameter(title: LocalizedStringResource("Period", comment: "Summary widget: the period its figures cover."))
    var period: String

    init() {}

    init(_ period: StatisticsPeriod) {
        self.period = period.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let chosen = StatisticsPeriod(rawValue: period) { StatisticsPeriod.widgetChoice = chosen }
        // Every Summary widget shows the one choice: the tapped one is
        // reloaded anyway, the others on this.
        WidgetCenter.shared.reloadTimelines(ofKind: StatisticsWidgetSummary.kind)
        return .result()
    }
}

extension StatisticsPeriod {
    /// Kept in a small file in the App Group, where the widget's timeline
    /// reads it. Today until a button is tapped. A file rather than shared
    /// defaults: WidgetKit reloads the tapped widget straight after the
    /// button's intent, and shared defaults could still hand that reload
    /// the previous choice, leaving the tapped widget one tap behind.
    static var widgetChoice: StatisticsPeriod {
        get {
            widgetChoiceURL
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .flatMap { StatisticsPeriod(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .today
        }
        set {
            guard let url = widgetChoiceURL else { return }
            try? Data(newValue.rawValue.utf8).write(to: url, options: .atomic)
        }
    }

    private static var widgetChoiceURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: StatisticsWidgetSummary.appGroup)?
            .appendingPathComponent("SummaryWidgetPeriod.txt")
    }
}
