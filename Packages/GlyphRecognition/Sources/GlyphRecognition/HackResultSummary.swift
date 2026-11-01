import Foundation

/// What the app shows and keeps for one hack's conclusion: the reducer's
/// fields and the validator comparison, with no screen data, OCR text or
/// timing evidence. Codable so a saved copy reads back exactly as shown.
public struct HackResultSummary: Sendable, Equatable, Codable {
    public struct Bonus: Sendable, Equatable, Codable {
        public let percent: Int
        /// False for the last value seen before finality was established.
        public let isFinal: Bool

        public init(percent: Int, isFinal: Bool) {
            self.percent = percent
            self.isFinal = isFinal
        }
    }

    public struct Slot: Sendable, Equatable, Codable {
        /// The confirmed expected Glyph; nil when the sequence never confirmed it.
        public let glyph: String?
        public let outcome: GameSlotOutcome
        /// Our check of the attempt the game judged, when that link is known.
        public let check: InputCheckVerdict?
        public let comparison: ValidatorResultComparison.Status
        /// How long the judged attempt took to draw; absent in results saved
        /// before it was recorded, or when either end was not seen.
        public let drawSeconds: Double?

        public init(glyph: String?, outcome: GameSlotOutcome, check: InputCheckVerdict?,
                    comparison: ValidatorResultComparison.Status, drawSeconds: Double? = nil) {
            self.glyph = glyph
            self.outcome = outcome
            self.check = check
            self.comparison = comparison
            self.drawSeconds = drawSeconds
        }
    }

    public let captureSessionID: UInt64
    public let hackID: Int
    public let state: HackResult.State
    public let isClosed: Bool
    public let closeReason: String?
    public let hackingBonus: Bonus?
    public let speedBonus: Bonus?
    public let slots: [Slot]
    /// Input screen to submitting; nil in older records and when the
    /// result never appeared.
    public let inputSeconds: Double?
    public let commands: HackCommandSummary?
    /// Set by the app as it receives the summary; nil in older records.
    public var origin: CaptureOrigin?

    public init(captureSessionID: UInt64, hackID: Int, state: HackResult.State, isClosed: Bool,
                closeReason: String?, hackingBonus: Bonus?, speedBonus: Bonus?, slots: [Slot],
                inputSeconds: Double? = nil, commands: HackCommandSummary? = nil) {
        self.captureSessionID = captureSessionID
        self.hackID = hackID
        self.state = state
        self.isClosed = isClosed
        self.closeReason = closeReason
        self.hackingBonus = hackingBonus
        self.speedBonus = speedBonus
        self.slots = slots
        self.inputSeconds = inputSeconds
        self.commands = commands
    }

    /// `comparison` comes from `ValidatorResultComparison.compare(result)`; a
    /// slot it does not cover has no known link to our check.
    public init(result: HackResult, comparison: [ValidatorResultComparison.Entry]) {
        func bonus(final: Int?, observed: Int?) -> Bonus? {
            if let final { return Bonus(percent: final, isFinal: true) }
            return observed.map { Bonus(percent: $0, isFinal: false) }
        }
        let entries = Dictionary(comparison.map { ($0.slotIndex, $0) }, uniquingKeysWith: { first, _ in first })
        self.init(captureSessionID: result.context.sessionID.rawValue, hackID: result.context.hackID,
                  state: result.state, isClosed: result.closedAt != nil, closeReason: result.closeReason,
                  hackingBonus: bonus(final: result.finalHackingBonus, observed: result.observedHackingBonus),
                  speedBonus: bonus(final: result.finalSpeedBonus, observed: result.observedSpeedBonus),
                  slots: result.outcomes.indices.map { index in
                      let entry = entries[index]
                      return Slot(glyph: result.context.glyphs.indices.contains(index) ? result.context.glyphs[index] : nil,
                                  outcome: result.outcomes[index], check: entry?.validatorVerdict,
                                  comparison: entry?.status ?? .unknownAssociation,
                                  drawSeconds: entry?.drawSeconds)
                  },
                  inputSeconds: result.inputSeconds, commands: result.context.commands)
    }

    /// Identity within one app run. Capture session numbers restart at launch,
    /// so anything kept longer adds its own run identifier.
    public var runKey: String { "\(captureSessionID)/\(hackID)" }
}

/// This app run's summaries, newest hack first. A hack's later summary
/// replaces its earlier one in place, so a result that finalizes after being
/// shown never appears twice.
public struct HackResultLog: Sendable, Equatable {
    public private(set) var entries: [HackResultSummary] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public mutating func record(_ summary: HackResultSummary) {
        if let index = entries.firstIndex(where: { $0.runKey == summary.runKey }) {
            entries[index] = summary
        } else {
            entries.insert(summary, at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
    }
}
