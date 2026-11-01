import SwiftUI
import Charts

/// Per-day averages of both bonuses and the accepted share, for 7 days and
/// All. Each line can be shown or hidden; touching the chart shows a day.
struct BonusOverTimeChart: View {
    let statistics: HackStatistics
    let period: HackStatistics.Period
    /// Smaller, without the touched day's line, for the summary card.
    var compact = false
    @AppStorage("statistics.series") private var stored = ChartSeries.defaultStorage
    @State private var selectedDay: Date?

    /// Only for days: Today would chart single hacks, which says little.
    static func isShown(for statistics: HackStatistics, period: HackStatistics.Period) -> Bool {
        DailyAveragesChart.isShown(for: statistics, period: period)
    }

    var body: some View {
        let shown = ChartSeries.parse(stored)
        VStack(alignment: .leading, spacing: 8) {
            SeriesToggles(shown: shown) { stored = ChartSeries.storage(ChartSeries.toggling($0, in: shown)) }
            if !compact {
                Text(verbatim: selectionText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DailyAveragesChart(points: statistics.bonusPoints, chartDays: statistics.chartDays, period: period,
                               shown: shown, selected: selected?.date, selection: $selectedDay)
                .frame(height: compact ? 120 : 160)
        }
    }

    private var selected: HackStatistics.BonusPoint? {
        guard let selectedDay else { return nil }
        return statistics.bonusPoints.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }
    }

    /// "Tue, Sep 23 · 4 hacks · Hacking 120% · Speed 45% · Accepted 90%"
    private var selectionText: String {
        guard let point = selected else {
            return String(localized: "Touch the chart to see a day's average bonuses.", comment: "Statistics details, bonus chart hint.")
        }
        return [point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                String(localized: "\(point.hacks) hacks", comment: "Statistics details, bonus chart: hacks on the touched day."),
                String(localized: "Hacking \(point.hacking.map { "\($0)%" } ?? "—")",
                       comment: "Statistics details, bonus chart: the touched point's Hacking Bonus."),
                String(localized: "Speed \(point.speed.map { "\($0)%" } ?? "—")",
                       comment: "Statistics details, bonus chart: the touched point's Speed Bonus."),
                String(localized: "Accepted \(point.accepted.map { "\($0)%" } ?? "—")",
                       comment: "Statistics details, bonus chart: the share of the touched point's Glyphs the game accepted.")]
            .joined(separator: " · ")
    }
}

/// A capsule per line, filled while it's shown; doubles as the legend.
private struct SeriesToggles: View {
    let shown: Set<ChartSeries>
    let toggle: (ChartSeries) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChartSeries.allCases) { series in
                let on = shown.contains(series)
                Button { toggle(series) } label: {
                    SeriesCapsule(series: series, on: on)
                        // The capsule stays compact; the tappable area is 44 × 44 points at least.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: series.label))
                .accessibilityValue(Text(on ? LocalizedStringResource("Shown") : LocalizedStringResource("Hidden")))
                .accessibilityHint(Text("Shows or hides this line."))
            }
        }
    }
}

/// Hacks per hour for one day, per day otherwise.
struct ActivityChart: View {
    let statistics: HackStatistics

    var body: some View {
        Group {
            if statistics.hourly {
                Chart(statistics.activity) { bucket in
                    BarMark(x: .value("Hour", bucket.start, unit: .hour), y: .value("Hacks", bucket.hacks))
                }
                .chartXScale(domain: hours)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
            } else {
                Chart(statistics.activity) { bucket in
                    BarMark(x: .value("Day", bucket.start, unit: .day), y: .value("Hacks", bucket.hacks))
                }
                .chartXScale(domain: statistics.chartDays.map { $0.lowerBound...$0.upperBound } ?? Date()...Date())
                .chartXAxis { dayAxis(statistics.chartPeriod) }
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .foregroundStyle(Color.accentColor.gradient)
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(statistics.hourly ? LocalizedStringResource("Hacks per hour") : LocalizedStringResource("Hacks per day")))
        .accessibilityValue(Text(verbatim: statistics.activity.map(spoken).joined(separator: ", ")))
    }

    /// "3 PM: 4 hacks" for one day, "Oct 14: 4 hacks" otherwise, one per bar for VoiceOver.
    private func spoken(_ bucket: HackStatistics.ActivityBucket) -> String {
        let when = statistics.hourly
            ? bucket.start.formatted(.dateTime.hour())
            : bucket.start.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "\(when): \(bucket.hacks) hacks",
                      comment: "Statistics chart, hacks per hour or day, one bar for VoiceOver: the hour or date, then how many hacks.")
    }

    /// The shown day's hours, or today's.
    private var hours: ClosedRange<Date> {
        if let hours = statistics.hours { return hours.lowerBound...hours.upperBound }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return start...(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }
}

/// Accepted share per Glyph, lowest first, with how many were judged.
struct WeakestGlyphsChart: View {
    let glyphs: [HackStatistics.GlyphLine]

    var body: some View {
        Chart(glyphs) { line in
            BarMark(x: .value("Accepted", line.acceptedPercent ?? 0), y: .value("Glyph", line.glyph))
                .foregroundStyle(Color.accentColor.gradient)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: "\(line.acceptedPercent ?? 0)% · \(line.judged)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityLabel(Text(verbatim: line.glyph))
                .accessibilityValue(Text("\(line.acceptedPercent ?? 0)% of \(line.judged) accepted",
                                         comment: "Statistics details, weakest Glyphs chart, one bar for VoiceOver."))
        }
        .chartXScale(domain: 0...118)
        .chartXAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let percent = value.as(Int.self) { Text(verbatim: "\(percent)%") } }
            }
        }
        .frame(height: CGFloat(glyphs.count) * 26 + 24)
    }
}

/// Median drawing time per Glyph, with a bar from fastest to slowest.
struct DrawTimeChart: View {
    let glyphs: [HackStatistics.GlyphLine]

    var body: some View {
        Chart(glyphs) { line in
            let times = line.drawTimes
            RuleMark(xStart: .value("Fastest", times.min() ?? 0), xEnd: .value("Slowest", times.max() ?? 0),
                     y: .value("Glyph", line.glyph))
                .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                .foregroundStyle(Color.accentColor.opacity(0.25))
            PointMark(x: .value("Median", line.medianDrawSeconds ?? 0), y: .value("Glyph", line.glyph))
                .foregroundStyle(Color.accentColor)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: Self.seconds(line.medianDrawSeconds ?? 0))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityLabel(Text(verbatim: line.glyph))
                .accessibilityValue(Text("median \(Self.seconds(line.medianDrawSeconds ?? 0)), \(line.drawTimes.count) timed",
                                         comment: "Statistics details, drawing time chart, one Glyph for VoiceOver."))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let seconds = value.as(Double.self) { Text(verbatim: Self.seconds(seconds)) } }
            }
        }
        .frame(height: CGFloat(glyphs.count) * 26 + 24)
    }

    static func seconds(_ value: Double) -> String {
        Duration.seconds(value).formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}
