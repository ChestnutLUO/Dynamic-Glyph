import SwiftUI

/// Redraws the widget extension's surfaces (the Summary widget and the
/// Control Center switch) after the theme changes, once the app has left
/// the screen rather than at every tap.
///
/// WidgetKit honours only the first reload an app asks for while it is in
/// the foreground; chronod throttles the rest ("Throttling additional
/// refresh request while foreground"). Reloading at each tap, a player who
/// tried Violet, then Emerald, then Crimson found the widget still Violet.
/// So a change only marks a reload as owed, and the owed reload is made
/// once as the scene goes to the background, with the theme chosen last.
/// Neither surface can be seen while the app fills the screen.
///
/// With no scene in front, nothing will go to the background later, so a change
/// reloads at once.
@MainActor
final class DeferredSurfaceReload {
    /// A theme change not yet shown by the widget extension.
    private(set) var isOwed = false
    /// Whether a scene is on screen; false until the first one becomes active.
    private(set) var isInForeground = false
    private let reload: @MainActor () -> Void

    init(reload: @escaping @MainActor () -> Void) {
        self.reload = reload
    }

    /// The theme changed: reload when the app leaves the screen, or now if
    /// it already has.
    func themeChanged() {
        isOwed = true
        if !isInForeground { flush() }
    }

    /// The scene's phase. Leaving for the background makes the owed reload.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInForeground = true
        case .background:
            isInForeground = false
            flush()
        default:
            // Inactive: Control Center or the app switcher over the app,
            // which may come straight back.
            break
        }
    }

    private func flush() {
        guard isOwed else { return }
        isOwed = false
        reload()
    }
}
