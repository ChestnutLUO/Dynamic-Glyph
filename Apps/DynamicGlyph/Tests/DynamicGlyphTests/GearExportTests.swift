import Foundation
import Testing
import GlyphRecognition

@MainActor
@Suite("Gear export")
struct GearExportTests {
    private let base = Date(timeIntervalSince1970: 1_790_983_200) // 2026-10-02T23:20:00Z

    private func entry(_ position: Int, _ item: String?, level: Int? = nil, quantity: Int = 1,
                       rarity: GearDropEntry.Rarity? = nil, multiplied: Bool? = nil,
                       levelState: GearDropEntry.Level? = nil) -> GearDropEntry {
        GearDropEntry(column: position % 2, row: position / 2, item: item,
                      levelState: levelState ?? (level == nil ? .notApplicable : .known),
                      level: level, quantity: quantity, rarity: rarity, multiplied: multiplied)
    }

    private func group(_ panels: [GearDropSummary.Panel], association: GearDropSummary.Association = .ordered,
                       hack: Int? = 1) -> GearDropSummary {
        GearDropSummary(groupID: 1, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: hack,
                        association: association, panels: panels)
    }

    private func hack(_ id: Int, closed: Bool = true, origin: CaptureOrigin? = nil,
                      hacking: HackResultSummary.Bonus? = .init(percent: 120, isFinal: true),
                      speed: HackResultSummary.Bonus? = .init(percent: 40, isFinal: false)) -> HackResultSummary {
        var summary = HackResultSummary(captureSessionID: 1, hackID: id, state: closed ? .complete : .partial,
                                        isClosed: closed, closeReason: closed ? "panelLeft" : nil,
                                        hackingBonus: hacking, speedBonus: speed,
                                        slots: [.init(glyph: "help", outcome: .accepted, check: nil, comparison: .agreement),
                                                .init(glyph: nil, outcome: .unknown, check: nil, comparison: .unknownAssociation)])
        summary.origin = origin
        return summary
    }

    private func origin(offset: Int?, build: String = "70") -> CaptureOrigin {
        CaptureOrigin(appVersion: "0.1.0", appBuild: build, captureMode: .glyphAssistance, gameLanguage: .japanese,
                      gameLanguageSource: .chosen, utcOffsetMinutes: offset)
    }

    private func snapshot(_ records: [HackResultRecord] = [], _ drops: [GearDropRecord] = []) -> GearExport.Snapshot {
        GearExport.Snapshot(records: records, drops: drops, exporterVersion: "0.1.0", exporterBuild: "73")
    }

    /// The file as rows of named cells, read back with an RFC 4180 parser.
    private func table(_ file: GearExport.File) throws -> [[String: String]] {
        let lines = parse(String(decoding: file.data, as: UTF8.self))
        let header = try #require(lines.first)
        #expect(header == GearExport.columns.map(\.name))
        return lines.dropFirst().map { fields in
            #expect(fields.count == header.count)
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }

    private func parse(_ text: String) -> [[String]] {
        var lines: [[String]] = [], fields: [String] = [], field = "", quoted = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                fields.append(field); field = ""
            } else if character == "\r\n" || character == "\n" {
                fields.append(field); lines.append(fields); fields = []; field = ""
            } else {
                field.append(character)
            }
        }
        return lines
    }

    @Test("A record id is the kind's letter and the first 128 bits of SHA-256 of its saved key")
    func recordIDs() {
        // SHA-256("a") starts ca978112ca1bbdcafac231b39a23dc4d.
        #expect(GearExport.recordID(kind: .hack, key: "a") == "hca978112ca1bbdcafac231b39a23dc4d")
        #expect(GearExport.recordID(kind: .drop, key: "a") == "dca978112ca1bbdcafac231b39a23dc4d")
        #expect(GearExport.recordID(kind: .drop, key: "launch/1/drop-1") != GearExport.recordID(kind: .drop, key: "launch/2/drop-1"),
                "Identical items in different records keep different ids")
    }

    @Test("A hack's id stays the same when its gear arrives, and its gear is never a record of its own")
    func idSurvivesLateGear() throws {
        let key = "launch/1/1"
        let before = HackResultRecord(id: key, date: base, summary: hack(1))
        var after = before
        after.gear = HackGearAttachment(captureSessionID: 1, hackID: 1,
                                        reading: .read(group([.init(stage: .portal, entries: [entry(0, "Resonator", level: 8, quantity: 2)], partial: false)])))
        let first = try table(GearExport.make(snapshot([before]), options: .init(), exportedAt: base))
        let second = try table(GearExport.make(snapshot([after]), options: .init(), exportedAt: base))
        #expect(first.map { $0["record_id"] } == [GearExport.recordID(kind: .hack, key: key)])
        #expect(Set(second.map { $0["record_id"] }) == [GearExport.recordID(kind: .hack, key: key)])
        #expect(second.allSatisfy { $0["kind"] == "hack" })
        #expect(first.first?["read_status"] == "unavailable" && second.first?["read_status"] == "read")
    }

    @Test("Each kind of missing gear has its own status, and records this build can't read or still open are left out")
    func statuses() throws {
        var notRead = HackResultRecord(id: "l/1/2", date: base.addingTimeInterval(1), summary: hack(2))
        notRead.gear = HackGearAttachment(captureSessionID: 1, hackID: 2, reading: .notRead(reason: "captureStopped"))
        var unsupported = HackResultRecord(id: "l/1/3", date: base.addingTimeInterval(2), summary: hack(3))
        unsupported.gearUnreadable = true
        let records = [
            HackResultRecord(id: "l/1/1", date: base, summary: hack(1)),
            notRead, unsupported,
            HackResultRecord(id: "l/1/4", date: base.addingTimeInterval(3), summary: hack(4, closed: false)),
            HackResultRecord(id: "future", date: base, summary: nil),
        ]
        let drops = [GearDropRecord(id: "l/1/drop-9", date: base, drop: nil)]
        let file = GearExport.make(snapshot(records, drops), options: .init(), exportedAt: base)
        let rows = try table(file)
        #expect(rows.map { $0["read_status"] } == ["unavailable", "notRead", "unsupported"])
        #expect(rows.map { $0["read_reason"] } == ["", "captureStopped", ""])
        #expect(rows.allSatisfy { $0["item"] == "" && $0["quantity"] == "" && $0["panel"] == "" },
                "No gear is blank, not zero")
        let counts = file.counts
        #expect(counts.hacks == 3 && counts.drops == 0 && counts.rows == 3)
        #expect(counts.unavailable == 1 && counts.notRead == 1 && counts.unsupported == 1)
        #expect(counts.skipped == 2 && counts.inProgress == 1)
    }

    @Test("A panel with no row read and a reading with no panel each keep a row, item columns blank")
    func sentinelRows() throws {
        let emptyPanel = GearDrop(captureSessionID: 1, summary: group([
            .init(stage: .portal, entries: [entry(0, "Power Cube", level: 7)], partial: false),
            .init(stage: .bonus, entries: [], partial: true)], association: .noWaitingHack, hack: nil))
        let noPanels = GearDrop(captureSessionID: 1, summary: group([], association: .uncertainContinuity, hack: nil))
        let rows = try table(GearExport.make(snapshot([], [
            GearDropRecord(id: "l/1/drop-1", date: base, drop: emptyPanel),
            GearDropRecord(id: "l/1/drop-2", date: base.addingTimeInterval(5), drop: noPanels)]),
            options: .init(), exportedAt: base))
        #expect(rows.map { $0["panel"] } == ["portal", "bonus", ""])
        #expect(rows.map { $0["item"] } == ["Power Cube", "", ""])
        #expect(rows[1]["panel_partial"] == "true" && rows[1]["quantity"] == "")
        #expect(rows.map { $0["observed_panels_read_in_full"] } == ["false", "false", "false"])
        #expect(rows.map { $0["association"] } == ["noWaitingHack", "noWaitingHack", "uncertainContinuity"])
        #expect(rows.allSatisfy { $0["kind"] == "drop" && $0["time_basis"] == "drop_closed" && $0["hack_state"] == "" })
    }

    @Test("Items keep their slot, level, rarity source and multiplier; unknown is blank, false is false")
    func itemCells() throws {
        let drop = GearDrop(captureSessionID: 1, summary: group([.init(stage: .portal, entries: [
            entry(0, "Resonator", level: 8, quantity: 2, multiplied: true),
            entry(1, "Hypercube", multiplied: false),
            entry(2, "Portal Shield", rarity: .rare),
            entry(3, nil, quantity: 3, levelState: .unreadable),
            entry(5, "XMP Burster", levelState: .unreadable),
        ], partial: false, effects: ["ITO EN (+)", "ITO EN (-)"])], hack: nil))
        let rows = try table(GearExport.make(snapshot([], [GearDropRecord(id: "l/1/drop-1", date: base, drop: drop)]),
                                             options: .init(), exportedAt: base))
        #expect(rows.map { $0["slot"] } == ["0", "1", "2", "3", "5"])
        #expect(rows.map { $0["item"] } == ["Resonator", "Hypercube", "Portal Shield", "", "XMP Burster"])
        #expect(rows.map { $0["level"] } == ["8", "", "", "", ""])
        #expect(rows.map { $0["level_state"] } == ["known", "notApplicable", "notApplicable", "unreadable", "unreadable"])
        #expect(rows.map { $0["rarity"] } == ["", "veryRare", "rare", "", ""])
        #expect(rows.map { $0["rarity_source"] } == ["", "fixed", "read", "", ""])
        #expect(rows.map { $0["quantity"] } == ["2", "1", "1", "3", "1"])
        #expect(rows.map { $0["multiplied"] } == ["true", "false", "", "", ""])
        #expect(rows.allSatisfy { GearExport.listElements($0["panel_effects"] ?? "") == ["ITO EN (+)", "ITO EN (-)"] })
    }

    @Test("A hack's bonuses keep their finality, and its portal level its confidence and conflict")
    func hackCells() throws {
        var summary = hack(1, hacking: .init(percent: 120, isFinal: true), speed: .init(percent: 40, isFinal: false))
        var commands = HackCommandSummary()
        commands.mode = .portal
        commands.presentation.status = .confirmed; commands.presentation.lastObserved = .complex
        commands.gear.status = .unresolved; commands.gear.lastObserved = .keysOnly
        summary = HackResultSummary(captureSessionID: 1, hackID: 1, state: .complete, isClosed: true,
                                    closeReason: "panelLeft", hackingBonus: summary.hackingBonus,
                                    speedBonus: summary.speedBonus, slots: summary.slots, commands: commands)
        var record = HackResultRecord(id: "l/1/1", date: base, summary: summary)
        var gear = HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .read(group([])))
        gear.portalLevel = PortalLevelRules.estimate(resonators: [8, 6, 7, 6, 6, 6, 8, 7], unreadSlots: 0,
                                                     badgeHue: 329, glyphCount: 4)
        record.gear = gear
        let level = try #require(gear.portalLevel)
        let row = try #require(try table(GearExport.make(snapshot([record]), options: .init(), exportedAt: base)).first)
        #expect(row["hack_state"] == "complete" && row["hack_glyph_count"] == "2")
        #expect(row["hacking_bonus"] == "120" && row["hacking_bonus_final"] == "true")
        #expect(row["speed_bonus"] == "40" && row["speed_bonus_final"] == "false")
        #expect(row["command_mode"] == "portal")
        #expect(row["speed_command"] == "complex" && row["speed_command_status"] == "confirmed")
        #expect(row["key_command"] == "" && row["key_command_status"] == "unresolved",
                "An unresolved command isn't reported as the one in effect")
        #expect(row["portal_level_low"] == "\(level.lowest)" && row["portal_level_high"] == "\(level.highest)")
        #expect(row["portal_level_confidence"] == level.confidence.rawValue)
        #expect(row["portal_level_conflict"] == (level.conflict ? "true" : "false"))
        #expect(row["both_panels_read"] == "false" && row["panel"] == "")
    }

    @Test("Time is an interval in the capturing iPhone's offset; a record without one gets UTC and no local date")
    func timeIntervals() {
        // 23:20 UTC is 07:20 the next day at UTC+8.
        let east = GearExport.timeCells(base, offsetMinutes: 480, precision: .hour)
        #expect(east["time_bucket_start_utc"] == "2026-10-02T23:00:00Z" && east["time_bucket_end_utc"] == "2026-10-03T00:00:00Z")
        #expect(east["local_date"] == "2026-10-03" && east["local_hour"] == "7" && east["utc_offset_minutes"] == "480")
        // At UTC+5:45 a local hour starts at a quarter past in UTC.
        let nepal = GearExport.timeCells(base, offsetMinutes: 345, precision: .hour)
        #expect(nepal["time_bucket_start_utc"] == "2026-10-02T23:15:00Z" && nepal["local_hour"] == "5")
        let west = GearExport.timeCells(base, offsetMinutes: -420, precision: .day)
        #expect(west["time_bucket_start_utc"] == "2026-10-02T07:00:00Z" && west["time_bucket_end_utc"] == "2026-10-03T07:00:00Z")
        #expect(west["local_date"] == "2026-10-02" && west["local_hour"] == nil)
        let unknown = GearExport.timeCells(base, offsetMinutes: nil, precision: .hour)
        #expect(unknown["time_bucket_start_utc"] == "2026-10-02T23:00:00Z")
        #expect(unknown["local_date"] == nil && unknown["local_hour"] == nil && unknown["utc_offset_minutes"] == nil)
        let unknownDay = GearExport.timeCells(base, offsetMinutes: nil, precision: .day)
        #expect(unknownDay["time_bucket_start_utc"] == "2026-10-02T00:00:00Z")
    }

    @Test("Records keep the offset and build they were captured with, across a time change and another exporter")
    func originPerRecord() throws {
        // The same session either side of a daylight-saving change, then a
        // record from an older build with no origin at all.
        let records = [
            HackResultRecord(id: "l/1/1", date: base, summary: hack(1, origin: origin(offset: 60, build: "70"))),
            HackResultRecord(id: "l/1/2", date: base.addingTimeInterval(3600), summary: hack(2, origin: origin(offset: 120, build: "70"))),
            HackResultRecord(id: "old/1/1", date: base.addingTimeInterval(7200), summary: hack(3)),
        ]
        let rows = try table(GearExport.make(snapshot(records), options: .init(), exportedAt: base))
        #expect(rows.map { $0["utc_offset_minutes"] } == ["60", "120", ""])
        #expect(rows.map { $0["local_hour"] } == ["0", "2", ""])
        #expect(rows.map { $0["source_app_build"] } == ["70", "70", ""])
        #expect(rows.map { $0["game_language"] } == ["ja", "ja", ""])
        #expect(rows.map { $0["game_language_source"] } == ["chosen", "chosen", ""])
        #expect(rows.map { $0["capture_mode"] } == ["glyphAssistance", "glyphAssistance", ""])
        #expect(rows.allSatisfy { $0["exporter_app_build"] == "73" && $0["exporter_app_version"] == "0.1.0" })
    }

    @Test("Each hack says whether its portal was the player's faction's, the other side's or Machina's")
    func alignment() throws {
        func record(_ id: Int, portal: PortalFaction?, player: PortalFaction?) -> HackResultRecord {
            var origin = origin(offset: 0)
            origin.playerFaction = player
            var record = HackResultRecord(id: "l/1/\(id)", date: base.addingTimeInterval(Double(id)), summary: hack(id, origin: origin))
            var gear = HackGearAttachment(captureSessionID: 1, hackID: id, reading: .read(group([])))
            let screen = PortalScreenEvidence(sourceTime: 1, resonators: [], unreadSlots: 8, badgeHue: nil, faction: portal)
            gear.portalLevel = PortalLevelRules.estimate(screen: screen, glyphCount: 4)
            record.gear = gear
            return record
        }
        let records = [record(1, portal: .resistance, player: .resistance), record(2, portal: .enlightened, player: .resistance),
                       record(3, portal: .machina, player: .enlightened), record(4, portal: .machina, player: nil),
                       record(5, portal: .enlightened, player: nil), record(6, portal: nil, player: .resistance),
                       record(7, portal: .enlightened, player: .enlightened), record(8, portal: .resistance, player: .enlightened)]
        let drop = GearDropRecord(id: "l/1/drop-9", date: base.addingTimeInterval(9),
                                  drop: GearDrop(captureSessionID: 1, summary: group([], hack: nil), origin: origin(offset: 0)))
        let rows = try table(GearExport.make(snapshot(records, [drop]), options: .init(), exportedAt: base))
        #expect(rows.map { $0["portal_faction"] } == ["resistance", "enlightened", "machina", "machina", "enlightened", "", "enlightened", "resistance", ""])
        #expect(rows.map { $0["player_faction"] } == ["resistance", "resistance", "enlightened", "", "", "resistance", "enlightened", "enlightened", ""])
        #expect(rows.map { $0["portal_alignment"] } == ["same_faction", "enemy", "machina", "machina", "", "", "same_faction", "enemy", ""],
                "Machina needs no player faction; the others do, and a hack without a portal screen has none")
    }

    @Test("Date only leaves the hour out of every row")
    func dateOnly() throws {
        let records = [HackResultRecord(id: "l/1/1", date: base, summary: hack(1, origin: origin(offset: 480)))]
        let rows = try table(GearExport.make(snapshot(records), options: .init(timePrecision: .day), exportedAt: base))
        #expect(rows.first?["local_hour"] == "" && rows.first?["local_date"] == "2026-10-03")
        #expect(rows.first?["time_bucket_start_utc"] == "2026-10-02T16:00:00Z")
        #expect(GearExport.Options().timePrecision == .hour, "The hour is the default")
    }

    @Test("Sessions are numbered within the file by first record, and records ordered within each")
    func sessions() throws {
        let records = [
            HackResultRecord(id: "L/2/5", date: base.addingTimeInterval(100), summary: hack(5)),
            HackResultRecord(id: "L/1/1", date: base, summary: hack(1)),
        ]
        let drops = [GearDropRecord(id: "L/1/drop-3", date: base.addingTimeInterval(10),
                                    drop: GearDrop(captureSessionID: 1, summary: group([], hack: nil)))]
        let rows = try table(GearExport.make(snapshot(records, drops), options: .init(), exportedAt: base))
        #expect(rows.map { "\($0["session"] ?? "")/\($0["order"] ?? "")" } == ["1/1", "1/2", "2/1"])
        #expect(rows.allSatisfy { !($0["record_id"] ?? "").contains("L/") }, "No key reaches the file")
    }

    @Test("The same snapshot makes the same bytes, whatever arrives after it was taken")
    func snapshotStable() throws {
        let suite = "export-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.keepsHackResults = false
        let results = HackResults(preferences: preferences, store: nil)
        results.receive(hack(1))
        let snapshot = GearExport.Snapshot(records: results.records, drops: results.drops,
                                           exporterVersion: "0.1.0", exporterBuild: "73")
        let before = GearExport.make(snapshot, options: .init(), exportedAt: base)
        results.receive(hack(2))
        results.receiveDrop(GearDrop(captureSessionID: 1, summary: group([], hack: nil)))
        let after = GearExport.make(snapshot, options: .init(), exportedAt: base)
        #expect(before.data == after.data && before.checksum == after.checksum)
        #expect(before.checksum == GearExport.checksum(before.data) && before.checksum.count == 64)
        #expect(after.counts.hacks == 1 && after.counts.drops == 0)
    }

    @Test("No column holds a portal name, note, exact time or device; every cell matches its column's type")
    func columnSafety() throws {
        let names = GearExport.columns.map(\.name)
        for word in ["portal_name", "note", "device", "recorded_at", "uuid", "key", "path"] {
            #expect(!names.contains { $0.contains(word) && $0 != "key_command" && $0 != "key_command_status" }, "\(word)")
        }
        let drop = GearDrop(captureSessionID: 1, summary: group([.init(stage: .portal, entries: [
            entry(0, "Resonator", level: 8, multiplied: true), entry(1, nil, levelState: .unreadable)],
            partial: false, effects: ["ITO EN (+)"])], hack: nil), origin: origin(offset: -210))
        let rows = try table(GearExport.make(snapshot([HackResultRecord(id: "l/1/1", date: base, summary: hack(1, origin: origin(offset: 345)))],
                                                      [GearDropRecord(id: "l/1/drop-2", date: base, drop: drop)]),
                                             options: .init(), exportedAt: base))
        let patterns: [GearExport.ColumnType: String] = [
            .integer: #"^-?[0-9]+$"#, .boolean: "^(true|false)$", .enumeration: "^[A-Za-z][A-Za-z0-9_-]*$",
            .identifier: "^[A-Za-z][A-Za-z0-9_-]*$", .timestamp: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#,
            .date: #"^\d{4}-\d{2}-\d{2}$"#, .text: #"^[^=+\-@\t\r]"#,
        ]
        for row in rows {
            for column in GearExport.columns {
                let value = row[column.name] ?? ""
                guard !value.isEmpty, let pattern = patterns[column.type] else { continue }
                #expect(value.range(of: pattern, options: .regularExpression) != nil, "\(column.name): \(value)")
            }
        }
        #expect(rows.contains { $0["utc_offset_minutes"] == "-210" }, "A negative number is a number, not a formula")
    }

    @Test("Text a spreadsheet would run is marked, and fields are quoted as RFC 4180 says")
    func cellEncoding() {
        #expect(GearExport.cell("=SUM(A1)", type: .text) == "'=SUM(A1)")
        #expect(GearExport.cell("+1", type: .text) == "'+1")
        #expect(GearExport.cell("ITO EN (+)", type: .text) == "ITO EN (+)")
        #expect(GearExport.cell("-210", type: .integer) == "-210")
        #expect(GearExport.csvLine(["a,b", "say \"hi\"", "two\nlines", "plain"])
                == "\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",plain\r\n")
        #expect(parse(GearExport.csvLine(["a,b", "say \"hi\"", "two\nlines", ""])) == [["a,b", "say \"hi\"", "two\nlines", ""]])
    }

    @Test("A list cell keeps empty elements, trailing ones included, through a split")
    func listCells() {
        for list in [["a", "", ""], ["", "b"], ["ITO EN (+)", "ITO EN (-)"], [], ["", ""]] {
            #expect(GearExport.listElements(GearExport.listCell(list)) == (list == [""] ? [] : list))
        }
    }

    @Test("The text summary names the items and says what wasn't read")
    func textSummary() {
        var notRead = HackResultRecord(id: "l/1/2", date: base, summary: hack(2))
        notRead.gear = HackGearAttachment(captureSessionID: 1, hackID: 2, reading: .notRead(reason: "captureStopped"))
        let drop = GearDrop(captureSessionID: 1, summary: group([.init(stage: .portal, entries: [
            entry(0, "Resonator", level: 8, quantity: 2, multiplied: true), entry(1, nil, quantity: 1)], partial: true)], hack: nil))
        let snapshot = snapshot([notRead], [GearDropRecord(id: "l/1/drop-1", date: base, drop: drop)])
        let file = GearExport.make(snapshot, options: .init(), exportedAt: base)
        let text = GearExport.text(snapshot, counts: file.counts, scope: "Today", options: .init(), now: base)
        #expect(text.contains("Today"))
        #expect(text.contains("Resonator 2"))
        #expect(text.contains("L8 Resonator ×2"))
        #expect(text.contains("Unrecognized item ×1"))
        #expect(text.contains("Gear not read"))
    }

    @Test("The text summary gives each record's interval, never its minute, and the date alone when the hour is off")
    func textSummaryTimes() throws {
        let records = [
            HackResultRecord(id: "l/1/1", date: base, summary: hack(1, origin: origin(offset: 480))),
            HackResultRecord(id: "old/1/2", date: base.addingTimeInterval(60), summary: hack(2)),
        ]
        let drops = [GearDropRecord(id: "l/1/drop-3", date: base.addingTimeInterval(120),
                                    drop: GearDrop(captureSessionID: 1, summary: group([], hack: nil),
                                                   origin: origin(offset: -210)))]
        let snapshot = snapshot(records, drops)
        let counts = GearExport.make(snapshot, options: .init(), exportedAt: base).counts
        let hourly = GearExport.text(snapshot, counts: counts, scope: GearExport.scope(of: .drop), options: .init(), now: base)
        #expect(hourly.contains("2026-10-03 07:00–08:00 UTC+08:00"))
        #expect(hourly.contains("2026-10-02 23:00–00:00 UTC"), "No offset: the UTC hour")
        #expect(hourly.contains("2026-10-02 19:00–20:00 UTC-03:30"))
        let daily = GearExport.text(snapshot, counts: counts, scope: GearExport.scope(of: .hack),
                                    options: .init(timePrecision: .day), now: base)
        #expect(daily.contains("2026-10-03 UTC+08:00") && daily.contains("2026-10-02 UTC"))
        for text in [hourly, daily] {
            // Any hh:mm left must be a whole hour or a UTC offset.
            let minutes = text.matches(of: /(UTC[+-])?\d{2}:(\d{2})/).filter { $0.output.1 == nil && $0.output.2 != "00" }
            #expect(minutes.isEmpty, "\(minutes.map { String($0.output.0) })")
            #expect(!text.contains("23:20") && !text.contains("07:20") && !text.contains("11:20"))
        }
        #expect(!daily.contains("–"), "Date only has no hours")
        for kind in [GearExport.Kind.hack, .drop] {
            #expect(GearExport.scope(of: kind).rangeOfCharacter(from: .decimalDigits) == nil, "One card's heading has no time")
        }
    }

    @Test("Prepared files live in their own folder until removed; launch cleanup touches nothing else")
    func temporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("spikeB-2026-10-02T18-06-56Z", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let file = GearExport.make(snapshot([HackResultRecord(id: "l/1/1", date: base, summary: hack(1))]),
                                   options: .init(), exportedAt: base, calendar: utc)
        #expect(file.fileName == "DynamicGlyph-gear-v1-2026-10-02.csv")
        let first = try GearExportFiles.write(file, in: root)
        let second = try GearExportFiles.write(file, in: root)
        #expect(try Data(contentsOf: first) == file.data)
        GearExportFiles.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        GearExportFiles.removeStale(in: root)
        #expect(!FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("A record's origin reads the build, mode, language and offset at that moment")
    func currentOrigin() throws {
        let chosen = GameLanguageMemory(language: .japanese, isAutomatic: false)
        let automatic = GameLanguageMemory(language: .english, isAutomatic: true)
        let zone = try #require(TimeZone(secondsFromGMT: 345 * 60))
        let one = CaptureOrigin.current(mode: .gearOnly, languages: chosen, playerFaction: .enlightened, timeZone: zone, now: base)
        #expect(one.captureMode == .gearOnly && one.gameLanguage == .japanese && one.gameLanguageSource == .chosen)
        #expect(one.playerFaction == .enlightened)
        #expect(one.utcOffsetMinutes == 345)
        let guess = CaptureOrigin.current(mode: .glyphAssistance, languages: automatic, timeZone: zone, now: base)
        #expect(guess.gameLanguageSource == .assumed && guess.gameLanguage == .english,
                "The starting guess is assumed until a screen confirms it")
        automatic.found(.english)
        let confirmed = CaptureOrigin.current(mode: .glyphAssistance, languages: automatic, timeZone: zone, now: base)
        #expect(confirmed.gameLanguageSource == .detected && confirmed.gameLanguage == .english,
                "Confirming the same language counts, though nothing changed")
    }
}
