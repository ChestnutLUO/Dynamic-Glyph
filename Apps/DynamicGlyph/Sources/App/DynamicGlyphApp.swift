import SwiftUI

@main
struct DynamicGlyphApp: App {
    /// The chosen theme and icon, free for everyone.
    @State private var appearance: AppearanceStore
    /// The widget and the Control Center switch, redrawn in the theme as the
    /// app leaves the screen.
    @State private var themeSurfaces: DeferredSurfaceReload
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GearExportFiles.removeStale()
        // Local only: TipKit's datastore in the app's container.
        AppTips.configure()
        ReviewPromptSession.isFirstLaunchAfterUpdate =
            ReviewPromptRecord().registerLaunch(version: ReviewPromptRecord.currentVersion)
        let surfaces = DeferredSurfaceReload.live()
        let appearance = AppearanceStore.live(surfaces: surfaces)
        appearance.start()
        _appearance = State(initialValue: appearance)
        _themeSurfaces = State(initialValue: surfaces)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appearance)
                // The chosen theme; nil, the default, keeps the system tint
                // the app always had. `accentColor` too, since
                // `Color.accentColor` (charts, Start) doesn't follow `tint`.
                .tint(appearance.theme.appTint)
                .accentColor(appearance.theme.appTint)
                .environment(\.appTheme, appearance.theme)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in themeSurfaces.scenePhaseChanged(phase) }
    }
}
