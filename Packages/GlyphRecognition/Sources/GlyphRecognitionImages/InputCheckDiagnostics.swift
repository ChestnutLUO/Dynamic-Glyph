import Foundation
import GlyphRecognition

extension InputCheckResult {
    public var diagnosticRow: [String: Any] {
        ["sessionID": sessionID.rawValue, "hackID": hackID, "slotIndex": slotIndex,
         "attemptID": attemptID, "expectedGlyph": expectedGlyph.name,
         "verdict": verdict.rawValue, "reason": reason?.rawValue ?? NSNull(),
         "sourceTime": sourceTime, "startTime": startTime ?? NSNull(),
         "liftTime": liftTime ?? NSNull(),
         "windowEnd": windowEnd.rawValue,
         "samples": samples.map { sample -> [String: Any] in
             ["time": sample.time,
              "edges": sample.edges.map { "\($0.lower.character)-\($0.upper.character)" }.sorted(),
              "partialEdges": sample.partialEdges.map { "\($0.lower.character)-\($0.upper.character)" }.sorted()]
         }]
    }
}

extension InputCheckEvent {
    public var diagnosticRow: [String: Any] {
        var row: [String: Any] = ["kind": kind.rawValue, "sourceTime": time,
            "hackID": hackID, "slotIndex": slotIndex, "attemptID": attemptID,
            "reason": reason?.rawValue ?? NSNull()]
        if let result { row["result"] = result.diagnosticRow }
        if !edgeEvidence.isEmpty {
            row["edges"] = edgeEvidence.map { evidence -> [String: Any] in
                ["edge": "\(evidence.edge.lower.character)-\(evidence.edge.upper.character)",
                 "coverage": evidence.coverage, "present": evidence.isPresent]
            }
        }
        return row
    }
}
