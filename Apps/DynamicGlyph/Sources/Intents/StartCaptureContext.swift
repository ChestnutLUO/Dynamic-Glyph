import Foundation

/// How Start Dynamic Glyph, run in the app's process, sees what Home sees.
///
/// The home screen registers `home` once it is up. On a cold launch the
/// intent can run before that, so `conditions` waits briefly for it; if the
/// screens still aren't up it falls back to what is kept on disk, and Home
/// decides again when the request reaches it.
@MainActor
final class StartCaptureContext {
    static let shared = StartCaptureContext()

    /// Home's capture state and whether first-run setup is on screen; nil
    /// once Home's engine is gone.
    var home: (@MainActor () -> StartCaptureConditions?)?

    /// About as long as a cold launch takes to show its first screen.
    static let homePatience: Duration = .seconds(2)

    func conditions() async -> StartCaptureConditions {
        let deadline = ContinuousClock.now + Self.homePatience
        while home == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The App Group also reports a broadcast (iOS 18-26) that outlived
        // an earlier launch of the app.
        let sharedReportIsOn = ControlCaptureStore.appGroup?.isOn() ?? false
        guard var conditions = home?() else {
            return StartCaptureConditions(isReading: sharedReportIsOn,
                                          isGettingReady: AppPreferences().needsSetup)
        }
        conditions.isReading = conditions.isReading || sharedReportIsOn
        return conditions
    }
}
