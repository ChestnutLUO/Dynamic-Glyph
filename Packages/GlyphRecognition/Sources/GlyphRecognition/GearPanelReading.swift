/// One gear read, with what pacing and the session log need besides its
/// evidence. Never saved: only `evidence` reaches the tracker, and the rest
/// goes to the session's debug log at most.
public struct GearPanelReading: Sendable {
    public let evidence: GearDropFrameEvidence
    /// No panel stage was read, but the body showed a drop panel
    /// (`GearDropTextParser.showsUntitledPanel`): a panel whose title went
    /// unread. It is not a miss for the back-off; nothing of it is stored.
    public let untitledPanel: Bool
    /// Each OCR pass of the read, in order.
    public let passes: [GearReadPass]

    public init(evidence: GearDropFrameEvidence, untitledPanel: Bool = false, passes: [GearReadPass] = []) {
        self.evidence = evidence; self.untitledPanel = untitledPanel; self.passes = passes
    }
}

/// One OCR pass of a gear read, for the session log: counts, confidences and
/// time only. It has no field for recognized text.
public struct GearReadPass: Sendable, Equatable {
    public enum Purpose: String, Sendable {
        /// The whole panel in the reading language: titles and rows.
        case panel
        /// The whole panel, or without retries its title zone (the
        /// fallback), in a title-recovery family; only its title is used.
        case title
        /// One row's crop, reread.
        case row
        /// One row's quantity, in a non-English game.
        case quantity
    }
    public let purpose: Purpose
    /// The recognition languages asked for, such as "en-US".
    public let languages: [String]
    /// Every line the pass returned.
    public let lines: Int
    /// Lines in the panel's title zone; 0 for row and quantity crops.
    public let titleLines: Int
    /// The confidence of each title-zone line, highest first.
    public let titleConfidences: [Double]
    public let milliseconds: Double

    public init(purpose: Purpose, languages: [String], lines: Int, titleLines: Int,
                titleConfidences: [Double], milliseconds: Double) {
        self.purpose = purpose; self.languages = languages; self.lines = lines
        self.titleLines = titleLines; self.titleConfidences = titleConfidences
        self.milliseconds = milliseconds
    }

    /// A JSON object for the session log.
    public var logRow: [String: Any] {
        ["purpose": purpose.rawValue, "languages": languages, "lines": lines, "titleLines": titleLines,
         "titleConfidences": titleConfidences.map { ($0 * 1000).rounded() / 1000 },
         "milliseconds": (milliseconds * 10).rounded() / 10]
    }
}
