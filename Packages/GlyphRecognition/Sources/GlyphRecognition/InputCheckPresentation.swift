import Foundation

/// The small value sent to the widget; sample evidence stays in diagnostics.
public struct InputCheckDisplay: Sendable, Hashable, Codable {
    public let verdict: InputCheckVerdict
    public let expectedGlyph: String
    public let sourceTime: Double
    public let attemptID: Int
    public let showsSymbol: Bool

    public init(verdict: InputCheckVerdict, expectedGlyph: String, sourceTime: Double,
                attemptID: Int, showsSymbol: Bool = true) {
        self.verdict = verdict
        self.expectedGlyph = expectedGlyph
        self.sourceTime = sourceTime
        self.attemptID = attemptID
        self.showsSymbol = showsSymbol
    }

    public var renderKey: String {
        "\(attemptID):\(sourceTime):\(verdict.rawValue):\(expectedGlyph):\(showsSymbol)"
    }

    public func message(slotNumber: Int) -> String {
        switch verdict {
        case .matched:
            return String(localized: "Glyph \(slotNumber) matches", bundle: #bundle,
                          comment: "Completed player drawing matches. Placeholder is its one-based slot number.")
        case .differs:
            return String(localized: "Glyph \(slotNumber) differs — expected \(expectedGlyph)", bundle: #bundle,
                          comment: "Completed player drawing differs. First placeholder is its one-based slot number; second is an untranslated Glyph name.")
        case .unavailable:
            return String(localized: "Unable to check Glyph \(slotNumber)", bundle: #bundle,
                          comment: "Insufficient capture evidence to check a completed drawing. Placeholder is its one-based slot number.")
        }
    }
}

extension GlyphDisplaySnapshot {
    public func inputCheckDisplay(for index: Int, atUptime now: Double) -> InputCheckDisplay? {
        guard let result = inputChecks.first(where: {
            $0.slotIndex == index && $0.sessionID == captureSessionID && $0.hackID == hackID
        }) else { return nil }
        let elapsed = sourceFrameTime - result.sourceTime + age(atUptime: now)
        return InputCheckDisplay(verdict: result.verdict, expectedGlyph: result.expectedGlyph.name,
                                 sourceTime: result.sourceTime, attemptID: result.attemptID,
                                 showsSymbol: result.verdict != .matched || elapsed <= 1.5)
    }

    /// Includes the brief check mark's expiry even without a new source frame.
    public func inputCheckRenderKey(atUptime now: Double) -> String {
        inputChecks.compactMap { result in
            inputCheckDisplay(for: result.slotIndex, atUptime: now).map {
                "\(result.slotIndex):\($0.renderKey)"
            }
        }.joined(separator: "|")
    }
}
