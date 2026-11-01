import Foundation

/// One capture session's folder: its logs, screenshots and any recording.
struct SessionReport: Identifiable, Hashable {
    let url: URL
    let startedAt: Date?
    let byteCount: Int64
    let hasScreenRecording: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Lists, reads, packages and deletes the session folders `EvidenceWriter`
/// leaves in Documents. Foundation only, so it can be tested on a temporary
/// directory.
struct SessionReportStore {
    /// `EvidenceWriter` names every session folder this way.
    static let folderPrefix = "spikeB-"

    let root: URL

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.root = root
    }

    /// Newest first. A folder that cannot be measured is still listed: the
    /// report is what matters, not its size.
    func reports() throws -> [SessionReport] {
        let files = FileManager.default
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles])
            .filter { url in
                url.lastPathComponent.hasPrefix(Self.folderPrefix)
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map { url in
                SessionReport(url: url, startedAt: Self.startDate(of: url.lastPathComponent),
                              byteCount: Self.size(of: url),
                              hasScreenRecording: files.fileExists(
                                  atPath: url.appendingPathComponent("screen-recording.mp4").path))
            }
            .sorted { ($0.startedAt ?? .distantPast, $0.name) > ($1.startedAt ?? .distantPast, $1.name) }
    }

    /// The session's event log, or nil if it never wrote one.
    func eventLog(for report: SessionReport) -> String? {
        try? String(contentsOf: report.url.appendingPathComponent("events.log"), encoding: .utf8)
    }

    /// Zips the folder into `directory` and returns the archive. A note from
    /// the player goes in as `note.txt`, beside the session's logs.
    func archive(_ report: SessionReport, note: String = "", into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("DynamicGlyph-\(report.name).zip")
        guard let note = GearReportBuilder.trimmed(note) else { return try Self.zip(report.url, to: destination) }
        let staged = try stage(report, note: note, in: directory)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        return try Self.zip(staged, to: destination)
    }

    /// A copy of the session's folder, under its own name, with the note
    /// added. The session folder itself is never written to. APFS clones the
    /// files, so even a screen recording costs no extra space.
    func stage(_ report: SessionReport, note: String, in directory: URL) throws -> URL {
        let files = FileManager.default
        let parent = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let copy = parent.appendingPathComponent(report.name, isDirectory: true)
        try files.copyItem(at: report.url, to: copy)
        try Data((note + "\n").utf8).write(to: copy.appendingPathComponent("note.txt"))
        return copy
    }

    /// Zips `folder` to `destination`, replacing an older archive there. The
    /// system produces the zip for any folder read "for uploading"; it is
    /// moved out because the coordinator deletes its own copy when the block
    /// returns.
    static func zip(_ folder: URL, to destination: URL) throws -> URL {
        let files = FileManager.default
        var coordinationError: NSError?
        var outcome: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading,
                                       error: &coordinationError) { zipped in
            outcome = Result {
                if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                try files.moveItem(at: zipped, to: destination)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    func delete(_ report: SessionReport) throws {
        try FileManager.default.removeItem(at: report.url)
    }

    /// `EvidenceWriter` writes an ISO 8601 stamp with the colons swapped for
    /// dashes, because colons are awkward in file names.
    static func startDate(of folderName: String) -> Date? {
        guard folderName.hasPrefix(folderPrefix) else { return nil }
        let stamp = folderName.dropFirst(folderPrefix.count)
        guard let separator = stamp.firstIndex(of: "T") else { return nil }
        let time = stamp[separator...].replacingOccurrences(of: "-", with: ":")
        return ISO8601DateFormatter().date(from: String(stamp[..<separator]) + time)
    }

    private static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
