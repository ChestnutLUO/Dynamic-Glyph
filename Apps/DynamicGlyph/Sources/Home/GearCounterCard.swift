import SwiftUI
import GlyphRecognition

/// The home screen's card without Glyph assistance: what the capture is doing
/// with the item panels, and today's items. Observes results on its own:
/// they publish separately from the engine.
struct GearCounterCard: View {
    let snapshot: GlyphDisplaySnapshot
    @ObservedObject var results: HackResults
    let now: Double

    var body: some View {
        let statistics = HackStatistics(records: results.records, drops: results.drops, period: .today, now: Date())
        let gear = snapshot.visibleGear(atUptime: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: gear?.symbol ?? "shippingbox")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    // Localized by the recognition package.
                    Text(verbatim: gear?.message(currentHackID: snapshot.hackID)
                         ?? snapshot.statusLine(atUptime: now))
                        .font(.title3.bold())
                    Text(snapshot.liveness == .stopped
                         ? LocalizedStringResource("Tap Start, then hack portals in Ingress. The items each hack drops are counted here.")
                         : LocalizedStringResource("Keep the game's item panels in view after each hack."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
            }
            if statistics.hasGear {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").font(.caption.bold()).foregroundStyle(.secondary)
                    GearStrip(statistics: statistics)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}
