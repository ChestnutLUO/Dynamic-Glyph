import SwiftUI
import UIKit

// MARK: - The period header

/// The top of the Statistics page: the period segments, the timeline bar
/// and the readout. The cards follow the readout directly.
///
/// While a handle is dragged, the bar, its ticks and the readout follow the
/// draft; the page's selection, and with it the cards, charts and Results,
/// changes on release only.
struct StatisticsRangeHeader: View {
    @Binding var selection: StatisticsSelection
    let history: StatisticsHistory
    let ticks: [StatisticsTimeline.Tick]
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The handles while one is dragged; nil otherwise.
    @State private var draft: StatisticsSelection?
    /// The zoomed bar's focus window; nil for the normal bar.
    @State private var zoom: StatisticsTimeline.Zoom?
    @State private var feedback = StatisticsTimelineFeedback()

    private var shown: StatisticsSelection { draft ?? selection }
    private var matched: StatisticsRange.Preset? {
        shown.matchedPreset(now: now, oldest: history.oldest)
    }

    var body: some View {
        VStack(spacing: 0) {
            periodControl
            StatisticsTimelineBar(selection: $selection, draft: $draft, zoom: $zoom, feedback: $feedback,
                                  ticks: ticks, oldest: history.oldest, now: now, matched: matched,
                                  choose: select)
                .padding(.top, 12)
            readout
                .padding(.top, 12)
        }
        // Each fires once as its count changes: on arriving at a hack or a
        // tapped choice, at a section edge or the live edge, on zooming.
        .sensoryFeedback(.selection, trigger: feedback.selection)
        .sensoryFeedback(.impact(weight: .medium), trigger: feedback.edge)
        .sensoryFeedback(.impact(weight: .light), trigger: feedback.zoom)
        // Leaving the page resets to the normal bar.
        .onDisappear {
            draft = nil
            zoom = nil
        }
    }

    /// A segment or zone label: its start, a live end, the normal bar.
    private func select(_ preset: StatisticsRange.Preset) {
        let new = StatisticsSelection.preset(preset, now: Date(), oldest: history.oldest)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            selection = new
            draft = nil
            if zoom != nil {
                zoom = nil
                feedback.zoom += 1
            }
        }
        feedback.selection += 1
    }

    // MARK: Period

    @ViewBuilder
    private var periodControl: some View {
        let segments = StatisticsRange.Preset.segments
        let selected = matched.flatMap { segments.firstIndex(of: $0) }
        if typeSize.isAccessibilitySize {
            // The segments can't fit "30 days" at these sizes: one menu.
            Menu {
                Picker(selection: Binding(get: { selected.map { segments[$0] } },
                                          set: { if let preset = $0 { select(preset) } })) {
                    ForEach(segments) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                } label: {
                    Text("Period")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text("Period").foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    currentChoice.fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                }
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Period"))
            .accessibilityValue(currentChoice)
        } else {
            RangeSegments(titles: segments.map { String(localized: $0.title) }, selected: selected,
                          typeSize: typeSize) { index in
                select(segments[index])
            }
            .accessibilityLabel(Text("Period"))
        }
    }

    /// The segment shown, or the readout's first line.
    private var currentChoice: Text {
        if let matched, StatisticsRange.Preset.segments.contains(matched) { return Text(matched.title) }
        return Text(verbatim: StatisticsRangeText.readout(shown, now: now, oldest: history.oldest).line1)
    }

    // MARK: Readout

    @ViewBuilder
    private var readout: some View {
        if history.isEmpty {
            Text("No saved history yet.", comment: "Statistics: nothing is kept yet.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            let text = StatisticsRangeText.readout(shown, now: now, oldest: history.oldest)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: text.line1)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if text.isLive { LiveBadge() }
                }
                if let line2 = text.line2 {
                    Text(verbatim: line2)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())
            // Numbers roll as the live end moves on; not under the finger,
            // and not with Reduce Motion.
            .animation(reduceMotion || draft != nil ? nil : .default, value: text)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text.spoken))
        }
    }
}

/// The haptics' triggers: each count changes once per arrival.
struct StatisticsTimelineFeedback: Equatable {
    /// A hack snapped to, a segment or label tapped.
    var selection = 0
    /// A section edge snapped to, the live edge reached.
    var edge = 0
    /// Zoomed in or out.
    var zoom = 0
}

/// "LIVE" after the readout's first line: the range keeps ending now.
private struct LiveBadge: View {
    var body: some View {
        Text("LIVE", comment: "Badge: the range keeps ending at the current time.")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1))
            .fixedSize()
    }
}

/// The native segmented control, which can show no segment selected for any
/// other range. Tapping the selected segment again chooses it again, so a
/// 7 days whose start was dragged returns to the preset.
private struct RangeSegments: UIViewRepresentable {
    let titles: [String]
    let selected: Int?
    let typeSize: DynamicTypeSize
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeUIView(context: Context) -> ReselectingSegmentedControl {
        let control = ReselectingSegmentedControl(items: titles)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.apportionsSegmentWidthsByContent = false
        return control
    }

    func updateUIView(_ control: ReselectingSegmentedControl, context: Context) {
        context.coordinator.select = select
        for (index, title) in titles.enumerated() where control.titleForSegment(at: index) != title {
            control.setTitle(title, forSegmentAt: index)
        }
        control.selectedSegmentIndex = selected ?? UISegmentedControl.noSegment
        control.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReselectingSegmentedControl, context: Context) -> CGSize? {
        let natural = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: max(natural.height, 32))
    }

    final class Coordinator: NSObject {
        var select: (Int) -> Void
        init(select: @escaping (Int) -> Void) { self.select = select }

        @objc func changed(_ control: UISegmentedControl) {
            guard control.selectedSegmentIndex != UISegmentedControl.noSegment else { return }
            select(control.selectedSegmentIndex)
        }
    }
}

final class ReselectingSegmentedControl: UISegmentedControl {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let before = selectedSegmentIndex
        super.touchesEnded(touches, with: event)
        if before != UISegmentedControl.noSegment, before == selectedSegmentIndex,
           let touch = touches.first, bounds.contains(touch.location(in: self)) {
            sendActions(for: .valueChanged)
        }
    }
}
