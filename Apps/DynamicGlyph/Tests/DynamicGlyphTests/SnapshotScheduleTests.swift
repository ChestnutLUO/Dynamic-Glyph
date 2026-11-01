import Foundation
import ImageIO
import Testing

/// The first live run exposed a snapshot limiter that kept only the first of
/// four held presentation shapes. The fixture is that run's recognition log,
/// reduced to the fields the schedule reads.
@Suite("Snapshot schedule")
struct SnapshotScheduleTests {
    private struct Row: Decodable {
        let sample: Int
        let presentationTime: Double
        let state: String
        let edges: [String]
        let exactMatches: [String]
    }

    @Test("Every held presentation shape in the field run gets a screenshot")
    func fieldRunRetainsAllFourShapes() throws {
        let text = try String(contentsOf: TestFixtures.url("field-2026-09-18-schedule", "jsonl"),
                              encoding: .utf8)
        let rows = try text.split(separator: "\n").map {
            try JSONDecoder().decode(Row.self, from: Data($0.utf8))
        }
        #expect(rows.count == 310)

        var schedule = SnapshotSchedule()
        var selected: [Int] = []
        for row in rows {
            let key = row.state + ":" + row.edges.joined(separator: ",")
                + ":" + row.exactMatches.joined(separator: ",")
            if schedule.wantsSnapshot(key: key, at: row.presentationTime) {
                selected.append(row.sample)
                schedule.didQueue(key: key, at: row.presentationTime)
            }
        }
        // Fixed slot windows from this field run.
        for window in [443...448, 451...455, 458...463, 466...471] {
            #expect(selected.contains(where: window.contains), "no screenshot in \(window)")
        }
    }

    @Test("A changed shape waits out the minimum interval, and backpressure does not consume it")
    func retryAndBackpressure() {
        var schedule = SnapshotSchedule()
        schedule.didQueue(key: "blank", at: 0)
        #expect(!schedule.wantsSnapshot(key: "glyph", at: 0.1))
        #expect(schedule.wantsSnapshot(key: "glyph", at: 0.2))
        // Not queued (the writer was busy), so the next frame is still wanted.
        #expect(schedule.wantsSnapshot(key: "glyph", at: 0.25))
        schedule.didQueue(key: "glyph", at: 0.25)
        #expect(!schedule.wantsSnapshot(key: "glyph", at: 0.5))
        #expect(schedule.wantsSnapshot(key: "blank", at: 0.5))
    }

    @Test("The screenshot cap is 400, and the 400th is still taken")
    func cap() {
        var schedule = SnapshotSchedule()
        for index in 0..<399 { schedule.didQueue(key: String(index), at: Double(index)) }
        #expect(schedule.wantsSnapshot(key: "last", at: 500))
        schedule.didQueue(key: "last", at: 500)
        #expect(!schedule.wantsSnapshot(key: "over-limit", at: 600))
    }

    @Test("An asynchronous PNG save is flushed by finish and recorded as saved")
    func writerFlushes() throws {
        let destination = try TemporaryDirectory("snapshots")
        let source = try #require(CGImageSourceCreateWithURL(
            try TestFixtures.url("field-00443", "png") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let writer = try GlyphSnapshotWriter(directory: destination.url)
        #expect(writer.enqueue(image, name: "test.png", sample: 443))
        writer.finish()

        let saved = try Data(contentsOf: destination.url.appendingPathComponent("snapshots.jsonl"))
        let receipt = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(receipt["status"] as? String == "saved")
        let output = try #require(CGImageSourceCreateWithURL(
            destination.url.appendingPathComponent("test.png") as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
        #expect(decoded.width == 603 && decoded.height == 1311)
    }
}
