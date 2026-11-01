import SwiftUI
import GlyphRecognition

/// Every figure for the period: bonuses, each Glyph, and, for testers, gear
/// totals and how often each screen was read.
struct HackStatisticsView: View {
    /// The Statistics page's range, as it shows it.
    let statistics: HackStatistics
    /// The page's range in full, which Summary follows and can't change.
    let dateLine: String
    /// Reading accuracy is for testers: shown while logs are saved.
    let showsAccuracy: Bool
    let keepsResults: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let period = statistics.chartPeriod
        NavigationStack {
            List {
                Section {
                    Text(verbatim: dateLine)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text(keepsResults
                         ? LocalizedStringResource("All covers the results kept on this iPhone, up to 90 days.")
                         : LocalizedStringResource("Results are not kept, so these cover only hacks since the app opened."))
                }
                if BonusOverTimeChart.isShown(for: statistics, period: period) {
                    Section {
                        BonusOverTimeChart(statistics: statistics, period: period)
                            .padding(.vertical, 4)
                    } header: {
                        Text("Bonuses and accuracy over time")
                    } footer: {
                        Text("Each point is one day's average of final bonuses and the share of its Glyphs the game accepted. Tap a line's name to show or hide it.")
                    }
                }
                if statistics.hasGear {
                    Section {
                        GearTotalsView(statistics: statistics)
                    } header: {
                        Text("Gear")
                    } footer: {
                        Text("Items with a recognized name, split by level, or by rarity for mods. L? is a level that wasn't read. Multiplied drops are the ones the game showed with a red quantity, such as on the first hack of the day. A drop is one group of item panels: a Glyph hack's, or one no Glyph hack claimed, so drops may not match the hacks you played. Rows or panels the app never saw aren't counted.")
                    }
                }
                if !statistics.lengthRows.isEmpty {
                    Section {
                        if LengthBonusChart.isShown(for: statistics) {
                            LengthBonusChart(rows: statistics.lengthAverages)
                                .padding(.vertical, 4)
                        }
                        LengthTable(rows: statistics.lengthRows)
                    } header: {
                        Text("By hack length")
                    } footer: {
                        Text("Higher-level portals give more Glyphs and less time, so compare within a row. Levels come from the gear reading where it read them. Seconds per Glyph is the time from the input screen to submitting, over the Glyphs, for hacks timed since this was added.")
                    }
                }
                if !statistics.keyCommandRows.isEmpty || !statistics.speedCommandRows.isEmpty {
                    Section {
                        if !statistics.speedCommandRows.isEmpty {
                            SpeedCommandTable(rows: statistics.speedCommandRows)
                        }
                        if !statistics.keyCommandRows.isEmpty {
                            KeyCommandTable(rows: statistics.keyCommandRows)
                        }
                    } header: {
                        Text("By command")
                    } footer: {
                        Text("Commands are read from the game's notices before each hack. None means no notice was seen; uncertain means one may have been missed. Gear per hack counts only hacks whose items were read in full with no multiplied drop, shown as measured of all. Drone hacks can't get keys, so they're kept apart.")
                    }
                }
                if !statistics.onlyDrops {
                    Section {
                        row("Hacks", "\(statistics.hacks)")
                        row("Average Hacking Bonus", percent(statistics.averageHackingBonus))
                        row("Best Hacking Bonus", percent(statistics.bestHackingBonus))
                        row("Average Speed Bonus", percent(statistics.averageSpeedBonus))
                        row("Seconds per Glyph", statistics.secondsPerGlyph.map(StatisticsFormat.seconds) ?? "—")
                        row("Glyphs accepted", share(statistics.glyphsAccepted, of: statistics.glyphsJudged))
                    } header: {
                        Text("Hacks and bonuses")
                    } footer: {
                        Text("Bonuses count only final values from the game's result screen.")
                    }
                }
                if statistics.hacks > 0 {
                    Section {
                        ActivityChart(statistics: statistics)
                            .padding(.vertical, 4)
                    } header: {
                        Text(statistics.hourly ? LocalizedStringResource("Hacks per hour") : LocalizedStringResource("Hacks per day"))
                    }
                }
                if !statistics.weakestGlyphs.isEmpty {
                    Section {
                        WeakestGlyphsChart(glyphs: statistics.weakestGlyphs)
                            .padding(.vertical, 4)
                    } header: {
                        Text("Weakest Glyphs")
                    } footer: {
                        Text("Accepted by the game, lowest first, and how many were judged. Glyphs judged fewer than \(HackStatistics.minimumAttempts) times are left out.")
                    }
                }
                if !statistics.drawTimeGlyphs.isEmpty {
                    Section {
                        DrawTimeChart(glyphs: statistics.drawTimeGlyphs)
                            .padding(.vertical, 4)
                    } header: {
                        Text("Drawing time")
                    } footer: {
                        Text("Median drawing time, slowest first; the bar runs from the fastest attempt to the slowest. Glyphs timed fewer than \(HackStatistics.minimumAttempts) times are left out.")
                    }
                }
                if !statistics.onlyDrops {
                    Section {
                        if statistics.glyphs.isEmpty {
                            Text("No Glyph verdicts read.").foregroundStyle(.secondary)
                        }
                        ForEach(statistics.glyphs) { line in
                            HStack(alignment: .firstTextBaseline) {
                                // Glyph names stay as the game has them.
                                Text(verbatim: line.glyph)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: share(line.accepted, of: line.judged)).monospacedDigit()
                                    if let seconds = line.medianDrawSeconds {
                                        Text(drawTime(seconds, timed: line.drawTimes.count))
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Glyphs")
                    } footer: {
                        Text("Accepted by the game, and the median drawing time of the attempts it judged. Drawing time is estimated from the screen, from first ink to lift. A hack's last Glyph is never timed.")
                    }
                }
                if showsAccuracy {
                    Section {
                        if !statistics.onlyDrops {
                            row("Result screens read in full", "\(statistics.resultsComplete)")
                            row("Result screens partly read", "\(statistics.resultsPartial)")
                            row("No result screen seen", "\(statistics.resultsNotSeen)")
                            row("The app's check agreed with the game", "\(statistics.checkAgreements)")
                            row("The app's check disagreed", "\(statistics.checkDisagreements)")
                        }
                        if statistics.hasGear {
                            row("Gear read in full", "\(statistics.gearComplete)")
                            row("Gear partly read", "\(statistics.gearPartial)")
                            row("Gear not read", "\(statistics.gearNotRead)")
                        }
                    } header: {
                        Text("Reading accuracy")
                    } footer: {
                        Text("How often each screen was read, and how often the app's check matched the game's verdict where both judged a Glyph.")
                    }
                }
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ title: LocalizedStringResource, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }

    /// "0.6 s median, 3 timed"
    private func drawTime(_ seconds: Double, timed: Int) -> String {
        let time = Duration.seconds(seconds).formatted(
            .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
        return String(localized: "\(time) median, \(timed) timed",
                      comment: "Statistics, one Glyph: median drawing time, then how many attempts were timed.")
    }

    /// "45 of 49 · 92%", or a dash when nothing was judged.
    private func share(_ part: Int, of whole: Int) -> String {
        guard let percent = HackStatistics.percent(part, of: whole) else { return "—" }
        let count = String(localized: "\(part) of \(whole)", comment: "Statistics: a count out of a total, such as Glyphs accepted out of those judged.")
        return "\(count) · \(percent)%"
    }
}

/// One row per hack length, and per portal level under a length several
/// levels share.
private struct LengthTable: View {
    let rows: [HackStatistics.LengthRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Glyphs").gridColumnAlignment(.leading)
                Text("Hacks")
                Text("Sec/Glyph")
                Text("Hacking")
                Text("Speed")
                Text("Accepted")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { row in
                GridRow {
                    Group {
                        if let level = row.level {
                            Text(verbatim: "L\(level)").padding(.leading, 12).foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: "\(row.glyphs)").bold()
                        }
                    }
                    .gridColumnAlignment(.leading)
                    Text(verbatim: "\(row.hacks)")
                    Text(verbatim: row.secondsPerGlyph.map(StatisticsFormat.seconds) ?? "—")
                    Text(verbatim: row.hacking.map { "\($0)%" } ?? "—")
                    Text(verbatim: row.speed.map { "\($0)%" } ?? "—")
                    Text(verbatim: row.accepted.map { "\($0)%" } ?? "—")
                }
                .font(row.level == nil ? .callout : .caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

extension HackStatistics.CommandGroup {
    var label: String {
        switch self {
        case .command(.simple): return String(localized: "Simple", comment: "Statistics: the SIMPLE HACK command.")
        case .command(.complex): return String(localized: "Complex", comment: "Statistics: the COMPLEX HACK command.")
        case .command(.requestKey): return String(localized: "Request key")
        case .command(.noKey): return String(localized: "No key")
        case .command(.keysOnly): return String(localized: "Keys only")
        case .none: return String(localized: "None", comment: "Statistics: hacks with no command notice seen.")
        case .uncertain: return String(localized: "Uncertain", comment: "Statistics: hacks whose command may have been missed.")
        case .drone: return String(localized: "Drone", comment: "Statistics: drone hacks, which can't get keys.")
        }
    }
}

/// Bonuses by presentation speed: Complex shows Glyphs faster, so compare
/// its bonuses with Simple's rather than mixing them.
private struct SpeedCommandTable: View {
    let rows: [HackStatistics.SpeedCommandRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Command").gridColumnAlignment(.leading)
                Text("Hacks")
                Text("Hacking")
                Text("Speed")
                Text("Accepted")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { row in
                GridRow {
                    Text(verbatim: row.group.label).lineLimit(1).fixedSize().gridColumnAlignment(.leading)
                    Text(verbatim: "\(row.hacks)")
                    Text(verbatim: row.hacking.map { "\($0)%" } ?? "—")
                    Text(verbatim: row.speed.map { "\($0)%" } ?? "—")
                    Text(verbatim: row.accepted.map { "\($0)%" } ?? "—")
                }
                .font(.callout).monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Keys and other items per hack by key command, with how many hacks were
/// measured.
private struct KeyCommandTable: View {
    let rows: [HackStatistics.KeyCommandRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Key request").gridColumnAlignment(.leading)
                Text("Measured")
                Text("Keys/hack")
                Text("Other/hack")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { row in
                GridRow {
                    Text(verbatim: row.group.label).lineLimit(1).fixedSize().gridColumnAlignment(.leading)
                    Text("\(row.measured) of \(row.hacks)", comment: "Statistics: a count out of a total, such as Glyphs accepted out of those judged.")
                    Text(verbatim: row.keysPerHack.map(Self.perHack) ?? "—")
                    Text(verbatim: row.otherItemsPerHack.map(Self.perHack) ?? "—")
                }
                .font(.callout).monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    static func perHack(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
}
