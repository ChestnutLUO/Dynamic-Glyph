import Foundation
import SwiftUI
import Testing

/// WidgetKit honours one foreground reload; the theme's reload waits for the
/// app to leave the screen, and is made once with the theme chosen last.
@MainActor
@Suite("Theme surfaces reload when the app leaves the screen", .serialized)
struct DeferredSurfaceReloadTests {
    let suite = "DeferredSurfaceReloadTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let mirror: AppThemeMirror

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mirror = AppThemeMirror(url: directory.appendingPathComponent(AppTheme.mirrorFileName))
    }

    @Test("Changes in the foreground are owed, and reloaded once on going to the background")
    func deferredWhileForeground() {
        var reloads = 0
        let surfaces = DeferredSurfaceReload { reloads += 1 }
        surfaces.scenePhaseChanged(.active)
        surfaces.themeChanged()
        surfaces.themeChanged()
        surfaces.themeChanged()
        #expect(reloads == 0 && surfaces.isOwed)
        surfaces.scenePhaseChanged(.inactive)
        #expect(reloads == 0, "Control Center or the app switcher over the app isn't leaving it")
        surfaces.scenePhaseChanged(.background)
        #expect(reloads == 1 && !surfaces.isOwed)
        surfaces.scenePhaseChanged(.active)
        surfaces.scenePhaseChanged(.background)
        #expect(reloads == 1, "Nothing owed, nothing reloaded")
    }

    @Test("With no scene in front a change reloads at once")
    func immediateWithoutScene() {
        var reloads = 0
        let surfaces = DeferredSurfaceReload { reloads += 1 }
        surfaces.themeChanged()
        #expect(reloads == 1 && !surfaces.isOwed, "Before any scene is active")
        surfaces.scenePhaseChanged(.active)
        surfaces.scenePhaseChanged(.background)
        #expect(reloads == 1)
        surfaces.themeChanged()
        #expect(reloads == 2, "In the background")
    }

    @Test("The store's theme taps reach the widget as the last theme, once per visit")
    func storeIntegration() async {
        let icons = FakeIcons()
        var seen: [AppTheme] = []
        let mirror = mirror
        let surfaces = DeferredSurfaceReload { seen.append(mirror.read()) }
        let store = AppearanceStore(iconSetter: { icons },
                                    appearance: AppearancePreferences(defaults: defaults, mirror: mirror),
                                    onThemeChange: { surfaces.themeChanged() })
        surfaces.scenePhaseChanged(.active)
        for theme in [AppTheme.violet, .emerald, .crimson] { store.setTheme(theme) }
        #expect(seen.isEmpty)
        surfaces.scenePhaseChanged(.background)
        #expect(seen == [.crimson])

        surfaces.scenePhaseChanged(.active)
        store.setTheme(.default)
        surfaces.scenePhaseChanged(.background)
        #expect(seen == [.crimson, .default])

        // In the background no scene will leave the screen to make the
        // reload, so it's made at once.
        store.setTheme(.violet)
        #expect(seen == [.crimson, .default, .violet])
    }
}
