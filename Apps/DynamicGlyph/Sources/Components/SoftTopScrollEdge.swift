import SwiftUI

extension View {
    /// Fades rows scrolled under the top edge instead of frosting them. Scroll
    /// edge effects arrived in iOS 26; before it, content scrolls under the
    /// navigation bar as it always has, so there is nothing to change.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
