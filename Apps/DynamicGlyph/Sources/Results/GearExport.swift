import Foundation
import CryptoKit
import GlyphRecognition

/// The gear CSV a player exports for their own analysis or to share: one row
/// per item read, every column in `Docs/GEAR_EXPORT_FORMAT.md`. It is made
/// from a snapshot, so the counts, preview, checksum and shared file all
/// describe the same bytes however the records change meanwhile.
enum GearExport {
    static let formatVersion = 1

    enum TimePrecision: String, CaseIterable {
        /// An hour's interval, and the date.
        case hour
        /// The date only.
        case day
    }

    struct Options: Equatable {
        var timePrecision = TimePrecision.hour
    }

    /// Copies of the records the player chose, fixed when they asked.
    struct Snapshot {
        let records: [HackResultRecord]
        let drops: [GearDropRecord]
        let exporterVersion: String?
        let exporterBuild: String?

        init(records: [HackResultRecord], drops: [GearDropRecord], bundle: Bundle = .main) {
            self.init(records: records, drops: drops,
                      exporterVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                      exporterBuild: bundle.infoDictionary?["CFBundleVersion"] as? String)
        }

        init(records: [HackResultRecord], drops: [GearDropRecord], exporterVersion: String?, exporterBuild: String?) {
            self.records = records
            self.drops = drops
            self.exporterVersion = exporterVersion
            self.exporterBuild = exporterBuild
        }
    }

    /// What went into a file and what was left out, for the export sheet.
    struct Counts: Equatable {
        var hacks = 0
        var drops = 0
        var rows = 0
        /// Exported records by `read_status`.
        var read = 0
        var notRead = 0
        var unavailable = 0
        var unsupported = 0
        /// Read, but a panel seen was only partly read or a row unidentified.
        var partlyRead = 0
        /// Saved in a format this build can't read, so not in the file.
        var skipped = 0
        /// Hacks still being read.
        var inProgress = 0
        var records: Int { hacks + drops }
    }

    struct File {
        let data: Data
        let counts: Counts
        /// SHA-256 of `data`, lowercase hex.
        let checksum: String
        let fileName: String
    }

    // MARK: - Columns

    /// What a column may hold. Only text can start with a character a
    /// spreadsheet reads as a formula, so only text is guarded.
    enum ColumnType: Equatable {
        case integer, boolean, enumeration, identifier, timestamp, date, text
    }

    static let columns: [(name: String, type: ColumnType)] = [
        ("format_version", .integer), ("record_id", .identifier), ("kind", .enumeration),
        ("time_basis", .enumeration), ("time_bucket_start_utc", .timestamp), ("time_bucket_end_utc", .timestamp),
        ("local_date", .date), ("local_hour", .integer), ("utc_offset_minutes", .integer),
        ("session", .integer), ("order", .integer),
        ("read_status", .enumeration), ("read_reason", .identifier), ("association", .enumeration),
        ("observed_panels_read_in_full", .boolean), ("both_panels_read", .boolean),
        ("panel", .enumeration), ("panel_partial", .boolean), ("panel_effects", .text),
        ("slot", .integer), ("item", .text), ("level", .integer), ("level_state", .enumeration),
        ("rarity", .enumeration), ("rarity_source", .enumeration), ("quantity", .integer), ("multiplied", .boolean),
        ("hack_state", .enumeration), ("hack_glyph_count", .integer),
        ("hacking_bonus", .integer), ("hacking_bonus_final", .boolean),
        ("speed_bonus", .integer), ("speed_bonus_final", .boolean),
        ("command_mode", .enumeration), ("speed_command", .enumeration), ("speed_command_status", .enumeration),
        ("key_command", .enumeration), ("key_command_status", .enumeration),
        ("portal_level_low", .integer), ("portal_level_high", .integer),
        ("portal_level_confidence", .enumeration), ("portal_level_conflict", .boolean),
        ("capture_mode", .enumeration), ("game_language", .enumeration), ("game_language_source", .enumeration),
        ("source_app_version", .text), ("source_app_build", .text),
        ("exporter_app_version", .text), ("exporter_app_build", .text),
        ("portal_faction", .enumeration), ("player_faction", .enumeration), ("portal_alignment", .enumeration),
    ]

    // MARK: - Making the file

    static func make(_ snapshot: Snapshot, options: Options, exportedAt: Date = Date(),
                     calendar: Calendar = .current) -> File {
        var counts = Counts()
        var exported: [Exported] = []
        for record in snapshot.records {
            guard let summary = record.summary else { counts.skipped += 1; continue }
            guard summary.isClosed else { counts.inProgress += 1; continue }
            exported.append(Exported(key: record.id, date: record.date, content: .hack(summary, record)))
        }
        for record in snapshot.drops {
            guard let drop = record.drop else { counts.skipped += 1; continue }
            exported.append(Exported(key: record.id, date: record.date, content: .drop(drop)))
        }
        let places = sessionPlaces(exported)
        var lines = [csvLine(columns.map(\.name))]
        for record in exported.sorted(by: { ($0.date, $0.key) < ($1.date, $1.key) }) {
            let rows = rows(for: record, place: places[record.key] ?? (0, 0), snapshot: snapshot, options: options)
            count(record, into: &counts)
            counts.rows += rows.count
            lines += rows.map { row in csvLine(columns.map { cell(row[$0.name] ?? "", type: $0.type) }) }
        }
        let data = Data(lines.joined().utf8)
        return File(data: data, counts: counts, checksum: checksum(data),
                    fileName: "DynamicGlyph-gear-v\(formatVersion)-\(localDay(exportedAt, calendar: calendar)).csv")
    }

    /// `h` for a hack, `d` for a drop, then the first 128 bits of the
    /// SHA-256 of its saved key, which holds a random number made when the
    /// app launched. The same record has the same id in every export, from
    /// every iPhone it synced to; the id says nothing of who or where. The
    /// letter keeps spreadsheets from reading an id such as `12e45…` as a
    /// number.
    static func recordID(kind: Kind, key: String) -> String {
        kind.prefix + SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum Kind: String {
        case hack, drop
        var prefix: String { self == .hack ? "h" : "d" }
    }

    // MARK: - Cells

    /// A list in one cell, `;` between elements. Elements never contain `;`
    /// (they are game terms from a fixed list), and an empty element is
    /// kept, so positions survive a split on `;`.
    static func listCell(_ elements: [String]) -> String {
        elements.joined(separator: ";")
    }

    static func listElements(_ cell: String) -> [String] {
        cell.isEmpty ? [] : cell.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    }

    /// Text that a spreadsheet would read as a formula gets a leading `'`,
    /// which `Docs/GEAR_EXPORT_FORMAT.md` says to strip. Other types are
    /// numbers, booleans, dates or fixed words and are written as they are.
    static func cell(_ value: String, type: ColumnType) -> String {
        guard type == .text || type == .identifier, let first = value.first,
              ["=", "+", "-", "@", "\t", "\r"].contains(first) else { return value }
        return "'" + value
    }

    /// RFC 4180: a field with a comma, quote or line break is quoted, its
    /// quotes doubled; lines end in CRLF.
    static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",") + "\r\n"
    }

    // MARK: - Rows

    private struct Exported {
        enum Content {
            case hack(HackResultSummary, HackResultRecord)
            case drop(GearDrop)
        }
        let key: String
        let date: Date
        let content: Content

        var kind: Kind {
            if case .hack = content { return .hack }
            return .drop
        }

        var origin: CaptureOrigin? {
            switch content {
            case .hack(let summary, let record): return summary.origin ?? record.gear?.origin
            case .drop(let drop): return drop.origin
            }
        }

        /// The gear read, or why there is none.
        var reading: (status: String, reason: String?, summary: GearDropSummary?) {
            switch content {
            case .drop(let drop):
                return ("read", nil, drop.summary)
            case .hack(_, let record):
                switch record.gear?.reading {
                case .read(let summary): return ("read", nil, summary)
                case .notRead(let reason): return ("notRead", reason, nil)
                case nil: return (record.gearUnreadable ? "unsupported" : "unavailable", nil, nil)
                }
            }
        }
    }

    private typealias Row = [String: String]

    /// Records of one capture session share their key's prefix: the launch
    /// and the session number. Sessions are numbered in this file only, by
    /// their first record; `order` counts records within one.
    private static func sessionPlaces(_ records: [Exported]) -> [String: (session: Int, order: Int)] {
        let bySession = Dictionary(grouping: records) { record -> String in
            let parts = record.key.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count >= 3 ? parts.dropLast().joined(separator: "/") : record.key
        }
        let sessions = bySession.values.map { $0.sorted { ($0.date, $0.key) < ($1.date, $1.key) } }
            .sorted { ($0[0].date, $0[0].key) < ($1[0].date, $1[0].key) }
        var places: [String: (Int, Int)] = [:]
        for (session, records) in sessions.enumerated() {
            for (order, record) in records.enumerated() { places[record.key] = (session + 1, order + 1) }
        }
        return places
    }

    private static func count(_ record: Exported, into counts: inout Counts) {
        if record.kind == .hack { counts.hacks += 1 } else { counts.drops += 1 }
        let reading = record.reading
        switch reading.status {
        case "read": counts.read += 1
        case "notRead": counts.notRead += 1
        case "unsupported": counts.unsupported += 1
        default: counts.unavailable += 1
        }
        if let summary = reading.summary, !summary.panelsReadInFull { counts.partlyRead += 1 }
    }

    private static func rows(for record: Exported, place: (session: Int, order: Int), snapshot: Snapshot,
                             options: Options) -> [Row] {
        var base: Row = [
            "format_version": "\(formatVersion)",
            "record_id": recordID(kind: record.kind, key: record.key),
            "kind": record.kind.rawValue,
            "time_basis": record.kind == .hack ? "hack_first_seen" : "drop_closed",
            "session": "\(place.session)", "order": "\(place.order)",
            "exporter_app_version": snapshot.exporterVersion ?? "",
            "exporter_app_build": snapshot.exporterBuild ?? "",
        ]
        base.merge(timeCells(record.date, offsetMinutes: record.origin?.utcOffsetMinutes, precision: options.timePrecision)) { $1 }
        if let origin = record.origin {
            base["capture_mode"] = origin.captureMode?.rawValue
            base["game_language"] = origin.gameLanguage?.rawValue
            base["game_language_source"] = origin.gameLanguageSource?.rawValue
            base["source_app_version"] = origin.appVersion
            base["source_app_build"] = origin.appBuild
        }
        if case .hack(let summary, let saved) = record.content {
            base.merge(hackCells(summary, portalLevel: saved.gear?.portalLevel)) { $1 }
            let portal = saved.gear?.portalLevel?.faction
            base["portal_faction"] = portal?.rawValue
            base["portal_alignment"] = alignment(portal: portal, player: record.origin?.playerFaction)
        }
        base["player_faction"] = record.origin?.playerFaction?.rawValue
        let reading = record.reading
        base["read_status"] = reading.status
        base["read_reason"] = reading.reason
        guard let summary = reading.summary else { return [base] }
        base["association"] = summary.association.rawValue
        base["observed_panels_read_in_full"] = bool(summary.panelsReadInFull)
        base["both_panels_read"] = bool(summary.bothPanelsRead)
        // A record whose panels were never read still gets its row, item
        // columns blank: blank is not zero.
        guard !summary.panels.isEmpty else { return [base] }
        var rows: [Row] = []
        for panel in summary.panels {
            var panelRow = base
            panelRow["panel"] = panel.stage.rawValue
            panelRow["panel_partial"] = bool(panel.partial)
            panelRow["panel_effects"] = panel.effects.map(listCell)
            guard !panel.entries.isEmpty else { rows.append(panelRow); continue }
            for entry in panel.entries {
                var row = panelRow
                row["slot"] = "\(entry.position)"
                row["item"] = entry.item
                row["level"] = entry.level.map(String.init)
                row["level_state"] = entry.levelState.rawValue
                if let fixed = entry.intrinsicRarity {
                    row["rarity"] = fixed.rawValue
                    row["rarity_source"] = "fixed"
                } else if let read = entry.rarity {
                    row["rarity"] = read.rawValue
                    row["rarity_source"] = "read"
                }
                row["quantity"] = "\(entry.quantity)"
                row["multiplied"] = entry.multiplied.map(bool)
                rows.append(row)
            }
        }
        return rows
    }

    private static func hackCells(_ summary: HackResultSummary, portalLevel: PortalLevelEstimate?) -> Row {
        var row: Row = [
            "hack_state": summary.state.rawValue,
            "hack_glyph_count": "\(summary.slots.count)",
        ]
        if let bonus = summary.hackingBonus {
            row["hacking_bonus"] = "\(bonus.percent)"
            row["hacking_bonus_final"] = bool(bonus.isFinal)
        }
        if let bonus = summary.speedBonus {
            row["speed_bonus"] = "\(bonus.percent)"
            row["speed_bonus_final"] = bool(bonus.isFinal)
        }
        if let commands = summary.commands {
            row["command_mode"] = commands.mode.rawValue
            row["speed_command"] = commands.presentation.effective?.rawValue
            row["speed_command_status"] = commands.presentation.status.rawValue
            row["key_command"] = commands.gear.effective?.rawValue
            row["key_command_status"] = commands.gear.status.rawValue
        }
        if let level = portalLevel {
            row["portal_level_low"] = "\(level.lowest)"
            row["portal_level_high"] = "\(level.highest)"
            row["portal_level_confidence"] = level.confidence.rawValue
            row["portal_level_conflict"] = bool(level.conflict)
        }
        return row
    }

    /// The interval holding the record's date, in its capturing iPhone's
    /// offset when known, otherwise in UTC with the local columns blank: a
    /// record never gets a time zone it wasn't captured in.
    static func timeCells(_ date: Date, offsetMinutes: Int?, precision: TimePrecision) -> [String: String] {
        let local = offsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local ?? TimeZone(identifier: "UTC")!
        guard let interval = calendar.dateInterval(of: precision == .hour ? .hour : .day, for: date) else { return [:] }
        var cells = ["time_bucket_start_utc": interval.start.formatted(.iso8601),
                     "time_bucket_end_utc": interval.end.formatted(.iso8601)]
        if local != nil, let offsetMinutes {
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            cells["local_date"] = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if precision == .hour { cells["local_hour"] = parts.hour.map(String.init) }
            cells["utc_offset_minutes"] = "\(offsetMinutes)"
        }
        return cells
    }

    /// The portal's side as the player saw it: Machina whoever the player is;
    /// otherwise their own faction's or the other's, once both are known.
    /// Neutral portals have no resonator bars and aren't recognized yet.
    static func alignment(portal: PortalFaction?, player: PortalFaction?) -> String? {
        guard let portal else { return nil }
        if portal == .machina { return "machina" }
        guard let player, player != .machina else { return nil }
        return portal == player ? "same_faction" : "enemy"
    }

    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    private static func localDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension GearExport {
    /// A readable summary of the same records: totals, then each record as
    /// its card shows it. Labels follow the app's language; item names stay
    /// as the English game prints them. Times are the file's intervals, never
    /// the exact minute.
    static func text(_ snapshot: Snapshot, counts: Counts, scope: String, options: Options,
                     now: Date = Date()) -> String {
        let records = snapshot.records.filter { $0.summary?.isClosed == true }
        let drops = snapshot.drops.filter { $0.drop != nil }
        let statistics = HackStatistics(records: records, drops: drops, period: .all, now: now)
        var lines = [String(localized: "DynamicGlyph gear: \(scope)",
                            comment: "Gear export summary, first line. The placeholder is what was exported, such as Today or 3 selected.")]
        lines.append(String(localized: "\(statistics.items) items recognized",
                            comment: "Hack card, gear section: both item panels were read in full."))
        var tally: [String] = []
        if counts.hacks > 0 {
            tally.append(String(localized: "Hack results: \(counts.hacks)",
                                comment: "Statistics, delete confirmation: how many hacks are chosen."))
        }
        if counts.drops > 0 {
            tally.append(String(localized: "Drops: \(counts.drops)",
                                comment: "Statistics, delete confirmation: how many drop groups no hack claimed are chosen."))
        }
        lines.append(tally.joined(separator: " · "))
        lines.append(String(localized: "Only what the app read is here: hacks and drops it didn't see, or read no items from, aren't counted.",
                            comment: "Gear export: coverage note."))
        if !statistics.gear.isEmpty {
            lines.append("")
            lines.append(String(localized: "Totals", comment: "Gear export summary: heading over the item totals."))
            for group in statistics.gear {
                var parts = group.chips.map { chip -> String in
                    switch chip.split {
                    case .level(let level): return "L\(level) \(chip.quantity)"
                    case .levelUnread: return "L? \(chip.quantity)"
                    case .rarity(let rarity): return "\(rarity.label) \(chip.quantity)"
                    }
                }
                if group.multiplied > 0 {
                    parts.append(String(localized: "\(group.multiplied) multiplied",
                                        comment: "Statistics summary card: how many of those items came from drops the game multiplied, as on the first hack of the day."))
                }
                lines.append("  \(group.item) \(group.total)" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"))
            }
        }
        let entries: [(date: Date, lines: [String])] = records.map { record in
            let offset = record.summary?.origin?.utcOffsetMinutes ?? record.gear?.origin?.utcOffsetMinutes
            let time = timeLabel(record.date, offsetMinutes: offset, precision: options.timePrecision)
            var lines = [String(localized: "Hack result, \(time)",
                                comment: "Statistics, selecting: VoiceOver label of a hack's card. The placeholder is its time.")]
            switch record.gear?.reading {
            case .read(let summary): lines += panelLines(summary)
            case .notRead, nil: lines.append("  " + String(localized: "Gear not read", comment: "Hack card, gear section: no item panels were read."))
            }
            return (record.date, lines)
        } + drops.compactMap { record in
            guard let drop = record.drop else { return nil }
            let time = timeLabel(record.date, offsetMinutes: drop.origin?.utcOffsetMinutes,
                                 precision: options.timePrecision)
            return (record.date, [String(localized: "Item drop, \(time)",
                                         comment: "Statistics, selecting: VoiceOver label of a drop group's card. The placeholder is its time.")]
                    + panelLines(drop.summary))
        }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            lines.append("")
            lines += entry.lines
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The record's interval as the file gives it: `2026-10-03 07:00–08:00
    /// UTC+08:00`, or the date alone; in UTC when its offset isn't known.
    static func timeLabel(_ date: Date, offsetMinutes: Int?, precision: TimePrecision) -> String {
        let zone = offsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? TimeZone(identifier: "UTC")!
        let start = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        var label = String(format: "%04d-%02d-%02d", start.year ?? 0, start.month ?? 0, start.day ?? 0)
        if precision == .hour, let hour = start.hour {
            label += String(format: " %02d:00–%02d:00", hour, (hour + 1) % 24)
        }
        guard zone != nil, let offsetMinutes else { return label + " UTC" }
        let magnitude = abs(offsetMinutes)
        return label + String(format: " UTC%@%02d:%02d", offsetMinutes < 0 ? "-" : "+", magnitude / 60, magnitude % 60)
    }

    /// What one card's export is called: its kind, with no time.
    static func scope(of kind: Kind) -> String {
        kind == .hack
            ? String(localized: "Hack result", comment: "Gear export: what is exported when one hack's card is.")
            : String(localized: "Drop", comment: "Statistics list: a card for one group of item panels that no Glyph hack claimed.")
    }

    private static func panelLines(_ summary: GearDropSummary) -> [String] {
        summary.panels.map { panel in
            var title = panel.stage == .bonus ? String(localized: "Bonus items") : String(localized: "From the portal")
            if panel.partial { title += " " + String(localized: "· partly read") }
            let items = panel.entries.map { entry -> String in
                guard let item = entry.item else {
                    return String(localized: "Unrecognized item") + " ×\(entry.quantity)"
                }
                var text = (entry.level.map { "L\($0) \(item)" } ?? item) + " ×\(entry.quantity)"
                var notes: [String] = []
                if let rarity = entry.intrinsicRarity ?? entry.rarity { notes.append(rarity.label) }
                if entry.levelState == .unreadable { notes.append(String(localized: "level unread")) }
                if entry.multiplied == true {
                    notes.append(String(localized: "multiplied",
                                        comment: "Hack card, one item: the game showed its quantity in red, as on the first hack of the day."))
                }
                if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
                return text
            }
            return "  \(title): " + (items.isEmpty ? String(localized: "No items read") : items.joined(separator: ", "))
        }
    }
}

/// Prepared files wait in their own folder in the temporary directory while
/// the share sheet needs them, and are removed after. Nothing else is
/// touched: only folders this code named.
enum GearExportFiles {
    static let folderPrefix = "GearExport-"

    static func write(_ file: GearExport.File,
                      in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.fileName)
        try file.data.write(to: url, options: .atomic)
        return url
    }

    /// The folder `write` made for this file.
    static func remove(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// At launch, when no share sheet can still be using one.
    static func removeStale(in root: URL = FileManager.default.temporaryDirectory) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
