import Foundation

/// Switches to Ingress, or to its App Store page when it is not installed.
///
/// Ingress publishes no URL scheme. `link.ingress.com` does publish an
/// apple-app-site-association claiming every path for the Ingress app, so that
/// link opened as a universal link *only* opens the game when it is installed
/// and does nothing otherwise — it never lands the player on a web page.
struct IngressLauncher {
    static let universalLink = URL(string: "https://link.ingress.com/")!
    static let appStorePage = URL(string: "https://apps.apple.com/app/id576505181")!

    enum Outcome: Equatable { case openedGame, openedAppStore, failed }

    /// Opens a URL, optionally only as a universal link, and says whether
    /// anything opened. Injected so the fallback can be tested without UIKit.
    let open: (_ url: URL, _ universalLinksOnly: Bool) async -> Bool

    func launch() async -> Outcome {
        if await open(Self.universalLink, true) { return .openedGame }
        if await open(Self.appStorePage, false) { return .openedAppStore }
        return .failed
    }
}
