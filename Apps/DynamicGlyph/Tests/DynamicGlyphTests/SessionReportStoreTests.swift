import Foundation
import Testing

@Suite("Session reports")
struct SessionReportStoreTests {
    private func makeSession(_ name: String, in root: URL, log: String? = nil,
                             video: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("frame,status\n0,complete\n".utf8).write(to: folder.appendingPathComponent("frames.csv"))
        if let log { try Data(log.utf8).write(to: folder.appendingPathComponent("events.log")) }
        if video { try Data(count: 64).write(to: folder.appendingPathComponent("screen-recording.mp4")) }
        return folder
    }

    @Test("Only session folders are listed, newest first, with their start time")
    func listsSessions() throws {
        let root = try TemporaryDirectory("reports")
        _ = try makeSession("spikeB-2026-09-18T20-00-22Z", in: root.url)
        _ = try makeSession("spikeB-2026-09-22T05-58-06Z", in: root.url, video: true)
        try Data("x".utf8).write(to: root.url.appendingPathComponent("glyph_line.csv"))
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("Inbox"),
                                                withIntermediateDirectories: true)

        let reports = try SessionReportStore(root: root.url).reports()
        #expect(reports.map(\.name) == ["spikeB-2026-09-22T05-58-06Z", "spikeB-2026-09-18T20-00-22Z"])
        #expect(reports[0].hasScreenRecording)
        #expect(!reports[1].hasScreenRecording)
        #expect(reports[0].byteCount > 64)
        let expected = ISO8601DateFormatter().date(from: "2026-09-22T05:58:06Z")
        #expect(reports[0].startedAt == expected)
    }

    @Test("A folder name that is not a stamp has no start date rather than a wrong one")
    func unparseableStamp() {
        #expect(SessionReportStore.startDate(of: "spikeB-copy") == nil)
        #expect(SessionReportStore.startDate(of: "notes-2026-09-22T05-58-06Z") == nil)
    }

    @Test("The event log is read back, and its absence is not an error")
    func readsEventLog() throws {
        let root = try TemporaryDirectory("reports-log")
        _ = try makeSession("spikeB-2026-09-22T05-58-06Z", in: root.url, log: "startCapture ok\n")
        _ = try makeSession("spikeB-2026-09-21T05-58-06Z", in: root.url)
        let store = SessionReportStore(root: root.url)
        let reports = try store.reports()
        #expect(store.eventLog(for: reports[0]) == "startCapture ok\n")
        #expect(store.eventLog(for: reports[1]) == nil)
    }

    @Test("Sharing makes a zip and leaves the session folder in place; deleting removes it")
    func archivesAndDeletes() throws {
        let root = try TemporaryDirectory("reports-zip")
        let outbox = try TemporaryDirectory("reports-outbox")
        _ = try makeSession("spikeB-2026-09-22T05-58-06Z", in: root.url, log: "hello\n")
        let store = SessionReportStore(root: root.url)
        let report = try #require(try store.reports().first)

        let zip = try store.archive(report, into: outbox.url)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.starts(with: [0x50, 0x4B]))  // "PK", a zip header
        #expect(zip.lastPathComponent == "DynamicGlyph-spikeB-2026-09-22T05-58-06Z.zip")
        // Sharing twice replaces the old archive instead of failing.
        _ = try store.archive(report, into: outbox.url)
        #expect(FileManager.default.fileExists(atPath: report.url.path))

        try store.delete(report)
        #expect(try store.reports().isEmpty)
    }

    @Test("A note goes into the shared zip as note.txt, and the session folder is left as it was")
    func archivesWithNote() throws {
        let root = try TemporaryDirectory("reports-note")
        let outbox = try TemporaryDirectory("reports-note-outbox")
        let folder = try makeSession("spikeB-2026-09-22T05-58-06Z", in: root.url, log: "hello\n")
        let store = SessionReportStore(root: root.url)
        let report = try #require(try store.reports().first)

        let staged = try store.stage(report, note: "The Bonus panel was cut off.", in: outbox.url)
        #expect(staged.lastPathComponent == report.name, "The zip keeps the session's own folder name")
        #expect(try String(contentsOf: staged.appendingPathComponent("note.txt"), encoding: .utf8)
                == "The Bonus panel was cut off.\n")
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("events.log").path))
        try FileManager.default.removeItem(at: staged.deletingLastPathComponent())

        let zip = try store.archive(report, note: "  The Bonus panel was cut off.\n", into: outbox.url)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.range(of: Data("note.txt".utf8)) != nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.url.path) == [zip.lastPathComponent],
                "The copy the zip was made from is gone")
        // Without a note, nothing is added.
        let plain = try store.archive(report, note: " \n", into: outbox.url)
        #expect(try Data(contentsOf: plain).range(of: Data("note.txt".utf8)) == nil)
    }
}
