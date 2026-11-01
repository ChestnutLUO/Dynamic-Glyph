import Foundation

/// A manual Show request remains pending until AVKit acknowledges success or
/// failure. Issuing startPictureInPicture does not mean a window appeared.
struct PiPStartRequest {
    enum Phase: Equatable { case waitingForReadiness, starting }

    private(set) var id: UUID?
    private(set) var phase: Phase?

    mutating func begin() -> UUID {
        let id = UUID()
        self.id = id
        phase = .waitingForReadiness
        return id
    }

    mutating func issue() -> Bool {
        guard phase == .waitingForReadiness else { return false }
        phase = .starting
        return true
    }

    mutating func finish() {
        id = nil
        phase = nil
    }

    /// The timer belongs to one request, so an old timeout cannot cancel a retry.
    mutating func expire(_ id: UUID) -> Phase? {
        guard self.id == id, let phase else { return nil }
        finish()
        return phase
    }
}
