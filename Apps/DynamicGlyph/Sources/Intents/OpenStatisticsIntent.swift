import AppIntents

/// Open Statistics in Shortcuts, Siri and Spotlight: opens the app on the
/// Statistics tab and period chosen, as the Summary widget's link does. The
/// page then shows its own figures or its own reason for showing none, so
/// nothing is said here. The Summary widget's period stays as it was.
struct OpenStatisticsIntent: AppIntent {
    static let title = LocalizedStringResource("Open Statistics",
                                               comment: "Shortcuts, Siri and Spotlight: the action that opens the app's Statistics tab.")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Opens Statistics for the period you choose.",
                                comment: "Shortcuts: what Open Statistics does."))
    static let openAppWhenRun = true

    @Parameter(title: LocalizedStringResource("Period", comment: "Statistics: the period its figures cover. Also Open Statistics' choice in Shortcuts."),
               default: .today)
    var period: StatisticsShortcutPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Open Statistics for \(\.$period)")
    }

    init() {}

    init(period: StatisticsShortcutPeriod) {
        self.period = period
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.run(period)
        return .result()
    }

    /// Leaves the period for the app's screens. Also run by the debug page.
    @MainActor
    static func run(_ period: StatisticsShortcutPeriod) {
        StatisticsOpenInbox.shared.post(period.period)
    }
}

/// The same names as the Statistics readout. The English synonyms are only
/// for Siri; in the other languages Siri matches the names themselves.
extension StatisticsShortcutPeriod: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Period", comment: "Statistics: the period its figures cover. Also Open Statistics' choice in Shortcuts."))

    static let caseDisplayRepresentations: [StatisticsShortcutPeriod: DisplayRepresentation] = [
        .today: DisplayRepresentation(
            title: LocalizedStringResource("Today", comment: "Statistics readout, Home's gear counter and Open Statistics' choice in Shortcuts: today from midnight.")),
        .last7Days: DisplayRepresentation(
            title: LocalizedStringResource("Last 7 days", comment: "Statistics readout: the 7 days segment, today and the 6 days before it."),
            synonyms: [LocalizedStringResource("past week", comment: "English-only Siri synonym for Open Statistics' Last 7 days."),
                       LocalizedStringResource("shortcuts.synonym.sevenDays", defaultValue: "7 days",
                                               comment: "English-only Siri synonym for Open Statistics' Last 7 days. Its own key, as the segment's 7 days is translated.")]),
        .all: DisplayRepresentation(
            title: LocalizedStringResource("All records", comment: "Statistics readout and VoiceOver: every record kept on this iPhone, the All zone of the timeline."),
            synonyms: [LocalizedStringResource("all", comment: "English-only Siri synonym for Open Statistics' All records."),
                       LocalizedStringResource("everything", comment: "English-only Siri synonym for Open Statistics' All records.")]),
    ]
}
