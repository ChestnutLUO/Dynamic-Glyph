import SwiftUI
import Charts
import WidgetKit

/// The pieces of the Statistics summary panel: its figures, its two charts
/// and its gear row. The app's Statistics page puts them together with its
/// interactive parts (the period picker, the lines' toggles, a touched day,
/// the Summary link); the Home Screen widget with static ones.
///
/// Shared source: the app and the widget extension draw the same numbers
/// and lines from the same code.
enum StatisticsPanelStyle: Equatable {
    /// The Statistics page, at every text size.
    case app
    /// A widget's room, whose height is fixed: no accessibility-size rows,
    /// labels scaled down rather than wrapped past it, charts filling what
    /// is left.
    case large, medium

    var isWidget: Bool { self != .app }

    /// A line's colour: the app's, or a stronger one of the same hue, so a
    /// widget's marks keep 3:1 against its lighter background.
    func color(_ series: ChartSeries) -> Color {
        isWidget ? series.strongColor : series.color
    }
}

enum StatisticsFormat {
    /// "1.4 s"
    static func seconds(_ value: Double) -> String {
        Duration.seconds(value).formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }

    static func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
}

// MARK: - Figures

/// The panel's figures: Drops, Items and Per drop for gear read without
/// Glyph hacks; otherwise Hacks, the bonuses, Accepted and Sec/Glyph, with
/// the change against the previous period and its notes.
struct SummaryFigures<Statistics: StatisticsPanelFigures>: View {
    let statistics: Statistics
    let period: StatisticsPeriod
    var style: StatisticsPanelStyle = .app
    /// The ▲▼ notes under the figures.
    var showsNotes = true
    /// The ▲▼ changes; off for an empty period, whose zeros aren't compared.
    var comparesPrevious = true
    /// Every value a dash: a widget whose summary couldn't be read.
    var valuesUnknown = false
    /// A medium widget short of height: values at 18 points, not 20.
    var compactValues = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var compactValueSize: CGFloat = 18

    var body: some View {
        if statistics.onlyDrops && !valuesUnknown {
            // Gear read without Glyph hacks: drop groups, never counted as hacks.
            figures {
                figure("Drops", value: "\(statistics.drops)", change: nil, favourable: nil)
                figure("Items", value: "\(statistics.items)", change: nil, favourable: nil)
                figure("Per drop", value: statistics.itemsPerDrop.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                       change: nil, favourable: nil)
            }
        } else {
            let change = comparesPrevious && !valuesUnknown ? statistics.change : nil
            VStack(alignment: .leading, spacing: 4) {
                if widgetAccessibilityLayout {
                    // Five across don't fit at these sizes: three, then two.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            hacks(change)
                            hacking(change)
                            speed(change)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            accepted(change)
                            secondsPerGlyph(change)
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                } else {
                    figures {
                        hacks(change)
                        hacking(change)
                        speed(change)
                        accepted(change)
                        secondsPerGlyph(change)
                    }
                }
                if showsNotes && change != nil {
                    note(period == .today
                         ? LocalizedStringResource("▲▼ compared with yesterday")
                         : LocalizedStringResource("▲▼ compared with the 7 days before"))
                }
                if showsNotes && statistics.mixesLengths && change != nil {
                    note(period == .today
                         ? LocalizedStringResource("Hack lengths are mixed, so bonus changes aren't shown. The chart compares each length.")
                         : LocalizedStringResource("Hack lengths are mixed, so bonus changes aren't shown. Details compares each length."))
                }
            }
        }
    }

    private func hacks(_ change: StatisticsFigures.Change?) -> some View {
        figure("Hacks", value: "\(statistics.hacks)", change: change?.hacks, favourable: nil)
    }

    private func hacking(_ change: StatisticsFigures.Change?) -> some View {
        figure("Avg. Hacking", value: StatisticsFormat.percent(statistics.averageHackingBonus),
               change: change?.hacking, favourable: true)
    }

    private func speed(_ change: StatisticsFigures.Change?) -> some View {
        figure("Avg. Speed", value: StatisticsFormat.percent(statistics.averageSpeedBonus),
               change: change?.speed, favourable: true)
    }

    private func accepted(_ change: StatisticsFigures.Change?) -> some View {
        figure("Accepted", value: StatisticsFormat.percent(statistics.acceptedPercent),
               change: change?.accepted, favourable: true)
    }

    private func secondsPerGlyph(_ change: StatisticsFigures.Change?) -> some View {
        figure("Sec/Glyph", value: statistics.secondsPerGlyph.map(StatisticsFormat.seconds) ?? "—",
               change: change?.secondsPerGlyph, decimals: 1, favourable: false)
    }

    private var accessibilityLayout: Bool { style == .app && typeSize.isAccessibilitySize }
    private var widgetAccessibilityLayout: Bool { style.isWidget && typeSize.isAccessibilitySize }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary)
            .minimumScaleFactor(style.isWidget ? 0.9 : 1)
    }

    /// Side by side; at accessibility sizes one full-width row each, so no
    /// label is cut short.
    private var figures: AnyLayout {
        accessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: style.isWidget ? 6 : 8))
    }

    /// `favourable`: whether a rise is good; nil for counts, shown neutral.
    private func figure(_ title: LocalizedStringResource, value: String, change: Int?, favourable: Bool?) -> some View {
        figure(title, value: value, change: change.map(Double.init), decimals: 0, favourable: favourable)
    }

    private func figure(_ title: LocalizedStringResource, value: String, change: Double?, decimals: Int,
                        favourable: Bool?) -> some View {
        let value = valuesUnknown ? "—" : value
        return VStack(alignment: .leading, spacing: 2) {
            if style.isWidget {
                // Shrinks to fit a long count before it is cut.
                Text(verbatim: value).font(valueFont)
                    .foregroundStyle(value == "—" ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(title).font(.caption2).panelSecondary(style)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.9)
            } else {
                Text(verbatim: value).font(.title3.bold().monospacedDigit())
                    .foregroundStyle(value == "—" ? .secondary : .primary)
                if accessibilityLayout {
                    // A row of its own: the whole title, however many lines it takes.
                    Text(title).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Two lines' room for every title, so each change sits at the same
                    // height and no title shrinks.
                    Text(title).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            if let change {
                ChangeLabel(change: change, decimals: decimals, favourable: favourable, period: period)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueFont: Font {
        if style == .medium && compactValues {
            return .system(size: compactValueSize, weight: .semibold).monospacedDigit()
        }
        return style == .medium ? .title3.weight(.semibold).monospacedDigit() : .title2.weight(.semibold).monospacedDigit()
    }
}

/// "▲6", against the previous period; points for percentages, seconds for
/// time per Glyph.
struct ChangeLabel: View {
    let change: Double
    let decimals: Int
    let favourable: Bool?
    let period: StatisticsPeriod

    /// Rounded as shown, so "±0" never sits beside a colour.
    private var shown: Double {
        let scale = pow(10, Double(decimals))
        return (change * scale).rounded() / scale
    }

    var body: some View {
        Text(verbatim: shown == 0 ? "±0" : "\(shown > 0 ? "▲" : "▼")\(amount)")
            .font(.caption2.bold().monospacedDigit())
            .foregroundStyle(color)
            .accessibilityLabel(Text(description))
    }

    private var amount: String { abs(shown).formatted(.number.precision(.fractionLength(decimals))) }

    private var color: Color {
        guard let favourable, shown != 0 else { return .secondary }
        return (shown > 0) == favourable ? .green : .red
    }

    private var description: LocalizedStringResource {
        let amount = self.amount
        switch (period == .today, shown > 0 ? 1 : shown < 0 ? -1 : 0) {
        case (true, 1): return LocalizedStringResource("Up \(amount) from yesterday")
        case (true, -1): return LocalizedStringResource("Down \(amount) from yesterday")
        case (true, _): return LocalizedStringResource("Same as yesterday")
        case (false, 1): return LocalizedStringResource("Up \(amount) from the 7 days before")
        case (false, -1): return LocalizedStringResource("Down \(amount) from the 7 days before")
        case (false, _): return LocalizedStringResource("Same as the 7 days before")
        }
    }
}

// MARK: - Charts

extension View {
    /// The app's charts have a fixed height; a widget's take what is left
    /// of its room, up to that. A compact one asks only the least it reads at.
    @ViewBuilder
    func panelChartHeight(_ height: CGFloat, _ style: StatisticsPanelStyle, compact: Bool = false) -> some View {
        if style.isWidget {
            frame(minHeight: compact ? 72 : 80, idealHeight: compact ? 72 : nil, maxHeight: height)
        } else {
            frame(height: height)
        }
    }
}

/// The card's chart: average Hacking and Speed Bonus for each hack length,
/// side by side, since a longer hack has less time and bonuses differ.
struct LengthBonusChart: View {
    let rows: [StatisticsFigures.LengthRow]
    var style: StatisticsPanelStyle = .app
    /// A widget short of height: the chart asks only the least it reads at.
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize

    static func isShown(for statistics: some StatisticsPanelFigures) -> Bool {
        statistics.lengthAverages.contains { $0.hacking != nil || $0.speed != nil }
    }

    var body: some View {
        // At accessibility sizes the bars' labels overlap in the fixed height,
        // so the figures become text rows instead. A widget has no room for
        // them, and the chart.
        if style == .app && typeSize.isAccessibilitySize {
            textRows
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(rows) { row in
                let length = Self.length(row)
                if let hacking = row.hacking {
                    BarMark(x: .value("Hack length", length), y: .value("Bonus", hacking))
                        .foregroundStyle(by: .value("Bonus", String(localized: "Hacking")))
                        .position(by: .value("Bonus", String(localized: "Hacking")))
                        .annotation(position: .top) { value(hacking) }
                }
                if let speed = row.speed {
                    BarMark(x: .value("Hack length", length), y: .value("Bonus", speed))
                        .foregroundStyle(by: .value("Bonus", String(localized: "Speed")))
                        .position(by: .value("Bonus", String(localized: "Speed")))
                        .annotation(position: .top) { value(speed) }
                }
            }
        }
        .chartForegroundStyleScale([String(localized: "Hacking"): style.color(.hacking),
                                    String(localized: "Speed"): style.color(.speed)])
        .chartLegend(position: .bottom, alignment: .leading)
        .percentYAxis(style, upTo: rows.flatMap { [$0.hacking, $0.speed] }.compactMap { $0 }.max() ?? 0,
                      bars: true)
        .panelChartHeight(130, style, compact: compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Average bonus by hack length"))
        .accessibilityValue(Text(verbatim: rows.map(Self.spoken).joined(separator: ", ")))
    }

    /// One row per length: its name, then each bonus under a dot in the
    /// chart's colour, wrapping as far as it needs.
    private var textRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.length(row)).font(.headline)
                    bonus("Hacking Bonus", row.hacking, color: .accentColor)
                    bonus("Speed Bonus", row.speed, color: .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func bonus(_ title: LocalizedStringResource, _ percent: Int?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: Self.spokenPercent(percent)).font(.body.bold()).monospacedDigit()
                    .foregroundStyle(percent == nil ? .secondary : .primary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "8 Glyphs", shared by the chart's axis and the text rows.
    private static func length(_ row: StatisticsFigures.LengthRow) -> String {
        String(localized: "\(row.glyphs) Glyphs",
               comment: "Statistics card chart: a hack length on the x axis.")
    }

    /// "8 Glyphs: Hacking Bonus 92%, Speed Bonus 45%", one per length for VoiceOver.
    private static func spoken(_ row: StatisticsFigures.LengthRow) -> String {
        String(localized: "\(row.glyphs) Glyphs: Hacking Bonus \(spokenPercent(row.hacking)), Speed Bonus \(spokenPercent(row.speed))",
               comment: "Statistics chart, bonus by hack length, one length for VoiceOver. The bonuses are a percentage such as 92%, or “no data”.")
    }

    private static func spokenPercent(_ percent: Int?) -> String {
        percent.map { "\($0)%" }
            ?? String(localized: "no data", comment: "Statistics chart, for VoiceOver: a length had no bonus read. Read inside a sentence, so lowercase.")
    }

    private func value(_ percent: Int) -> some View {
        Text(verbatim: "\(percent)%").font(.caption2).panelSecondary(style).monospacedDigit()
    }
}

/// The lines a per-day chart can show; the player picks which.
enum ChartSeries: String, CaseIterable, Identifiable {
    case hacking, speed, accepted
    var id: Self { self }

    /// What `AppStorage` keeps: the shown lines, comma-separated.
    static let defaultStorage = "hacking,speed"

    /// Unknown names are skipped; nothing readable falls back to the default,
    /// so the chart is never left empty.
    static func parse(_ stored: String) -> Set<ChartSeries> {
        let shown = Set(stored.split(separator: ",").compactMap { ChartSeries(rawValue: String($0)) })
        return shown.isEmpty ? parse(defaultStorage) : shown
    }

    static func storage(_ shown: Set<ChartSeries>) -> String {
        allCases.filter(shown.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Turns one line on or off, but never the last one off.
    static func toggling(_ series: ChartSeries, in shown: Set<ChartSeries>) -> Set<ChartSeries> {
        if shown.contains(series) { return shown.count > 1 ? shown.subtracting([series]) : shown }
        return shown.union([series])
    }

    var label: String {
        switch self {
        case .hacking: return String(localized: "Hacking")
        case .speed: return String(localized: "Speed")
        case .accepted: return String(localized: "Accepted")
        }
    }

    var color: Color {
        switch self {
        case .hacking: return .accentColor
        case .speed: return .orange
        case .accepted: return .green
        }
    }

    /// The same hues, darker in light mode and lighter in dark, for a
    /// widget's background.
    var strongColor: Color {
        func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
            func color(_ hex: UInt32) -> UIColor {
                UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
        }
        switch self {
        case .hacking: return dynamic(0x0066CC, 0x64A8FF)
        case .speed: return dynamic(0xB45F00, 0xFFB15C)
        case .accepted: return dynamic(0x27823A, 0x76D68A)
        }
    }

    /// The line's dashes: Accepted dashed, as it isn't a bonus. Where colour
    /// is lost, as on a tinted Home Screen, each line has its own.
    func dash(patterned: Bool) -> [CGFloat] {
        switch self {
        case .hacking: return []
        case .speed: return patterned ? [2, 2] : []
        case .accepted: return patterned ? [6, 3] : [4, 3]
        }
    }

    /// Points are circles; where colour is lost, each line has its own shape.
    func symbol(patterned: Bool) -> BasicChartSymbolShape {
        guard patterned else { return .circle }
        switch self {
        case .hacking: return .circle
        case .speed: return .square
        case .accepted: return .triangle
        }
    }

    /// The point's shape in a legend, where colour is lost.
    var symbolName: String {
        switch self {
        case .hacking: return "circle.fill"
        case .speed: return "square.fill"
        case .accepted: return "triangle.fill"
        }
    }
}

/// One line's capsule: filled while the line is shown. The app's is a
/// toggle; the widget's, all filled, a fixed legend.
struct SeriesCapsule: View {
    let series: ChartSeries
    let on: Bool
    var style: StatisticsPanelStyle = .app
    /// The line's own point shape, where colour is lost.
    var patterned = false

    var body: some View {
        let color = style.color(series)
        HStack(spacing: 4) {
            if patterned {
                Image(systemName: series.symbolName).font(.system(size: 7)).foregroundStyle(color)
            } else {
                Circle().fill(on ? color : Color.clear)
                    .overlay(Circle().stroke(color, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
            }
            Text(verbatim: series.label)
        }
        .font(style.isWidget ? .caption2 : .caption)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(on ? color.opacity(0.15) : Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// The widget's legend: every line, none tappable.
struct SeriesLegend: View {
    var style: StatisticsPanelStyle = .large
    var patterned = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChartSeries.allCases) { series in
                SeriesCapsule(series: series, on: true, style: style, patterned: patterned)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The lines of per-day averages of both bonuses and the accepted share, for
/// 7 days and All. The app adds the toggles and a touched day around it.
struct DailyAveragesChart: View {
    let points: [StatisticsFigures.BonusPoint]
    let chartDays: Range<Date>?
    let period: StatisticsPeriod
    let shown: Set<ChartSeries>
    /// The touched day, ruled; nil in a widget, which can't be touched.
    var selected: Date?
    var selection: Binding<Date?>?
    var style: StatisticsPanelStyle = .app
    /// Each line its own dashes and point shape, where colour is lost.
    var patterned = false

    /// Only for days: Today would chart single hacks, which says little.
    static func isShown(for statistics: some StatisticsPanelFigures, period: StatisticsPeriod) -> Bool {
        period != .today
            && statistics.bonusPoints.filter { $0.hacking != nil || $0.speed != nil || $0.accepted != nil }.count >= 2
    }

    var body: some View {
        let chart = Chart {
            ForEach(points) { point in
                marks(point: point)
            }
            if let selected {
                RuleMark(x: .value("Day", selected, unit: .day)).foregroundStyle(.tertiary)
            }
        }
        .chartXScale(domain: chartDays.map { $0.lowerBound...$0.upperBound } ?? Date()...Date())
        .chartXAxis { dayAxis(period) }
        .percentYAxis(style, upTo: points.flatMap { point in
            ChartSeries.allCases.filter(shown.contains).compactMap { value($0, of: point) }
        }.max() ?? 0)
        .chartForegroundStyleScale(domain: ChartSeries.allCases.map(\.label),
                                   range: ChartSeries.allCases.map(style.color))
        .chartLegend(.hidden)
        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }

    @ChartContentBuilder
    private func marks(point: StatisticsFigures.BonusPoint) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Day", point.date, unit: .day)
        ForEach(ChartSeries.allCases.filter(shown.contains)) { series in
            if let value = value(series, of: point) {
                LineMark(x: x, y: .value("Bonus", value), series: .value("Line", series.label))
                    .foregroundStyle(by: .value("Line", series.label))
                    // Accuracy shares the percent axis; dashed, as it isn't a bonus.
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: series.dash(patterned: patterned)))
                PointMark(x: x, y: .value("Bonus", value))
                    .foregroundStyle(by: .value("Line", series.label))
                    .symbol(series.symbol(patterned: patterned))
                    .symbolSize(20)
            }
        }
    }

    private func value(_ series: ChartSeries, of point: StatisticsFigures.BonusPoint) -> Int? {
        switch series {
        case .hacking: return point.hacking
        case .speed: return point.speed
        case .accepted: return point.accepted
        }
    }
}

@AxisContentBuilder
func percentAxis() -> some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel { if let percent = value.as(Int.self) { Text(verbatim: "\(percent)%") } }
    }
}

extension View {
    /// The charts' percent axis. The app's, as ever; a widget's draws its own
    /// labels (below), so they show in dark too.
    @ViewBuilder
    func percentYAxis(_ style: StatisticsPanelStyle, upTo highest: Int, bars: Bool = false) -> some View {
        if style.isWidget {
            modifier(WidgetPercentAxis(ticks: WidgetPercentAxis.ticks(upTo: highest, bars: bars), style: style))
        } else {
            chartYAxis { percentAxis() }
        }
    }
}

/// A widget's percent axis. On a dark Home Screen Charts leaves out a
/// widget's y-axis labels, so the widget sets its own scale and ticks, has
/// Charts lay out unseen labels for them, which keeps the gutter left of
/// the plot as wide as the widest, and draws each label there itself,
/// centred on its gridline.
struct WidgetPercentAxis: ViewModifier {
    let ticks: [Int]
    let style: StatisticsPanelStyle

    /// 0, 50 and 100% up to 100%, then hundreds. Bars keep a step above a
    /// tall bar for its value, as the app's axis does.
    static func ticks(upTo highest: Int, bars: Bool) -> [Int] {
        let needed = bars && highest > 80 ? highest + 50 : highest
        let step = needed <= 100 ? 50 : 100
        let top = max(100, (needed + step - 1) / step * step)
        return Array(stride(from: 0, through: top, by: step))
    }

    func body(content: Content) -> some View {
        content
            .chartYScale(domain: 0...(ticks.last ?? 100))
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine()
                    // Unseen, but laid out: Charts measures the gutter from
                    // these and keeps the plot clear of it.
                    AxisValueLabel(horizontalSpacing: Self.spacing) {
                        if let percent = value.as(Int.self) { label(percent).hidden() }
                    }
                }
            }
            .chartOverlay(alignment: .topLeading) { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let plot = geometry[plotFrame]
                        ForEach(ticks, id: \.self) { tick in
                            if let y = proxy.position(forY: tick) {
                                // Where Charts keeps its label: trailing edge
                                // `spacing` left of the plot, centred on the gridline.
                                label(tick).panelSecondary(style)
                                    .fixedSize()
                                    .frame(width: 0, height: 0, alignment: .trailing)
                                    .position(x: plot.minX - Self.spacing, y: plot.minY + y)
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
            }
    }

    private static let spacing: CGFloat = 4

    private func label(_ percent: Int) -> some View {
        Text(verbatim: "\(percent)%").font(.caption2).monospacedDigit()
    }
}

extension View {
    /// Secondary text. The system's secondary grey falls under 4.5:1 on a
    /// widget's background, so full-colour widgets use a fixed grey for
    /// each appearance; the app and tinted Home Screens keep the system's.
    func panelSecondary(_ style: StatisticsPanelStyle) -> some View {
        modifier(PanelSecondary(style: style))
    }
}

struct PanelSecondary: ViewModifier {
    let style: StatisticsPanelStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// #B9B9BE: 4.5:1 and more on the lightest dark widget background measured.
    static let widgetDark = Color(red: 0xB9 / 255, green: 0xB9 / 255, blue: 0xBE / 255)
    /// #636366: 4.5:1 and more on the light widget background.
    static let widgetLight = Color(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255)

    func body(content: Content) -> some View {
        if style.isWidget && renderingMode == .fullColor {
            content.foregroundStyle(colorScheme == .dark ? Self.widgetDark : Self.widgetLight)
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

/// Weekday letters for 7 days; a few dates for All.
@AxisContentBuilder
func dayAxis(_ period: StatisticsPeriod) -> some AxisContent {
    AxisMarks(values: period == .week ? .stride(by: .day) : .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
        AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day())
    }
}

// MARK: - Gear

enum GearSummary {
    /// "164 items · 3.9 per drop · 26 multiplied"
    /// A widget short of room leaves out the multiplied items, then the
    /// items per drop; never the items.
    static func line(_ statistics: some StatisticsPanelFigures, perDrop includesPerDrop: Bool = true,
                     multiplied includesMultiplied: Bool = true) -> String {
        parts(statistics, perDrop: includesPerDrop, multiplied: includesMultiplied).joined(separator: " · ")
    }

    /// `line` for the screen: it wraps only after a " · ", never inside a
    /// segment such as "26 multiplied" or "加倍 26". Keep `line` for exports and
    /// VoiceOver.
    static func displayLine(_ statistics: some StatisticsPanelFigures, perDrop includesPerDrop: Bool = true,
                            multiplied includesMultiplied: Bool = true) -> String {
        unbroken(parts(statistics, perDrop: includesPerDrop, multiplied: includesMultiplied))
    }

    /// Segments joined so that a line breaks only after a separator's dot,
    /// which stays at the end of the line before. Inside a segment a word
    /// joiner (U+2060) sits between characters, as Chinese and Japanese
    /// otherwise break anywhere, and a no-break space replaces each space,
    /// between a number and its word. A segment wider than the line still
    /// wraps. Display only: the joiners are invisible but not plain text.
    static func unbroken(_ segments: [String]) -> String {
        segments.map { segment in
            segment.replacingOccurrences(of: " ", with: "\u{00A0}")
                .map(String.init).joined(separator: "\u{2060}")
        }.joined(separator: "\u{00A0}· ")
    }

    private static func parts(_ statistics: some StatisticsPanelFigures, perDrop includesPerDrop: Bool,
                              multiplied includesMultiplied: Bool) -> [String] {
        var parts = [String(localized: "\(statistics.items) items",
                            comment: "Statistics gear: items recognized in the period.")]
        if includesPerDrop, let perDrop = statistics.itemsPerDrop {
            parts.append(String(localized: "\(perDrop.formatted(.number.precision(.fractionLength(1)))) per drop",
                                comment: "Statistics gear: average items per drop read, one hack's or one group of item panels no hack claimed."))
        }
        if includesMultiplied && statistics.multipliedItems > 0 {
            parts.append(String(localized: "\(statistics.multipliedItems) multiplied",
                                comment: "Statistics summary card: how many of those items came from drops the game multiplied, as on the first hack of the day."))
        }
        return parts
    }

    /// Stand-ins from SF Symbols, not the game's artwork.
    static func symbol(for item: String) -> String {
        switch item {
        case "Resonator": return "antenna.radiowaves.left.and.right"
        case "XMP Burster": return "burst.fill"
        case "Ultra Strike": return "bolt.fill"
        case "Power Cube": return "cube.fill"
        case "Hypercube": return "cube.transparent"
        case "Portal Shield", "Aegis Shield": return "shield.fill"
        case "Turret": return "scope"
        case "Force Amp": return "arrow.up.forward.circle.fill"
        case "Link Amp", "SoftBank Ultra Link": return "link"
        case "Heat Sink": return "thermometer.snowflake"
        case "Multi-Hack": return "square.stack.3d.up.fill"
        case "Portal Key": return "key.fill"
        case "ADA Refactor", "JARVIS Virus": return "wand.and.stars"
        case "Capsule", "Kinetic Capsule": return "capsule.fill"
        case "Media": return "photo"
        default: return "shippingbox.fill"
        }
    }
}

/// The card's gear line: the most common items with their counts.
struct GearStrip<Statistics: StatisticsPanelFigures>: View {
    let statistics: Statistics
    var style: StatisticsPanelStyle = .app
    /// The icons; a widget short of room keeps only the line.
    var showsIcons = true
    /// Between the icons and the line: a medium widget short of room closes it.
    var lineGap: CGFloat = 4
    /// A widget's: puts what leads the items line, the app's icon, before
    /// the line it is given, which takes the width left. The app's line has
    /// nothing before it.
    var leadingLine: ((AnyView) -> AnyView)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: style == .app ? 4 : lineGap) {
            if style == .app && typeSize.isAccessibilitySize {
                // Side by side, the large symbols crowd out the counts: one row
                // each, named, so the symbols needn't be learned either.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(statistics.gear.prefix(5)) { group in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                            // Game terms, printed as the English game prints them.
                            Text(verbatim: group.item)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(verbatim: "\(group.total)").bold().monospacedDigit()
                                .layoutPriority(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "\(group.total) \(group.item)"))
                    }
                }
                .font(.callout)
            } else if style == .app {
                HStack(spacing: 12) {
                    ForEach(statistics.gear.prefix(5)) { group in
                        Label {
                            Text(verbatim: "\(group.total)").monospacedDigit()
                        } icon: {
                            Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                        }
                        .labelStyle(.titleAndIcon)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "\(group.total) \(group.item)"))
                    }
                }
                .font(.callout)
            } else if showsIcons && !statistics.gear.isEmpty {
                // As many of the leading five as fit whole, spread across.
                ViewThatFits(in: .horizontal) {
                    spread(5)
                    spread(4)
                    spread(3)
                    spread(2)
                }
            }
            summaryLine
        }
    }

    @ViewBuilder
    private var summaryLine: some View {
        if style == .medium {
            // Measure the complete row, including its leading icon and gap,
            // before selecting; a surrounding HStack can compress a nested
            // ViewThatFits after it has chosen the full text.
            ViewThatFits(in: .horizontal) {
                markedLine(perDrop: true, multiplied: true)
                    .fixedSize(horizontal: true, vertical: false)
                markedLine(perDrop: true, multiplied: false)
                    .fixedSize(horizontal: true, vertical: false)
                markedLine(perDrop: false, multiplied: false)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            markedLine(perDrop: true, multiplied: true)
        }
    }

    @ViewBuilder
    private func markedLine(perDrop: Bool, multiplied: Bool) -> some View {
        if let leadingLine {
            leadingLine(AnyView(line(perDrop: perDrop, multiplied: multiplied)))
        } else {
            line(perDrop: perDrop, multiplied: multiplied)
        }
    }

    private func line(perDrop: Bool, multiplied: Bool) -> some View {
        Text(verbatim: GearSummary.displayLine(statistics, perDrop: perDrop, multiplied: multiplied))
            .font(style.isWidget ? .caption2 : .caption).panelSecondary(style)
            .lineLimit(style == .medium ? 1 : style == .large ? 2 : nil)
            .accessibilityLabel(Text(verbatim: GearSummary.line(statistics, perDrop: perDrop, multiplied: multiplied)))
    }

    private func spread(_ count: Int) -> some View {
        let groups = Array(statistics.gear.prefix(count))
        return HStack(spacing: 0) {
            ForEach(groups) { group in
                Label {
                    Text(verbatim: "\(group.total)").monospacedDigit()
                        .font(style == .medium ? .caption : .footnote)
                } icon: {
                    Image(systemName: GearSummary.symbol(for: group.item)).foregroundStyle(.tint)
                        .font(style == .medium ? .footnote : .subheadline)
                }
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(group.total) \(group.item)"))
                if group.id != groups.last?.id { Spacer(minLength: 6) }
            }
            // A short row stays leading, as the app's.
            if groups.count < 4 { Spacer(minLength: 0) }
        }
    }
}
