import Foundation
import SwiftUI

extension AppTheme {
    /// The colour's name, from the catalog key in the theme's table. Shared
    /// by the theme and the icon of the same colour.
    var name: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: spec.nameKey)
    }
}

extension AppIconChoice {
    var name: LocalizedStringResource { theme.name }
}

/// The chosen theme: kept in standard defaults for the app, and copied to the
/// App Group for the widget extension, which then reloads.
struct AppearancePreferences {
    let defaults: UserDefaults
    let mirror: AppThemeMirror

    init(defaults: UserDefaults = .standard, mirror: AppThemeMirror = .appGroup) {
        self.defaults = defaults
        self.mirror = mirror
    }

    var theme: AppTheme {
        get { defaults.string(forKey: AppTheme.defaultsKey).flatMap(AppTheme.init(rawValue:)) ?? .default }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: AppTheme.defaultsKey)
            mirror.write(newValue)
        }
    }

    /// Writes the copy again when it disagrees with the app's choice, as
    /// after a restore from backup that left the App Group behind. True when
    /// it wrote.
    @discardableResult
    func syncMirror() -> Bool {
        let theme = theme
        guard mirror.read() != theme else { return false }
        return mirror.write(theme)
    }
}
