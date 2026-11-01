import SwiftUI
import GlyphRecognition

/// The home screen's way into the results page, showing the latest hack.
struct LastHackCard: View {
    @ObservedObject var results: HackResults
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rosette")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hack results").font(.headline)
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
            }
            if results.readsResults, let summary = results.latest?.summary,
               summary.state == .complete || summary.state == .partial {
                // At accessibility sizes the labels need the full width.
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 16))
                layout {
                    bonus("Hacking Bonus", summary.hackingBonus)
                    bonus("Speed Bonus", summary.speedBonus)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    HStack(spacing: 4) {
                        ForEach(summary.slots.indices, id: \.self) { index in
                            Image(systemName: dot(summary.slots[index].outcome))
                                .foregroundStyle(tint(summary.slots[index].outcome))
                                .accessibilityLabel(summary.accessibilityLabel(slot: index))
                        }
                    }
                    .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }

    @ViewBuilder private var subtitle: some View {
        if !results.readsResults {
            Text("Off. Tap to turn on reading each hack's result.")
        } else if let latest = results.latest, let summary = latest.summary {
            // Both parts are already localized: the headline by the
            // recognition package, the time by its formatter.
            Text(verbatim: "\(summary.headline) · \(latest.date.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("After each Glyph hack, its result appears here.")
        }
    }

    private func bonus(_ title: LocalizedStringResource, _ value: HackResultSummary.Bonus?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: HackResultSummary.percentText(value).map { value?.isFinal == false ? "\($0)?" : $0 } ?? "—")
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func dot(_ outcome: GameSlotOutcome) -> String {
        switch outcome {
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(_ outcome: GameSlotOutcome) -> Color {
        switch outcome {
        case .accepted: return .green
        case .rejected: return .red
        case .unknown: return .secondary
        }
    }
}
