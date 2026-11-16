import SwiftUI

/// A Settings row icon as iOS Settings draws them: a white symbol on a
/// 29-point rounded square.
struct SettingsIcon: View {
    let systemName: String
    let background: Color

    var body: some View {
        // A fixed box for the symbol, not a font size. A Form row gives a
        // Label's icon an image scale: large at standard text sizes, small
        // at accessibility sizes, so a symbol sized by font drew about 22 pt
        // (1.28×) in the 29-pt square at default and 13 pt at AX3. A
        // resizable image ignores the image scale, so the box sets the size
        // (about 60% of the square, as in iOS's own Settings) at every text
        // size.
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An app icon's preview tile, an image in Media.xcassets clipped as iOS
/// clips icons.
struct AppIconPreview: View {
    let choice: AppIconChoice
    let size: CGFloat

    var body: some View {
        Image(choice.previewImageName)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A theme's swatch: its light accent top-left and its dark accent
/// bottom-right, split at 135°, so both appearances show.
struct ThemeSwatch: View {
    let theme: AppTheme
    let size: CGFloat

    var body: some View {
        let pair = theme.tintPair
        Circle()
            .fill(LinearGradient(stops: [.init(color: pair.light, location: 0), .init(color: pair.light, location: 0.5),
                                         .init(color: pair.dark, location: 0.5), .init(color: pair.dark, location: 1)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One tile of Appearance's icon and theme grids: the picture, its name,
/// and the selection ring with its check.
struct AppearanceTile<Picture: View>: View {
    enum Outline { case rounded, circle }

    let name: LocalizedStringResource
    let isSelected: Bool
    let outline: Outline
    let action: () -> Void
    @ViewBuilder let picture: Picture

    /// The card behind the grid, for the badge's outline.
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                picture
                    .padding(6)
                    .overlay {
                        if isSelected {
                            ring.stroke(.tint, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { badge.offset(x: 2, y: 2) }
                Text(name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        // "Violet", or "Violet, selected".
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var ring: AnyShape {
        switch outline {
        case .rounded: return AnyShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        case .circle: return AnyShape(Circle())
        }
    }

    @ViewBuilder
    private var badge: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
                .overlay(Circle().stroke(card, lineWidth: 2))
        }
    }
}
