import AppIntents

/// The app's actions in Siri, Spotlight and Shortcuts, ready without any
/// setup. Every phrase names the app, and at most one choice. The phrases'
/// translations are in AppShortcuts.xcstrings; the titles in Localizable.
struct DynamicGlyphShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCaptureIntent(),
                    phrases: [
                        "Start \(.applicationName)",
                        "Start reading with \(.applicationName)",
                    ],
                    // The tile sits under the app's name, so the Home button's word
                    // fits; the full name stays the action's title.
                    shortTitle: LocalizedStringResource("Start", comment: "Main button: start capturing the screen."),
                    systemImageName: "play.fill")
        AppShortcut(intent: StopCaptureIntent(),
                    phrases: [
                        "Stop \(.applicationName)",
                        "Stop reading with \(.applicationName)",
                    ],
                    shortTitle: LocalizedStringResource("Stop", comment: "Main button: stop capturing the screen."),
                    systemImageName: "stop.fill")
        AppShortcut(intent: OpenStatisticsIntent(),
                    phrases: [
                        "Show \(.applicationName) statistics",
                        "Open statistics in \(.applicationName)",
                        "Show \(\.$period) in \(.applicationName)",
                    ],
                    shortTitle: LocalizedStringResource("Statistics", comment: "Tab bar: the game results read after each hack."),
                    systemImageName: "chart.bar")
    }
}
