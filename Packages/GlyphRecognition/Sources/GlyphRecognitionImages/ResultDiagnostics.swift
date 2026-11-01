import Foundation
import GlyphRecognition

extension ResultFrameEvidence {
    public var diagnosticRow: [String: Any] {
        ["schemaVersion": 1, "policyVersion": 1, "kind": "reading", "layout": "english-portrait-2.17",
         "sessionID": context.sessionID.rawValue, "hackID": context.hackID,
         "sourceTime": sourceTime, "panelPresent": panelPresent,
         "stageIndex": stageIndex ?? NSNull(), "hackingBonus": hackingBonus ?? NSNull(),
         "speedBonus": speedBonus ?? NSNull(), "appearances": appearances.map(\.rawValue),
         "lines": lines.map { ["text": $0.text, "confidence": $0.confidence,
                                "x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] }]
    }
}

extension HackResult {
    public var diagnosticRow: [String: Any] {
        ["schemaVersion": 1, "policyVersion": 1, "kind": "summary",
         "sessionID": context.sessionID.rawValue, "hackID": context.hackID,
         "glyphs": context.glyphs.map { $0 as Any? ?? NSNull() }, "state": state.rawValue,
         "firstPanelTime": firstPanelTime ?? NSNull(), "lastPanelTime": lastPanelTime ?? NSNull(),
         "finalStageTime": finalStageTime ?? NSNull(),
         "inputStartedAt": inputStartedAt ?? NSNull(), "inputEndedAt": inputEndedAt ?? NSNull(),
         "observedHackingBonus": observedHackingBonus ?? NSNull(),
         "observedSpeedBonus": observedSpeedBonus ?? NSNull(),
         "finalHackingBonus": finalHackingBonus ?? NSNull(), "finalSpeedBonus": finalSpeedBonus ?? NSNull(),
         "outcomes": outcomes.map(\.rawValue), "closedAt": closedAt ?? NSNull(),
         "closeReason": closeReason ?? NSNull()]
    }
}

extension ValidatorResultComparison.Entry {
    public var diagnosticRow: [String: Any] {
        ["slotIndex": slotIndex, "attemptID": attemptID ?? NSNull(),
         "validatorVerdict": validatorVerdict?.rawValue ?? NSNull(),
         "gameOutcome": gameOutcome.rawValue, "status": status.rawValue,
         "drawSeconds": drawSeconds ?? NSNull()]
    }
}
