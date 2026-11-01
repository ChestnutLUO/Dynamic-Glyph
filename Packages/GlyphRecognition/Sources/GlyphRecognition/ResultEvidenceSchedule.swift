/// A separate budget from ordinary shape snapshots, starting at the first
/// numeric stage. Decision evidence bypasses the regular cadence/budget.
public struct ResultEvidenceSchedule: Sendable {
    public enum Selection: String, Sendable { case detection, animation, decision, budgetExhausted }
    private var context: ResultReadContext?
    private var detectionSaved = false
    private var firstNumeric: Double?
    private var lastSaved = -Double.infinity
    private var exhausted = false
    public init() {}

    public mutating func select(_ evidence: ResultFrameEvidence, decision: Bool) -> Selection? {
        if context != evidence.context { self = Self(); context = evidence.context }
        guard evidence.panelPresent else { return nil }
        if firstNumeric == nil && (evidence.hackingBonus != nil || evidence.speedBonus != nil) {
            firstNumeric = evidence.sourceTime
        }
        if decision { lastSaved = evidence.sourceTime; return .decision }
        if !detectionSaved { detectionSaved = true; lastSaved = evidence.sourceTime; return .detection }
        guard let firstNumeric else { return nil }
        if evidence.sourceTime - firstNumeric > 2.5 {
            guard !exhausted else { return nil }
            exhausted = true; return .budgetExhausted
        }
        guard evidence.sourceTime - lastSaved >= 0.198 else { return nil }
        lastSaved = evidence.sourceTime
        return .animation
    }
}
