import Foundation
import Observation
import os

/// The chosen colour theme and Home Screen icon. Free for everyone: any
/// theme or icon applies at once, nothing is bought and nothing is ever
/// reset behind the player's back.
///
/// Made once, at launch, at the app's root, which tints the app with
/// `theme`; Settings › Appearance changes it.
@MainActor
@Observable
final class AppearanceStore {
    private(set) var theme: AppTheme
    private(set) var iconChoice = AppIconChoice.default

    @ObservationIgnored private let iconSetter: @MainActor () -> AlternateIconSetting
    @ObservationIgnored private let appearance: AppearancePreferences
    @ObservationIgnored private let onThemeChange: @MainActor () -> Void
    @ObservationIgnored private let log = Logger(subsystem: "org.szres.DynamicGlyph", category: "Appearance")

    init(iconSetter: @escaping @MainActor () -> AlternateIconSetting,
         appearance: AppearancePreferences = AppearancePreferences(),
         onThemeChange: @escaping @MainActor () -> Void = {}) {
        self.iconSetter = iconSetter
        self.appearance = appearance
        self.onThemeChange = onThemeChange
        theme = appearance.theme
    }

    /// Called at launch: writes the App Group copy again if a restore from
    /// backup left it behind, so the widget extension shows the app's theme.
    /// Changes neither the theme nor the icon.
    func start() {
        appearance.syncMirror()
    }

    /// Applies the theme at once and copies it to the App Group.
    func setTheme(_ newTheme: AppTheme) {
        appearance.theme = newTheme
        theme = newTheme
        onThemeChange()
    }

    /// Reads the icon iOS shows now.
    func refreshIconChoice() {
        iconChoice = AppIconChoice(alternateIconName: iconSetter().alternateIconName)
    }

    /// Fails quietly, leaving the icon as it was, when this build lacks the
    /// icon or the system offers none.
    func setIcon(_ choice: AppIconChoice,
                 isBundled: (AppIconChoice) -> Bool = { AppIconChoice.isBundled($0) }) async {
        let icons = iconSetter()
        do {
            try await icons.setIcon(choice, isBundled: isBundled)
        } catch {
            log.error("icon \(choice.id, privacy: .public) not set: \(String(describing: error), privacy: .public)")
        }
        iconChoice = AppIconChoice(alternateIconName: icons.alternateIconName)
    }
}
