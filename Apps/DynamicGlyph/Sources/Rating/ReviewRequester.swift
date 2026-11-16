// The app's one use of StoreKit: Apple's rating sheet. No purchase API is
// used here or anywhere else. Whether to ask is ReviewPromptPolicy's
// decision; iOS then decides whether its sheet appears.
import StoreKit
import SwiftUI

extension View {
    /// Asks iOS for its rating sheet each time `request` changes.
    func requestsReview(on request: Int) -> some View {
        modifier(ReviewRequester(request: request))
    }
}

private struct ReviewRequester: ViewModifier {
    let request: Int
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.onChange(of: request) { _, _ in requestReview() }
    }
}
