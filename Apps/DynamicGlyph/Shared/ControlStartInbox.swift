import Combine
import Foundation

/// Where `StartGlyphIntent` leaves its request for the app's screens.
///
/// On a cold launch the intent runs before the home screen exists, so the
/// request is kept here rather than only announced; `posted` tells a screen
/// that is already up.
@MainActor
final class ControlStartInbox {
    static let shared = ControlStartInbox()

    private var request = ControlStartRequest()
    private let postedSubject = PassthroughSubject<Void, Never>()

    var posted: AnyPublisher<Void, Never> { postedSubject.eraseToAnyPublisher() }

    func post() {
        request.receive(at: ProcessInfo.processInfo.systemUptime)
        postedSubject.send()
    }

    func resolve(_ app: ControlStartRequest.AppState) -> ControlStartRequest.Outcome {
        request.resolve(app, at: ProcessInfo.processInfo.systemUptime)
    }
}
