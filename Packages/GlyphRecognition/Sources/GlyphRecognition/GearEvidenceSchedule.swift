/// At most four pictures per panel, with a separate cadence for each stage.
/// The first Bonus frame is eligible even just after a portal picture.
public struct GearEvidenceSchedule: Sendable {
    public static let perStageLimit = 4
    public static let minimumInterval = 0.5
    private var portalCount = 0
    private var bonusCount = 0
    private var lastPortal = -Double.infinity
    private var lastBonus = -Double.infinity

    public init() {}

    public func shouldSave(stage: GearDropStage, at time: Double) -> Bool {
        guard time.isFinite else { return false }
        switch stage {
        case .portal: return portalCount < Self.perStageLimit && time - lastPortal + 1e-9 >= Self.minimumInterval
        case .bonus: return bonusCount < Self.perStageLimit && time - lastBonus + 1e-9 >= Self.minimumInterval
        default: return false
        }
    }

    /// A busy writer does not spend the budget or postpone the next attempt.
    public mutating func didEnqueue(stage: GearDropStage, at time: Double) {
        guard shouldSave(stage: stage, at: time) else { return }
        switch stage {
        case .portal: portalCount += 1; lastPortal = time
        case .bonus: bonusCount += 1; lastBonus = time
        default: break
        }
    }
}
