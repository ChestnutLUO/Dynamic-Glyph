import SwiftUI
import Charts
import UIKit

/// The Statistics page's colours: system semantics, and a green and red
/// chosen for 4.5:1 on white and on #1C1C1E.
enum StatisticsColors {
    static let better = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
            : UIColor(red: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
    })
    static let worse = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
            : UIColor(red: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255, alpha: 1)
    })
}

extension View {
    /// A white (dark: #1C1C1E) card on the grouped background.
    func statisticsCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Items dropped

/// The page's big number: items dropped in the range, the drops they came
/// in, a comparison, the leading kinds and a chart over time.
struct ItemsDroppedCard: View {
    let statistics: HackStatistics
    let range: StatisticsRange
    let history: StatisticsHistory
    /// Why an empty range is empty: never "No drops" for days not kept.
    let empty: StatisticsEmptyReason
    /// The store's problem, already localized, shown in place of an empty line.
    var problem: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Items dropped")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                // The summary element below says it, with the total.
                .accessibilityHidden(statistics.dropsRead > 0)
            if statistics.dropsRead == 0 {
                Group {
                    if statistics.gearNotRead > 0 {
                        Text("No items read")
                    } else {
                        StatisticsEmptyText(reason: empty, problem: problem, stream: .drops)
                    }
                }
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                summary
                if !statistics.gear.isEmpty {
                    ItemKindsRow(statistics: statistics)
                        .padding(.top, 12)
                }
                if let domain = chartDomain {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statistics.hourly ? LocalizedStringResource("Items per hour")
                             : LocalizedStringResource("Items per day"))
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        ItemsChart(slots: slots(in: domain), hourly: statistics.hourly, domain: domain,
                                   noHistory: noHistory(in: domain))
                    }
                    .padding(.top, 12)
                }
            }
        }
        .statisticsCard()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: statistics.items.formatted())
                .font(.largeTitle.bold()).monospacedDigit()
                .contentTransition(.numericText())
                .padding(.top, 2)
            // Wraps only at a " · "; VoiceOver reads the plain value below.
            Text(verbatim: GearSummary.unbroken(subLine))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if let comparison {
                comparison.text
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Items dropped"))
        .accessibilityValue(Text(verbatim: ([statistics.items.formatted(), subLine.joined(separator: ", ")]
                                             + [comparison?.sentence].compactMap { $0 }).joined(separator: ". ")))
    }

    /// "9 drops · 6.9 per drop · 2 multiplied", without the count at 0.
    private var subLine: [String] {
        var parts = [String(localized: "\(statistics.dropsRead) drops",
                            comment: "Statistics gear: drops read in the period, a hack's item panels or a group of them no hack claimed.")]
        if let perDrop = statistics.itemsPerDrop {
            parts.append(String(localized: "\(perDrop.formatted(.number.precision(.fractionLength(1)))) per drop",
                                comment: "Statistics gear: average items per drop read, one hack's or one group of item panels no hack claimed."))
        }
        if statistics.multipliedItems > 0 {
            parts.append(String(localized: "\(statistics.multipliedItems) multiplied",
                                comment: "Statistics summary card: how many of those items came from drops the game multiplied, as on the first hack of the day."))
        }
        return parts
    }

    private var comparison: (text: Text, sentence: String)? {
        if statistics.itemComparisonUnavailable {
            let sentence = String(localized: "Comparison unavailable: earlier history is incomplete.",
                                  comment: "Statistics: the interval before the shown one isn't fully kept, so no change is shown.")
            return (Text(verbatim: sentence), sentence)
        }
        guard let change = statistics.itemChange,
              let previous = StatisticsRangeText.previous(range, history: history) else { return nil }
        let attributed = StatisticsRangeText.itemChangeAttributed(change, previous: previous)
        let sentence = String(attributed.characters)
        let color: Color? = change > 0 ? StatisticsColors.better : change < 0 ? StatisticsColors.worse : nil
        return (comparisonText(attributed, color: color), sentence)
    }

    /// What the chart spans: the range, its days' midnights for days, or
    /// All's kept days through tonight.
    private var chartDomain: Range<Date>? {
        let calendar = Calendar.current
        if statistics.hourly, let hours = statistics.hours { return hours }
        if let interval = range.interval {
            // Longer ranges are whole days, but for a timed one's first and last.
            let start = calendar.dateInterval(of: .day, for: interval.lowerBound)?.start ?? interval.lowerBound
            let end = calendar.dateInterval(of: .day, for: interval.upperBound.addingTimeInterval(-1))?.end
            return start..<max(end ?? interval.upperBound, interval.upperBound)
        }
        guard let first = history.oldestDay,
              let tonight = calendar.date(byAdding: .day, value: 1, to: history.today), first < tonight else { return nil }
        return first..<tonight
    }

    /// Every hour or day the range covers, empty ones too, but none
    /// before the drops kept.
    private func slots(in domain: Range<Date>) -> [HackStatistics.ItemSlot] {
        HackStatistics.itemSlots(buckets: statistics.itemBuckets, domain: domain, range: range.interval,
                                 unit: statistics.hourly ? .hour : .day,
                                 historyStart: noHistory(in: domain)?.upperBound)
    }

    /// Days before the oldest drop kept: not zero, just unknown.
    private func noHistory(in domain: Range<Date>) -> Range<Date>? {
        guard let start = history.drops?.oldestDay, start > domain.lowerBound else { return nil }
        return domain.lowerBound..<min(start, domain.upperBound)
    }
}

/// The leading kinds with their counts, up to five; with more kinds, the
/// top four and Other, so the row always adds up to the total.
private struct ItemKindsRow: View {
    let statistics: HackStatistics
    @Environment(\.dynamicTypeSize) private var typeSize
    /// One column for the symbols in the named list, so the names line up:
    /// the widest symbol (XMP Burster's) fits.
    @ScaledMetric(relativeTo: .callout) private var symbolWidth: CGFloat = 22

    private var shown: [StatisticsParts.GearGroup] { statistics.gearRow.shown }
    /// Items, not kinds, left out of the row.
    private var other: Int { statistics.gearRow.other }

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Side by side, the large symbols crowd out the counts: one row
            // each, named, so the symbols needn't be learned either.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                            .frame(width: symbolWidth)
                        // Game terms, printed as the English game prints them.
                        Text(verbatim: group.item).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(verbatim: group.total.formatted()).bold().monospacedDigit().layoutPriority(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(group.total) \(group.item)"))
                }
                if other > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                            .frame(width: symbolWidth)
                        Text("Other", comment: "Statistics gear row: all the item kinds not shown on their own.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(verbatim: other.formatted()).bold().monospacedDigit().layoutPriority(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(otherLabel)
                }
            }
            .font(.callout)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Spacer(minLength: 8) }
                    HStack(spacing: 4) {
                        Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                        Text(verbatim: group.total.formatted()).monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(group.total) \(group.item)"))
                }
                if other > 0 {
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        otherSlot(named: true)
                        otherSlot(named: false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(otherLabel)
                }
                if shown.count < 4 && other == 0 { Spacer(minLength: 0) }
            }
            .font(.callout)
        }
    }

    private func otherSlot(named: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            if named {
                Text("Other", comment: "Statistics gear row: all the item kinds not shown on their own.")
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: other.formatted()).monospacedDigit()
        }
        .fixedSize()
    }

    private var otherLabel: Text {
        Text(verbatim: StatisticsRangeText.otherItems(other))
    }
}

/// Items per hour or per day, with days before the drops kept hatched.
/// Each bar is its own VoiceOver element, empty ones too, saying the part of
/// its hour or day the range covers: "4:43 – 5:00 PM, 0 items".
struct ItemsChart: View {
    let slots: [HackStatistics.ItemSlot]
    let hourly: Bool
    let domain: Range<Date>
    /// Before the oldest drop kept.
    let noHistory: Range<Date>?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    /// Room for the x-axis labels, grown with the text so the bars keep
    /// their default 78-point height at every text size.
    @ScaledMetric(relativeTo: .caption2) private var axisSpace: CGFloat = 18

    private var axisFormat: Date.FormatStyle {
        hourly ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
    }

    var body: some View {
        Chart(slots) { slot in
            BarMark(x: .value(hourly ? "Hour" : "Day", slot.start, unit: hourly ? .hour : .day),
                    y: .value("Items", slot.items))
                .cornerRadius(3)
                .foregroundStyle(Color.accentColor)
                // Spoken by the overlay below: Charts groups narrow bars (a
                // day's 24 hours, 30 days) into ranges and drops these labels.
                .accessibilityHidden(true)
        }
        .chartXScale(domain: domain.lowerBound...domain.upperBound)
        .chartYAxis(.hidden)
        .chartXAxis {
            // At accessibility sizes only the first and last slots are
            // labelled, pinned inside the plot so neither is dropped or clipped.
            if typeSize.isAccessibilitySize, let first = slots.first, let last = slots.last,
               first.start != last.start {
                AxisMarks(values: [first.start]) { _ in
                    AxisValueLabel(anchor: .topLeading) { Text(first.start, format: axisFormat) }
                }
                AxisMarks(values: [slotEnd(last)]) { _ in
                    AxisValueLabel(anchor: .topTrailing) { Text(last.start, format: axisFormat) }
                }
            } else {
                AxisMarks(values: StatisticsRangeText.itemAxisDates(slots: slots)) { _ in
                    AxisValueLabel(format: axisFormat)
                }
            }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let noHistory, let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    let start = proxy.position(forX: noHistory.lowerBound) ?? 0
                    let end = proxy.position(forX: noHistory.upperBound) ?? 0
                    let width = max(0, end - start)
                    ZStack {
                        Hatching(opacity: contrast == .increased ? 0.20 : 0.10)
                        if width >= 60 {
                            Text("No drop history", comment: "Statistics chart: the hatched days before the oldest drop kept.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 2)
                        }
                    }
                    .frame(width: width, height: frame.height)
                    .clipped()
                    .position(x: frame.minX + start + width / 2, y: frame.midY)
                    // Unknown, not zero: one element saying since when.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: noHistoryLabel(noHistory)))
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ForEach(slots) { slot in
                        let start = min(max(proxy.position(forX: slot.start) ?? 0, 0), frame.width)
                        let end = min(max(proxy.position(forX: slotEnd(slot)) ?? start, start), frame.width)
                        // Labelled before .position, which fills the overlay.
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: max(end - start, 1), height: frame.height)
                            .accessibilityElement()
                            .accessibilityLabel(Text(verbatim: label(slot)))
                            .accessibilityValue(Text(verbatim: StatisticsRangeText.items(slot.items)))
                            .position(x: frame.minX + (start + end) / 2, y: frame.midY)
                    }
                }
            }
        }
        .frame(height: 78 + axisSpace)
        // Axis labels stop growing at xxxLarge; the bars keep 78 points
        // because the frame grows with axisSpace. Each bar is spoken in full.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Contain, so the title names the chart without relabelling each bar
        // and the hatched band.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityChartDescriptor(self)
    }

    /// Where the slot's bar ends: the next hour or day.
    private func slotEnd(_ slot: HackStatistics.ItemSlot) -> Date {
        Calendar.current.date(byAdding: hourly ? .hour : .day, value: 1, to: slot.start) ?? slot.span.upperBound
    }

    private var title: LocalizedStringResource {
        hourly ? LocalizedStringResource("Items per hour") : LocalizedStringResource("Items per day")
    }

    /// The date goes in where the chart crosses midnight, so two 2 PMs differ.
    private var withDate: Bool {
        guard hourly, let first = slots.first, let last = slots.last else { return false }
        return !Calendar.current.isDate(first.span.lowerBound, inSameDayAs: last.span.upperBound.addingTimeInterval(-1))
    }

    private func label(_ slot: HackStatistics.ItemSlot) -> String {
        StatisticsRangeText.slotSpan(slot, hourly: hourly, withDate: withDate)
    }

    private func noHistoryLabel(_ band: Range<Date>) -> String {
        String(localized: "No drop history before \(StatisticsRangeText.historyDate(band.upperBound)).",
               comment: "Statistics chart, for VoiceOver: the hatched days before the oldest drop kept. The placeholder is that day, with its year.")
    }
}

extension ItemsChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let names = slots.map(label)
        let most = Double(slots.map(\.items).max() ?? 0)
        let x = AXCategoricalDataAxisDescriptor(title: hourly ? String(localized: "Hour") : String(localized: "Day"), categoryOrder: names)
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Items"), range: 0...max(most, 1),
                                            gridlinePositions: []) { $0.formatted(.number.precision(.fractionLength(0))) }
        let series = AXDataSeriesDescriptor(name: String(localized: title), isContinuous: false,
                                            dataPoints: zip(names, slots).map { AXDataPoint(x: $0, y: Double($1.items)) })
        return AXChartDescriptor(title: String(localized: title), summary: noHistory.map(noHistoryLabel),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// 135° stripes, 4 points wide with 4-point gaps.
private struct Hatching: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step = 8 * 2.0.squareRoot()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += step
            }
            context.stroke(path, with: .color(Color.secondary.opacity(opacity)), lineWidth: 4)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hacks

/// Hacks in the range, with their comparison, the four averages and a chart.
struct HacksCard: View {
    let statistics: HackStatistics
    let range: StatisticsRange
    let history: StatisticsHistory
    /// Why an empty range is empty: "No hacks in this period." only where
    /// the range's hacks are kept and loaded.
    let empty: StatisticsEmptyReason
    /// The store's problem, already localized, shown in place of an empty line.
    var problem: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hacks")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(statistics.hacks > 0)
            if statistics.hacks == 0 {
                StatisticsEmptyText(reason: empty, problem: problem, stream: .hacks)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: statistics.hacks.formatted())
                        .font(.title.bold()).monospacedDigit()
                        .contentTransition(.numericText())
                    if let line = countComparison {
                        line.text
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Hacks"))
                .accessibilityValue(Text(verbatim: ([statistics.hacks.formatted()]
                                                     + [countComparison?.sentence].compactMap { $0 }).joined(separator: ". ")))
                grid.padding(.top, 12)
                // Only where bonuses had something to compare with: against
                // an empty interval there is no bonus change to explain.
                if statistics.mixesLengths && change != nil && (statistics.previousHacks ?? 0) > 0 {
                    Text(range.isShort()
                         ? LocalizedStringResource("Hack lengths are mixed, so bonus changes aren't shown. The chart compares each length.")
                         : LocalizedStringResource("Hack lengths are mixed, so bonus changes aren't shown. Details compares each length."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                chart
            }
        }
        .statisticsCard()
    }

    /// Nil where none is shown: All, no hacks before, or an interval before
    /// that isn't fully kept.
    private var change: StatisticsFigures.Change? {
        statistics.comparisonUnavailable ? nil : statistics.change
    }

    private var previous: String? { StatisticsRangeText.previous(range, history: history) }

    private var countComparison: (text: Text, sentence: String)? {
        if statistics.comparisonUnavailable {
            let sentence = String(localized: "Comparison unavailable: earlier history is incomplete.",
                                  comment: "Statistics: the interval before the shown one isn't fully kept, so no change is shown.")
            return (Text(verbatim: sentence), sentence)
        }
        guard let change, let previous else { return nil }
        let amount = abs(change.hacks).formatted()
        let attributed = StatisticsRangeText.changeAttributed(amount, sign: change.hacks.signum(), previous: previous)
        return (comparisonText(attributed, color: nil), String(attributed.characters))
    }

    private var grid: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .topLeading)]
            : [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
               GridItem(.flexible(), spacing: 16, alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            cell("Avg. Hacking", value: StatisticsFormat.percent(statistics.averageHackingBonus),
                 change: change?.hacking.map(Double.init), points: true, higherIsBetter: true)
            cell("Avg. Speed", value: StatisticsFormat.percent(statistics.averageSpeedBonus),
                 change: change?.speed.map(Double.init), points: true, higherIsBetter: true)
            cell("Accepted", value: StatisticsFormat.percent(statistics.acceptedPercent),
                 change: change?.accepted.map(Double.init), points: true, higherIsBetter: true)
            cell("Sec/Glyph", value: statistics.secondsPerGlyph.map(StatisticsFormat.seconds) ?? "—",
                 change: change?.secondsPerGlyph, points: false, higherIsBetter: false)
        }
    }

    /// Value, name, and "▲ 3 pts" or "▼ 0.2s" in the better or worse colour.
    private func cell(_ name: LocalizedStringResource, value: String, change: Double?, points: Bool,
                      higherIsBetter: Bool) -> some View {
        let shown = change.map { points ? $0.rounded() : ($0 * 10).rounded() / 10 }
        let amount = shown.map { abs($0) }.map { points
            ? String(localized: "\(Int($0).formatted()) pts",
                     comment: "Statistics change of a percentage, in percentage points, such as 3 pts.")
            : StatisticsFormat.seconds($0) }
        let sign = shown.map { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        let better = sign.map { $0 != 0 && ($0 > 0) == higherIsBetter }
        let color: Color = sign == nil || sign == 0 ? .secondary
            : better == true ? StatisticsColors.better : StatisticsColors.worse
        let sentence = zip2(amount, sign).flatMap { amount, sign in
            previous.map { StatisticsRangeText.change(amount, sign: sign, previous: $0) }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.title2.bold()).monospacedDigit()
                .foregroundStyle(value == "—" ? .secondary : .primary)
                .contentTransition(.numericText())
            Text(name).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let amount, let sign, sentence != nil {
                Text(verbatim: sign == 0 ? "±0" : "\(sign > 0 ? "▲" : "▼") \(amount)")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(verbatim: ([value] + [sentence].compactMap { $0 }).joined(separator: ", ")))
    }

    private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// Up to 48 hours, bonuses by hack length; longer, how each day went.
    @ViewBuilder
    private var chart: some View {
        if range.isShort() {
            if LengthBonusChart.isShown(for: statistics) {
                chartSection(LocalizedStringResource("Average bonus by hack length")) {
                    LengthBonusChart(rows: statistics.lengthAverages)
                }
            }
        } else if BonusOverTimeChart.isShown(for: statistics, period: statistics.chartPeriod) {
            chartSection(LocalizedStringResource("Daily averages")) {
                BonusOverTimeChart(statistics: statistics, period: statistics.chartPeriod, compact: true)
            }
        }
    }

    private func chartSection<Content: View>(_ title: LocalizedStringResource,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 14)
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A card's line for a range with none of its records, by why.
struct StatisticsEmptyText: View {
    enum Stream { case hacks, drops }
    let reason: StatisticsEmptyReason
    let problem: String?
    let stream: Stream

    var body: some View {
        switch reason {
        case .noRecords:
            stream == .hacks ? Text("No hacks in this period.", comment: "Statistics, Hacks: no hacks in the shown range.")
                : Text("No drops in this period.")
        case .beforeHistory:
            // Not "No hacks": a zero nobody knows.
            stream == .hacks
                ? Text("No hack history for this period.",
                       comment: "Statistics, Hacks card: the whole range is before the oldest hack kept on this iPhone, so its hacks are unknown, not zero.")
                : Text("No drop history for this period.",
                       comment: "Statistics, Items dropped card: the whole range is before the oldest drop kept on this iPhone, so its items are unknown, not zero.")
        case .nothingSaved:
            Text("No saved history yet.", comment: "Statistics: nothing is kept yet.")
        case .notKept:
            Text("Results are not kept, so these cover only hacks since the app opened.")
        case .unavailable:
            Text(verbatim: problem ?? "")
        }
    }
}

// MARK: - Rows

/// Summary and Options, as inset grouped rows on a card.
struct StatisticsRowsCard: View {
    let optionsStatus: String
    let showSummary: () -> Void
    let showOptions: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(symbol: "list.bullet.rectangle", tile: .accentColor, title: Text("Summary"),
                subtitle: Text("Charts and tables for this period"), action: showSummary)
            Divider().padding(.leading, 16 + 28 + 12)
            row(symbol: "gearshape.fill", tile: Color(.systemGray), title: Text("Options"),
                subtitle: Text(verbatim: optionsStatus), action: showOptions)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(symbol: String, tile: Color, title: Text, subtitle: Text,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title.foregroundStyle(.primary)
                    subtitle.font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
