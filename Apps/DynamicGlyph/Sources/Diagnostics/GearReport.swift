import Foundation
import GlyphRecognition

/// What a player says was wrong with a gear reading. Saved by name in the
/// report, so a reader can count them.
enum GearReportProblem: String, CaseIterable, Codable, Sendable {
    case missingItem, wrongItem, wrongQuantity, wrongLevel, wrongHack, other
}

/// One gear reading a player can report: a hack's gear, or a drop group no
/// Glyph hack claimed.
enum GearReportSubject: Sendable {
    case hackGear(HackGearAttachment, recordID: String, date: Date, hack: HackResultSummary?)
    case drop(GearDrop, recordID: String, date: Date)

    var pictures: [HackGearPicture] {
        switch self {
        case .hackGear(let gear, _, _, _): return gear.pictures ?? []
        case .drop(let drop, _, _): return drop.pictures
        }
    }

    /// Nil when gear wasn't read: the hack stopped waiting without a group.
    var group: GearDropSummary? {
        switch self {
        case .hackGear(let gear, _, _, _):
            if case .read(let summary) = gear.reading { return summary }
            return nil
        case .drop(let drop, _, _): return drop.summary
        }
    }

    var hackID: Int? {
        switch self {
        case .hackGear(let gear, _, _, _): return gear.hackID
        case .drop(let drop, _, _): return drop.summary.hackID
        }
    }

    /// Gear saved before reports has no folder, but its pictures' paths name it.
    var sessionFolder: String? {
        let saved: String?
        switch self {
        case .hackGear(let gear, _, _, _): saved = gear.sessionFolder
        case .drop(let drop, _, _): saved = drop.sessionFolder
        }
        return saved ?? pictures.first.flatMap { $0.path.split(separator: "/").first.map(String.init) }
    }
}

/// Packs one gear reading, its panel pictures, its lines from the session's
/// gear log and the player's account of what was wrong into a zip to send,
/// with a picture of the reading as the app showed it and, if the player
/// chooses, the whole frames the panel pictures were cut from. Nothing else
/// from the session goes in.
struct GearReportBuilder {
    /// The longest note kept. A note is a few sentences; this bounds a paste.
    static let noteLimit = 2_000
    /// Log rows this long either side of the group are its own: a reading
    /// that finished late carries its frame's time, and the portal screen and
    /// queue rows around the group explain which hack it went to.
    static let logMargin = 1.0

    /// Whether this drop's lines from the session's gear log are in the zip.
    enum LogStatus: String, Encodable {
        case included
        /// Logs were off for the session, or it was saved before reports.
        case noSessionFolder
        /// The session's logs were deleted, or it ran on another iPhone.
        case notOnThisPhone
        case noGearLog
    }

    /// Documents, where `EvidenceWriter` leaves each session's folder.
    let documents: URL

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documents = documents
    }

    /// Writes the report into `directory` and returns its zip. The folder the
    /// zip is made from is removed again.
    func archive(_ subject: GearReportSubject, problems: Set<GearReportProblem>, note: String,
                 app: String, system: String, now: Date, includesFullFrames: Bool = false,
                 readingImage: Data? = nil, into directory: URL) throws -> URL {
        let files = FileManager.default
        let name = "DynamicGlyph-gear-report-" + Self.stamp(now)
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        defer { try? files.removeItem(at: folder) }
        try write(subject, problems: problems, note: note, app: app, system: system, now: now,
                  includesFullFrames: includesFullFrames, readingImage: readingImage, to: folder)
        return try SessionReportStore.zip(folder, to: directory.appendingPathComponent(name + ".zip"))
    }

    /// The report's files: `report.json`, `pictures/`, `gear-log.jsonl`,
    /// `reading.png` and, when chosen, `screens/`.
    func write(_ subject: GearReportSubject, problems: Set<GearReportProblem>, note: String,
               app: String, system: String, now: Date, includesFullFrames: Bool = false,
               readingImage: Data? = nil, to folder: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var included: [String] = [], missing = 0
        let pictures = subject.pictures
        if !pictures.isEmpty {
            let pictureFolder = folder.appendingPathComponent("pictures", isDirectory: true)
            try files.createDirectory(at: pictureFolder, withIntermediateDirectories: true)
            for picture in pictures {
                guard let source = picture.url(in: documents), files.fileExists(atPath: source.path) else {
                    missing += 1
                    continue
                }
                guard !included.contains("pictures/" + source.lastPathComponent) else { continue }
                try files.copyItem(at: source, to: pictureFolder.appendingPathComponent(source.lastPathComponent))
                included.append("pictures/" + source.lastPathComponent)
            }
        }

        // The whole frames, unmasked, only when the player chose to send them.
        var screens: [String] = [], missingScreens = 0
        if includesFullFrames {
            let screenFolder = folder.appendingPathComponent("screens", isDirectory: true)
            for picture in pictures {
                guard let source = picture.fullFrameURL(in: documents), files.fileExists(atPath: source.path) else {
                    missingScreens += 1
                    continue
                }
                guard !screens.contains("screens/" + source.lastPathComponent) else { continue }
                try files.createDirectory(at: screenFolder, withIntermediateDirectories: true)
                try files.copyItem(at: source, to: screenFolder.appendingPathComponent(source.lastPathComponent))
                screens.append("screens/" + source.lastPathComponent)
            }
        }
        if let readingImage { try readingImage.write(to: folder.appendingPathComponent("reading.png")) }

        let status: LogStatus
        var logLines = 0
        if let sessionFolder = subject.sessionFolder, let session = Self.sessionURL(sessionFolder, in: documents) {
            let log = session.appendingPathComponent("gear-drops.jsonl")
            if !files.fileExists(atPath: session.path) {
                status = .notOnThisPhone
            } else if let text = try? String(contentsOf: log, encoding: .utf8) {
                let lines = Self.logLines(text, group: subject.group, hackID: subject.hackID)
                try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
                    .write(to: folder.appendingPathComponent("gear-log.jsonl"))
                logLines = lines.count
                status = .included
            } else {
                status = .noGearLog
            }
        } else {
            status = .noSessionFolder
        }

        let manifest = Manifest(subject: subject, problems: problems, note: Self.trimmed(note), app: app,
                                system: system, createdAt: now, pictures: included, missingPictures: missing,
                                fullFrames: includesFullFrames ? screens : nil,
                                missingFullFrames: includesFullFrames ? missingScreens : nil,
                                readingImage: readingImage == nil ? nil : "reading.png",
                                gearLog: status, gearLogLines: logLines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("report.json"))
    }

    /// The group's own rows, the rows timed within `logMargin` of it, and the
    /// hack's queue and portal level rows, in the log's order and as written.
    static func logLines(_ log: String, group: GearDropSummary?, hackID: Int?) -> [String] {
        log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let kind = row["kind"] as? String
            if let group {
                if kind == "group" {
                    return row["groupID"] as? Int == group.groupID ? String(line) : nil
                }
                if let time = (row["sourceTime"] ?? row["time"]) as? Double,
                   time >= group.startedAt - logMargin, time <= group.closedAt + logMargin {
                    return String(line)
                }
            }
            if let hackID, kind == "queue" || kind == "portalLevel", row["hackID"] as? Int == hackID {
                return String(line)
            }
            return nil
        }
    }

    /// Nil unless `name` is one session folder directly in `root`, so a
    /// saved record can never point elsewhere.
    static func sessionURL(_ name: String, in root: URL) -> URL? {
        guard name.hasPrefix(SessionReportStore.folderPrefix), !name.contains("/"), name != "..", name != "."
        else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    static func trimmed(_ note: String) -> String? {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(noteLimit))
    }

    /// Like a session folder's: ISO 8601 with the colons swapped for dashes.
    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// `report.json`. Technical, like the logs: read by whoever answers.
    private struct Manifest: Encodable {
        let schemaVersion = 2
        let kind: String
        let createdAt: Date
        let app: String
        let system: String
        let problems: [String]
        let note: String?
        let recordID: String
        let recordDate: Date
        let gear: HackGearAttachment?
        let drop: GearDrop?
        let hack: HackResultSummary?
        let pictures: [String]
        let missingPictures: Int
        /// Nil when the player chose not to send them.
        let fullFrames: [String]?
        /// Frames of sessions before full frames were saved, or deleted.
        let missingFullFrames: Int?
        let readingImage: String?
        let gearLog: LogStatus
        let gearLogLines: Int

        init(subject: GearReportSubject, problems: Set<GearReportProblem>, note: String?, app: String,
             system: String, createdAt: Date, pictures: [String], missingPictures: Int, fullFrames: [String]?,
             missingFullFrames: Int?, readingImage: String?, gearLog: LogStatus, gearLogLines: Int) {
            switch subject {
            case .hackGear(let gear, let recordID, let date, let hack):
                kind = "hackGear"; self.recordID = recordID; recordDate = date
                self.gear = gear; drop = nil; self.hack = hack
            case .drop(let drop, let recordID, let date):
                kind = "drop"; self.recordID = recordID; recordDate = date
                gear = nil; self.drop = drop; hack = nil
            }
            // In the order the player is offered them.
            self.problems = GearReportProblem.allCases.filter(problems.contains).map(\.rawValue)
            self.note = note
            self.app = app; self.system = system; self.createdAt = createdAt
            self.pictures = pictures; self.missingPictures = missingPictures
            self.fullFrames = fullFrames; self.missingFullFrames = missingFullFrames
            self.readingImage = readingImage
            self.gearLog = gearLog; self.gearLogLines = gearLogLines
        }
    }
}
