import Foundation

/// Tells SwiftUI about frequent changes only while the app is on screen.
/// The values themselves are always stored as they change; only the "will
/// change" notice is held back while the gate is closed, and sent once,
/// synchronously, when it opens, so the first frame after the app returns is
/// drawn from the current values.
@MainActor
final class InterfacePublishGate {
    private(set) var isOpen: Bool
    /// Something changed while closed.
    private(set) var isStale = false
    private let send: () -> Void

    init(isOpen: Bool, send: @escaping () -> Void) {
        self.isOpen = isOpen
        self.send = send
    }

    /// Before a value the app's screens show changes.
    func willChange() {
        if isOpen { send() } else { isStale = true }
    }

    /// The app went to the background: no screen of it shows.
    func close() {
        isOpen = false
    }

    /// The app is coming back: the screens are told now, before its first
    /// frame, if anything changed meanwhile.
    func open() {
        isOpen = true
        guard isStale else { return }
        isStale = false
        send()
    }
}
