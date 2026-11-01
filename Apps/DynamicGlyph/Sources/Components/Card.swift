import SwiftUI

extension View {
    /// The one card look the home screen and setup use.
    func card() -> some View {
        padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    /// A card on a grouped page, such as Statistics, whose grey background
    /// would swallow the plain card's fill.
    func groupedCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay { shape.strokeBorder(Color(.separator), lineWidth: 0.5) }
    }
}
