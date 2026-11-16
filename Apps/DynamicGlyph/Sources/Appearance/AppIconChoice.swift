import Foundation
import UIKit

/// One of the app icons: the cube recoloured for a theme.
/// Derived from `AppTheme`'s table, so a theme added
/// there brings its icon; its name, `.icon` package and preview tile are in
/// the theme's `spec`.
struct AppIconChoice: Hashable, Identifiable, CaseIterable, Sendable {
    let theme: AppTheme

    static let `default` = AppIconChoice(theme: .default)
    static var allCases: [AppIconChoice] { AppTheme.allCases.map(AppIconChoice.init(theme:)) }

    init(theme: AppTheme) {
        self.theme = theme
    }

    /// The icon iOS reports; an unknown name reads as the default.
    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .default
    }

    var id: String { theme.rawValue }

    /// The name `setAlternateIconName` takes; nil is the primary icon.
    var alternateIconName: String? { theme.spec.iconName }

    var previewImageName: String { theme.spec.iconPreview }

    /// Whether the built app carries this icon: the primary always, an
    /// alternate only once its `.icon` is in the bundle's CFBundleIcons.
    static func isBundled(_ choice: AppIconChoice, infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        guard let name = choice.alternateIconName else { return true }
        let icons = infoDictionary?["CFBundleIcons"] as? [String: Any]
        let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
        return alternates?[name] != nil
    }
}

/// What changes the Home Screen icon: UIApplication in the app, a fake in tests.
@MainActor
protocol AlternateIconSetting: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ alternateIconName: String?) async throws
}

extension UIApplication: AlternateIconSetting {}

enum AppIconChangeError: Error, Equatable {
    /// The device or system offers no alternate icons.
    case unsupported
    /// The alternate's `.icon` is not in this build.
    case missingIcon(String)
}

extension AlternateIconSetting {
    /// Sets the icon, or throws without touching it when the build lacks
    /// that icon. iOS shows its own "You have changed the icon" alert.
    func setIcon(_ choice: AppIconChoice, isBundled: (AppIconChoice) -> Bool = { AppIconChoice.isBundled($0) }) async throws {
        guard supportsAlternateIcons else { throw AppIconChangeError.unsupported }
        if let name = choice.alternateIconName, !isBundled(choice) { throw AppIconChangeError.missingIcon(name) }
        guard alternateIconName != choice.alternateIconName else { return }
        try await setAlternateIconName(choice.alternateIconName)
    }
}
