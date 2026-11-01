import SwiftUI
import GlyphRecognition

/// One drop group no Glyph hack claimed, among the hack cards. A group is the
/// item panels the game showed together, not a confirmed hack.
struct GearDropCard: View {
    let record: GearDropRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(.headline)
                Text("Drop", comment: "Statistics list: a card for one group of item panels that no Glyph hack claimed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if let drop = record.drop {
                if let note = Self.note(drop.summary.association) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HackGearSection(drop: drop, record: record)
            } else {
                Text("This drop was saved in a format this version of the app can't show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard()
    }

    /// Why no Glyph hack claimed it, where that is worth saying. Gear-only
    /// capture follows no hack, so its groups need no note.
    static func note(_ association: GearDropSummary.Association) -> LocalizedStringResource? {
        switch association {
        case .bonusExpected:
            return LocalizedStringResource("Shown while a Glyph hack was waiting for its Bonus items, so most likely an ordinary hack's.")
        case .uncertainContinuity:
            return LocalizedStringResource("Capture had a gap or a wait ran out, so which hack these came from isn't known.")
        case .unassociated, .ordered, .orderedWithoutBonus, .noWaitingHack, .repeatedBonus:
            return nil
        }
    }
}
