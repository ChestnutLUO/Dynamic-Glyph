import AppIntents
import SwiftUI
import WidgetKit

/// The Home Screen Summary widget: the Statistics page's summary panel for
/// Today, the last 7 days or All, chosen on the widget itself. Large has the
/// whole panel but its Summary link, medium all but the chart, small the
/// hacks and items. A tap outside the period buttons opens Statistics on the
/// widget's period.
struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StatisticsWidgetSummary.kind, provider: SummaryWidgetProvider()) { entry in
            SummaryWidgetView(entry: entry)
                // The Statistics card's own background.
                .containerBackground(Color(uiColor: .secondarySystemBackground), for: .widget)
                .widgetURL(AppLink.statistics(entry.period).url)
        }
        .configurationDisplayName(LocalizedStringResource("Summary",
                                                          comment: "Summary widget's name in the widget gallery."))
        .description(LocalizedStringResource("Hacks, drops and items for your chosen period.",
                                             comment: "Summary widget's description in the widget gallery."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SummaryWidgetView: View {
    let entry: SummaryWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallSummary(entry: entry)
            case .systemMedium: MediumSummary(entry: entry)
            default: LargeSummary(entry: entry)
            }
        }
        // Past these, even the fallbacks below can't keep five figures readable.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: - Large

/// The whole panel: periods, figures, the chart Statistics would show, gear.
private struct LargeSummary: View {
    let entry: SummaryWidgetEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Where the changes against the previous period stood, about a
    /// caption2 line: left open above the chart.
    @ScaledMetric(relativeTo: .caption2) private var breathingRoom: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeriodSelector(selected: entry.period)
            // The most the room takes: the chart gives up height, then the
            // chart, then gear icons go; the summary and app mark stay.
            ViewThatFits(in: .vertical) {
                content(chart: true)
                // The smallest iPhones' large widget, as the 13 mini's, has
                // no room for the chart's usual height on 7 days and All.
                content(chart: true, compactChart: true)
                content(chart: false)
                content(chart: false, icons: false)
            }
            .padding(.top, 6)
        }
        // Top-aligned by its frame; a Spacer beside the ViewThatFits would
        // take a share of the height it is offered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(chart: Bool, compactChart: Bool = false, icons: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let figures = entry.figures {
                if figures.onlyDrops {
                    SummaryFigures(statistics: figures, period: entry.period, style: .large)
                    GearRow(figures: figures, style: .large, icons: icons)
                } else if figures.hacks == 0 {
                    SummaryFigures(statistics: figures, period: entry.period, style: .large, comparesPrevious: false)
                    MarkedRow(.caption1) { SummaryLine.empty(entry.period) }
                } else {
                    // The five figures without their changes: the widget
                    // has the room for them, not for what they compare.
                    SummaryFigures(statistics: figures, period: entry.period, style: .large, showsNotes: false,
                                   comparesPrevious: false)
                    // At accessibility sizes the figures take the chart's room.
                    if chart && !typeSize.isAccessibilitySize {
                        PanelChart(figures: figures, period: entry.period, patterned: renderingMode != .fullColor,
                                   compact: compactChart)
                            .padding(.top, breathingRoom)
                    }
                    GearRow(figures: figures, style: .large, icons: icons)
                }
            } else {
                SummaryFigures(statistics: StatisticsWidgetSummary.empty.figures(entry.period, at: entry.date),
                               period: entry.period, style: .large, valuesUnknown: true)
                MarkedRow(.caption1) { SummaryLine.unavailable }
            }
        }
    }
}

/// The chart Statistics shows for the figures, by the same test: days for 7
/// days and All when there are enough, else bonuses by length, else none.
private struct PanelChart: View {
    let figures: StatisticsFigures
    let period: StatisticsPeriod
    let patterned: Bool
    /// Asks only the least height the chart reads at: it still takes what
    /// is left of the room, up to its usual height.
    var compact = false

    var body: some View {
        if DailyAveragesChart.isShown(for: figures, period: period) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Daily averages").font(.caption.bold()).panelSecondary(.large)
                    .lineLimit(1).minimumScaleFactor(0.8)
                SeriesLegend(style: .large, patterned: patterned).padding(.top, 6)
                DailyAveragesChart(points: figures.bonusPoints, chartDays: figures.chartDays, period: period,
                                   shown: Set(ChartSeries.allCases), style: .large, patterned: patterned)
                    .frame(minHeight: compact ? 56 : 80, idealHeight: compact ? 56 : nil, maxHeight: 116)
                    // 4 points to the chips, plus the half of the top axis
                    // label that stands above its gridline.
                    .padding(.top, 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Daily averages"))
            .accessibilityValue(Text(verbatim: spokenDays))
        } else if LengthBonusChart.isShown(for: figures) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Average bonus by hack length").font(.caption.bold()).panelSecondary(.large)
                    .lineLimit(1).minimumScaleFactor(0.8)
                LengthBonusChart(rows: figures.lengthAverages, style: .large, compact: compact)
                    // Half the top label stands above its gridline.
                    .padding(.top, 6)
            }
        }
    }

    /// "Oct 14: Hacking 120% · Speed 45% · Accepted 90%", one per day with
    /// hacks; a value not read is left out.
    private var spokenDays: String {
        figures.bonusPoints.map { point in
            var values: [String] = []
            if let hacking = point.hacking {
                values.append(String(localized: "Hacking \("\(hacking)%")",
                                     comment: "Statistics details, bonus chart: the touched point's Hacking Bonus."))
            }
            if let speed = point.speed {
                values.append(String(localized: "Speed \("\(speed)%")",
                                     comment: "Statistics details, bonus chart: the touched point's Speed Bonus."))
            }
            if let accepted = point.accepted {
                values.append(String(localized: "Accepted \("\(accepted)%")",
                                     comment: "Statistics details, bonus chart: the share of the touched point's Glyphs the game accepted."))
            }
            return "\(point.date.formatted(.dateTime.month(.abbreviated).day())): \(values.joined(separator: " · "))"
        }
        .joined(separator: ", ")
    }
}

// MARK: - Medium

/// The panel without its chart: periods, figures and gear.
private struct MediumSummary: View {
    let entry: SummaryWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Its tap row's empty top reaches into the margin, which holds
            // nothing: the track keeps its 6 points to the figures below.
            PeriodSelector(selected: entry.period)
                .padding(.top, -6)
            // No changes against the previous period here. Short of height
            // the gaps close first, then values go to 18 points, then the
            // icons go; the items line drops its own parts for width.
            ViewThatFits(in: .vertical) {
                content(gap: 6)
                content(gap: 4)
                content(gap: 4, compact: true)
                content(gap: 4, compact: true, lineGap: 2)
                content(gap: 6, icons: false)
            }
        }
        // Top-aligned by its frame; a Spacer beside the ViewThatFits would
        // take a share of the height it is offered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(gap: CGFloat, compact: Bool = false, lineGap: CGFloat = 4,
                         icons: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            if let figures = entry.figures {
                if figures.hacks == 0 && figures.drops == 0 {
                    SummaryFigures(statistics: figures, period: entry.period, style: .medium, showsNotes: false,
                                   comparesPrevious: false)
                    MarkedRow(.caption1) { SummaryLine.empty(entry.period) }
                } else {
                    SummaryFigures(statistics: figures, period: entry.period, style: .medium, showsNotes: false,
                                   comparesPrevious: false, compactValues: compact)
                    GearRow(figures: figures, style: .medium, icons: icons, lineGap: lineGap)
                }
            } else {
                SummaryFigures(statistics: StatisticsWidgetSummary.empty.figures(entry.period, at: entry.date),
                               period: entry.period, style: .medium, valuesUnknown: true)
                MarkedRow(.caption1) { SummaryLine.unavailable }
            }
        }
    }
}

// MARK: - Small

/// The period, cycled by its one button, its hacks and items, and the
/// app's icon leading the bottom row.
private struct SmallSummary: View {
    let entry: SummaryWidgetEntry
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CyclingPeriodButton(period: entry.period)
            ViewThatFits(in: .vertical) {
                content(figures: true)
                content(figures: true, rowGap: 4)
                // A long unavailable line in a large text size keeps the room.
                content(figures: false)
            }
            .padding(.top, 12)
        }
        // Top-aligned by its frame; a Spacer beside the ViewThatFits would
        // take a share of the height it is offered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The figures, then the bottom row pinned to the bottom margin by the
    /// Spacer between them, at least `rowGap` below the figures.
    @ViewBuilder
    private func content(figures shown: Bool, rowGap: CGFloat = 8) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if shown { tiles }
            Spacer(minLength: shown ? rowGap : 0)
            bottomRow
        }
    }

    @ViewBuilder
    private var tiles: some View {
        if let figures = entry.figures {
            HStack(alignment: .top, spacing: 8) {
                if figures.onlyDrops {
                    // Drop groups, never relabelled hacks.
                    tile("Drops", value: "\(figures.drops)",
                         spoken: Text("\(figures.drops) drops",
                                      comment: "Summary widget: drop groups no Glyph hack claimed, in the period."))
                } else {
                    tile("Hacks", value: "\(figures.hacks)",
                         spoken: Text("\(figures.hacks) hacks", comment: "Summary widget: Glyph hacks in the period."))
                }
                // Unknown gear is a dash, not a zero; an empty period has none.
                // With no gear kept at all, as with reading off, there's no tile.
                let isEmpty = figures.hacks == 0 && figures.drops == 0
                let itemsKnown = figures.hasGearReading || isEmpty
                if figures.hasGear || isEmpty {
                    tile("Items", value: itemsKnown ? "\(figures.items)" : "—",
                         spoken: itemsKnown
                            ? Text("\(figures.items) items", comment: "Statistics gear: items recognized in the period.")
                            : nil,
                         detail: figures.hasGearReading && figures.parts.bonusItems > 0
                            ? Text("Includes \(figures.parts.bonusItems) bonus items",
                                   comment: "Summary widget, under the items: how many of them were on the Bonus items panel.")
                            : nil)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                tile("Hacks", value: "—", spoken: nil)
                tile("Items", value: "—", spoken: nil)
            }
        }
    }

    /// The icon leading the line the period calls for: why there are no
    /// figures, the multiplied items, or nothing, the icon then alone on a
    /// row of its own height.
    @ViewBuilder
    private var bottomRow: some View {
        if let figures = entry.figures {
            if figures.hacks == 0 && figures.drops == 0 {
                MarkedRow(.caption1) { SummaryLine.empty(entry.period) }
            } else if figures.hasGear && !figures.hasGearReading {
                MarkedRow(.caption2) { SummaryLine.noItemsRead }
            } else if figures.multipliedItems > 0 {
                MarkedRow(.caption2) {
                    // Items the game showed in red, as Statistics counts them: not extra items.
                    Text("\(figures.multipliedItems) multiplied",
                         comment: "Statistics summary card: how many of those items came from drops the game multiplied, as on the first hack of the day.")
                        .font(.caption2).panelSecondary(.medium)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                AppMark()
            }
        } else {
            MarkedRow(.caption1) { SummaryLine.unavailable }
        }
    }

    /// `spoken`: the count with its unit, for VoiceOver; nil reads the tile.
    private func tile(_ title: LocalizedStringResource, value: String, spoken: Text?, detail: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value)
                .font(.system(size: valueSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == "—" ? .secondary : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).panelSecondary(.medium)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: spoken == nil ? .combine : .ignore)
        .modifier(SpokenCount(label: spoken, value: detail))
    }
}

private struct SpokenCount: ViewModifier {
    let label: Text?
    let value: Text?

    func body(content: Content) -> some View {
        if let label {
            if let value {
                content.accessibilityLabel(label).accessibilityValue(value)
            } else {
                content.accessibilityLabel(label)
            }
        } else {
            content
        }
    }
}

// MARK: - Shared parts

/// The gear row with its items line where gear was read; otherwise that
/// none was, since unknown items are not zero. The app's icon leads the
/// line, the widget's bottom row.
private struct GearRow: View {
    let figures: StatisticsFigures
    let style: StatisticsPanelStyle
    var icons = true
    var lineGap: CGFloat = 4

    var body: some View {
        if figures.hasGearReading {
            GearStrip(statistics: figures, style: style, showsIcons: icons, lineGap: lineGap,
                      leadingLine: { line in AnyView(MarkedRow(.caption2) { line }) })
        } else if figures.hasGear {
            MarkedRow(.caption2) { SummaryLine.noItemsRead }
        } else {
            // No gear kept at all, as with reading off: no gear row, as in
            // the app, and the icon alone in the bottom row.
            AppMark()
        }
    }
}

/// The widget's bottom row: the app's icon, then `content` in the width
/// left, 6 points on. The icon's centre stays on the centre of the text's
/// first line however many lines it wraps to, and the row is as high as
/// the text: the icon stands out of a shorter line rather than grow it.
private struct MarkedRow<Content: View>: View {
    /// The text style of `content`, whose first line the icon centres on.
    let textStyle: UIFont.TextStyle
    let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ textStyle: UIFont.TextStyle, @ViewBuilder content: () -> Content) {
        self.textStyle = textStyle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            AppMark()
                .offset(y: (firstLineHeight - AppMark.side) / 2)
                .frame(height: firstLineHeight, alignment: .top)
            content
        }
    }

    /// One line of the style at the widget's text size, as the widget caps it.
    private var firstLineHeight: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).lineHeight
    }
}

/// The widget's own lines, from its copy.
private enum SummaryLine {
    static var noItemsRead: some View {
        Text("No items read", comment: "Summary widget: hacks in the period, but none had its item panels read.")
            .font(.caption2).panelSecondary(.medium)
            .lineLimit(2).minimumScaleFactor(0.8)
    }

    static var unavailable: some View {
        Text("Summary unavailable. Open Dynamic Glyph.",
             comment: "Summary widget: the summary the app saves for it couldn't be read. Tapping the widget opens the app.")
            .font(.caption).panelSecondary(.medium)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func empty(_ period: StatisticsPeriod) -> some View {
        Text(emptyText(period)).font(.caption).panelSecondary(.medium)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func emptyText(_ period: StatisticsPeriod) -> LocalizedStringResource {
        switch period {
        case .today: return LocalizedStringResource("No hacks today.", comment: "Summary widget: nothing in Today.")
        case .week: return LocalizedStringResource("No hacks in the last 7 days.", comment: "Summary widget: nothing in the last 7 days.")
        case .all: return LocalizedStringResource("No hacks yet.", comment: "Summary widget: nothing kept at all.")
        }
    }
}

extension StatisticsPeriod {
    /// The widget's names: Last 7 days in full, where the app's picker says 7 days.
    var widgetName: LocalizedStringResource {
        switch self {
        case .today: return LocalizedStringResource("Today", comment: "Summary widget: the period from midnight.")
        case .week: return LocalizedStringResource("Last 7 days", comment: "Summary widget: today and the six days before it.")
        case .all: return LocalizedStringResource("All", comment: "Summary widget: every result kept on this iPhone.")
        }
    }
}

/// The app's own icon at 14 points, the bottom row's line height,
/// flattened from DynamicGlyph.icon with its dark rendition: which app the
/// widget is, without the width a name takes. It leads the bottom row, in
/// the bottom-left corner. Static, and hidden from VoiceOver: the system
/// already names the widget Dynamic Glyph.
private struct AppMark: View {
    static let side: CGFloat = 14
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("AppMark")
            .resizable()
            // Tinted and clear: the icon's luminance in the widget's ink.
            .widgetAccentedRenderingMode(.desaturated)
            .frame(width: Self.side, height: Self.side)
            // There, the dark rendition: its dark ground falls back and the
            // cube stands out, where the light one would be a bright square.
            .environment(\.colorScheme, renderingMode == .fullColor ? colorScheme : .dark)
            .accessibilityHidden(true)
    }
}

/// The three periods as the app's segmented control draws them: a track
/// with the chosen one raised on it, its label heavier too, so the choice
/// doesn't rest on colour. Each runs its intent; the app doesn't open.
private struct PeriodSelector: View {
    let selected: StatisticsPeriod
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatisticsPeriod.allCases) { period in
                let isSelected = period == selected
                Button(intent: SelectSummaryPeriodIntent(period)) {
                    Text(period.widgetName)
                        .font(.caption.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                segmentShape.fill(thumb)
                                    .shadow(color: .black.opacity(renderingMode == .fullColor ? 0.12 : 0), radius: 1, y: 1)
                            }
                        }
                        .padding(.horizontal, 2)
                        // 44 points to tap; the track drawn 32 high.
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .background { trackShape.fill(track).frame(height: 32) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Period", comment: "Summary widget: the period its figures cover."))
    }

    /// Where the Home Screen is tinted, colours become one ink: the raised
    /// segment is a lighter wash of it, so its label still shows.
    private var track: Color {
        renderingMode == .fullColor ? Color(uiColor: .systemGray5) : Color.primary.opacity(0.1)
    }

    private var thumb: Color {
        renderingMode == .fullColor
            ? Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGray2 : .white })
            : Color.primary.opacity(0.25)
    }

    /// Capsules from iOS 26, as its segmented control.
    private var trackShape: AnyShape {
        if #available(iOS 26, *) { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var segmentShape: AnyShape {
        if #available(iOS 26, *) { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The small widget's one button: the period it shows; each tap moves on.
private struct CyclingPeriodButton: View {
    let period: StatisticsPeriod
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Button(intent: SelectSummaryPeriodIntent(period.next)) {
            HStack(spacing: 6) {
                Text(period.widgetName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(renderingMode == .fullColor ? Color(uiColor: .systemGray5) : Color.primary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Change period", comment: "Summary widget: the action of its period buttons, and the name of the small widget's one button."))
        .accessibilityValue(Text(period.widgetName))
    }
}
