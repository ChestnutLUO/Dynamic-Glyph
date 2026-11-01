import Foundation
import Testing
import GlyphRecognition

@Suite("Gear reports")
struct GearReportTests {
    private let session = "spikeB-2026-10-01T22-04-20Z"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func group(id: Int = 3, hackID: Int? = nil) -> GearDropSummary {
        let entry = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 4, quantity: 1)
        return GearDropSummary(groupID: id, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: hackID,
                               association: hackID == nil ? .noWaitingHack : .ordered,
                               panels: [.init(stage: .portal, entries: [entry], partial: false)])
    }

    private func row(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A session folder holding one saved panel picture and a gear log.
    private func makeSession(in documents: URL, log: [String]) throws {
        let folder = documents.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: folder.appendingPathComponent("gear-11.000000.jpg"))
        try Data([0xFF, 0xD8, 0xFF, 0x01]).write(to: folder.appendingPathComponent("gear-full-11.000000.jpg"))
        try Data(log.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("gear-drops.jsonl"))
    }

    private func manifest(in folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("report.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A drop's report holds its reading, its pictures, its own log rows and what the player said")
    func dropReport() throws {
        let documents = try TemporaryDirectory("gear-report-documents")
        let outbox = try TemporaryDirectory("gear-report-outbox")
        let own = try row(["kind": "group", "groupID": 3, "startedAt": 10, "closedAt": 14])
        let early = try row(["kind": "portalScreen", "sourceTime": 9.4])
        let late = try row(["kind": "reading", "stage": "bonus", "sourceTime": 13.8])
        let other = try row(["kind": "group", "groupID": 4, "startedAt": 30, "closedAt": 32])
        let later = try row(["kind": "reading", "stage": "portal", "sourceTime": 30.5])
        try makeSession(in: documents.url, log: [early, own, late, "not json", other, later])
        var drop = GearDrop(captureSessionID: 1, summary: group(),
                            pictures: [HackGearPicture(path: "\(session)/gear-11.000000.jpg", stage: .portal),
                                       HackGearPicture(path: "\(session)/gear-12.000000.jpg", stage: .bonus)])
        drop.sessionFolder = session
        let folder = outbox.url.appendingPathComponent("report")

        try GearReportBuilder(documents: documents.url)
            .write(.drop(drop, recordID: "launch/1/drop-3", date: now), problems: [.wrongQuantity, .missingItem],
                   note: "  The game showed two Resonators.\n", app: "1.2 (34)", system: "iOS 27.0 · iPhone17,1",
                   now: now, to: folder)

        let report = try manifest(in: folder)
        #expect(report["kind"] as? String == "drop")
        #expect(report["problems"] as? [String] == ["missingItem", "wrongQuantity"], "In the order they're offered")
        #expect(report["note"] as? String == "The game showed two Resonators.")
        #expect(report["app"] as? String == "1.2 (34)" && report["recordID"] as? String == "launch/1/drop-3")
        #expect((report["drop"] as? [String: Any])?["sessionFolder"] as? String == session)
        #expect(report["pictures"] as? [String] == ["pictures/gear-11.000000.jpg"])
        #expect(report["missingPictures"] as? Int == 1, "The deleted picture is counted, not invented")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pictures/gear-11.000000.jpg").path))
        #expect(report["gearLog"] as? String == "included" && report["gearLogLines"] as? Int == 3)
        let log = try String(contentsOf: folder.appendingPathComponent("gear-log.jsonl"), encoding: .utf8)
        #expect(log == [early, own, late].joined(separator: "\n") + "\n")
        // Full screenshots weren't asked for, and no picture of the reading was drawn.
        #expect(report["fullFrames"] == nil && report["readingImage"] == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("screens").path))
    }

    @Test("Asked for, the full screenshots go in beside the panel pictures, with the picture of the reading")
    func fullFrames() throws {
        let documents = try TemporaryDirectory("gear-report-full-documents")
        let outbox = try TemporaryDirectory("gear-report-full-outbox")
        try makeSession(in: documents.url, log: [])
        let drop = GearDrop(captureSessionID: 1, summary: group(),
                            pictures: [HackGearPicture(path: "\(session)/gear-11.000000.jpg", stage: .portal),
                                       HackGearPicture(path: "\(session)/gear-12.000000.jpg", stage: .bonus)])
        let folder = outbox.url.appendingPathComponent("report")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try GearReportBuilder(documents: documents.url)
            .write(.drop(drop, recordID: "a", date: now), problems: [.missingItem], note: "", app: "1",
                   system: "iOS", now: now, includesFullFrames: true, readingImage: png, to: folder)
        let report = try manifest(in: folder)
        #expect(report["schemaVersion"] as? Int == 2)
        #expect(report["fullFrames"] as? [String] == ["screens/gear-full-11.000000.jpg"])
        #expect(report["missingFullFrames"] as? Int == 1, "The second picture's frame isn't on this iPhone")
        #expect(try Data(contentsOf: folder.appendingPathComponent("screens/gear-full-11.000000.jpg"))
                == Data([0xFF, 0xD8, 0xFF, 0x01]))
        #expect(report["readingImage"] as? String == "reading.png")
        #expect(try Data(contentsOf: folder.appendingPathComponent("reading.png")) == png)
    }

    @Test("A panel picture's whole frame sits beside it in the same session folder")
    func fullFrameNames() {
        let root = URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        let picture = HackGearPicture(path: "\(session)/gear-11.000000.jpg", stage: .portal)
        #expect(picture.fullFrameURL(in: root)?.path == "/tmp/documents/\(session)/gear-full-11.000000.jpg")
        #expect(HackGearPicture(path: "../gear-1.jpg", stage: .portal).fullFrameURL(in: root) == nil)
    }

    @Test("The zip is named for when it was made, and the folder it was made from is gone")
    func archive() throws {
        let documents = try TemporaryDirectory("gear-report-zip-documents")
        let outbox = try TemporaryDirectory("gear-report-zip-outbox")
        let drop = GearDrop(captureSessionID: 1, summary: group())
        let zip = try GearReportBuilder(documents: documents.url)
            .archive(.drop(drop, recordID: "a", date: now), problems: [.other], note: "", app: "1", system: "iOS",
                     now: now, into: outbox.url)
        #expect(zip.lastPathComponent == "DynamicGlyph-gear-report-2027-01-15T08-00-00Z.zip")
        #expect(try Data(contentsOf: zip).starts(with: [0x50, 0x4B]))  // "PK", a zip header
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.url.path) == [zip.lastPathComponent])
    }

    @Test("A hack's unread gear brings that hack's queue rows; a session that isn't here says so")
    func hackGear() throws {
        let documents = try TemporaryDirectory("gear-report-hack")
        let queue = try row(["kind": "queue", "hackID": 2, "reason": "waitTimeout", "time": 40])
        let otherHack = try row(["kind": "queue", "hackID": 1, "reason": "waiting", "time": 12])
        let level = try row(["kind": "portalLevel", "hackID": 2, "level": 6])
        #expect(GearReportBuilder.logLines([otherHack, queue, level].joined(separator: "\n"), group: nil, hackID: 2)
                == [queue, level])

        let gear = HackGearAttachment(captureSessionID: 1, hackID: 2, reading: .notRead(reason: "waitTimeout"),
                                      sessionFolder: "spikeB-2026-09-01T00-00-00Z")
        let folder = documents.url.appendingPathComponent("report")
        try GearReportBuilder(documents: documents.url)
            .write(.hackGear(gear, recordID: "launch/1/2", date: now, hack: nil), problems: [.wrongHack], note: "",
                   app: "1", system: "iOS", now: now, to: folder)
        let report = try manifest(in: folder)
        #expect(report["kind"] as? String == "hackGear" && report["note"] == nil)
        #expect(report["gearLog"] as? String == "notOnThisPhone")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("gear-log.jsonl").path))
    }

    @Test("Gear saved before reports finds its session through its pictures; without either there's none")
    func sessionFolder() {
        let old = GearDrop(captureSessionID: 1, summary: group(),
                           pictures: [HackGearPicture(path: "\(session)/gear-1.jpg", stage: .portal)])
        #expect(GearReportSubject.drop(old, recordID: "a", date: now).sessionFolder == session)
        let bare = GearDrop(captureSessionID: 1, summary: group())
        #expect(GearReportSubject.drop(bare, recordID: "a", date: now).sessionFolder == nil)
    }

    @Test("A saved folder name can only name a session folder directly in Documents")
    func sessionURL() {
        let root = URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        #expect(GearReportBuilder.sessionURL(session, in: root)?.path == "/tmp/documents/\(session)")
        for name in ["..", "spikeB-a/../../etc", "spikeB-a/b", "notes", ""] {
            #expect(GearReportBuilder.sessionURL(name, in: root) == nil, "\(name)")
        }
    }

    @Test("A blank note is left out and a pasted one is cut to the limit")
    func note() {
        #expect(GearReportBuilder.trimmed(" \n\t") == nil)
        #expect(GearReportBuilder.trimmed(String(repeating: "x", count: 5_000))?.count == GearReportBuilder.noteLimit)
    }
}
