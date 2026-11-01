import Combine
import Foundation

/// Where Open Statistics leaves the period for the app's screens.
///
/// On a cold launch the intent runs before the Statistics page has its
/// results, so the period is kept until the page is ready rather than only
/// announced; `posted` tells a page that is already up. Separate from the
/// Summary widget's choice, which this never changes.
@MainActor
final class StatisticsOpenInbox {
    static let shared = StatisticsOpenInbox()

    /// The latest period asked for and not yet shown.
    private(set) var pending: StatisticsPeriod?
    private let postedSubject = PassthroughSubject<Void, Never>()

    var posted: AnyPublisher<Void, Never> { postedSubject.eraseToAnyPublisher() }

    init() {}

    /// Several requests before the page looks are the latest one.
    func post(_ period: StatisticsPeriod) {
        pending = period
        postedSubject.send()
    }

    /// The period to show, once, when the page can show it; until then it
    /// is kept.
    func take(isReady: Bool) -> StatisticsPeriod? {
        guard isReady, let period = pending else { return nil }
        pending = nil
        return period
    }
}
