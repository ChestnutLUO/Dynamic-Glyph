import UIKit
import WidgetKit

extension AppearanceStore {
    /// The app's store: the real Home Screen icon, and the widget
    /// extension's surfaces redrawn when the theme changes, through
    /// `surfaces` (see `DeferredSurfaceReload` for why not at once).
    static func live(surfaces: DeferredSurfaceReload) -> AppearanceStore {
        AppearanceStore(iconSetter: { UIApplication.shared }, onThemeChange: { surfaces.themeChanged() })
    }
}

extension DeferredSurfaceReload {
    /// The Summary widget and the Control Center switch read the App Group
    /// copy of the theme; the Live Activity reads it at its next update.
    static func live() -> DeferredSurfaceReload {
        DeferredSurfaceReload {
            WidgetCenter.shared.reloadAllTimelines()
            ControlChannel.reload()
        }
    }
}
