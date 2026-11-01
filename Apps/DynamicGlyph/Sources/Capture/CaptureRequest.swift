import Foundation

/// One consent request and its capture. Callbacks retain this identity even
/// after another request starts; invalidation silences both notes and events.
@MainActor
final class CaptureRequest {
    private weak var delegate: CaptureBackendDelegate?
    private(set) var isActive = true

    init(delegate: CaptureBackendDelegate?) {
        self.delegate = delegate
    }

    func invalidate() { isActive = false }

    func perform(_ action: () -> Void) {
        guard isActive else { return }
        action()
    }

    func didStart() {
        perform { delegate?.captureBackendDidStart() }
    }

    func fail(_ failure: CaptureBackendFailure, message: String, status: String) {
        perform {
            delegate?.captureBackendNote(message, status: status)
            delegate?.captureBackend(didFail: failure)
        }
    }
}
