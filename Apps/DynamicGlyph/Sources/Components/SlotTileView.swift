import SwiftUI
import GlyphRecognition

/// One slot, drawn from the style the shared renderer chose for it.
struct SlotTileView: View {
    let index: Int
    let style: TileStyle
    let table: GlyphTable?
    let isCurrent: Bool
    /// The evidence line, chosen by the shared model so the in-app tiles and
    /// the Picture in Picture window cannot word it differently.
    let note: String?
    var inputCheck: InputCheckDisplay? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(index + 1, format: .number)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(isCurrent ? 0.9 : 0.25),
                            style: StrokeStyle(lineWidth: isCurrent ? 2 : 1))
                if let id = style.glyph, let path = table?.path(for: id) {
                    ZStack {
                        GlyphArrayFrame()
                        GlyphDiagramShape(path: path)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                                             lineJoin: .round, dash: style.isDashed ? [4, 3] : []))
                    }
                    .padding(4)
                } else {
                    Text(verbatim: "?").font(.title3.bold()).foregroundStyle(tint)
                }
            }
            .frame(height: 58)
            .overlay(alignment: .topTrailing) {
                if let inputCheck, inputCheck.showsSymbol {
                    Text(verbatim: inputCheck.verdict.symbol)
                        .font(.caption.bold())
                        .foregroundStyle(inputCheck.verdict == .differs ? Color.red : Color.secondary)
                        .padding(3).background(.black, in: Circle())
                }
            }
            .overlay {
                if inputCheck?.verdict == .differs {
                    RoundedRectangle(cornerRadius: 8).stroke(.red, lineWidth: 2)
                }
            }
            .accessibilityLabel(inputCheck?.message(slotNumber: index + 1) ?? style.caption)
            // Localized by the recognition package; Glyph names stay as the game has them.
            Text(style.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(inputCheck?.message(slotNumber: index + 1) ?? note ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tint: Color {
        switch style {
        case .confirmed: return Color(red: 0.80, green: 0.78, blue: 1.00)
        case .observing, .inferred: return Color(red: 1.00, green: 0.78, blue: 0.30)
        case .predicted, .alternatives: return Color(red: 0.35, green: 0.75, blue: 0.90)
        case .uncertain, .missing: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .pending: return .secondary
        }
    }
}
