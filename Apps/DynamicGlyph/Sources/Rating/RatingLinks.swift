import Foundation

/// Where Settings' Rate and Source code rows go. Both open outside the app;
/// nothing is sent from it.
enum RatingLinks {
    /// The App Store's write-a-review page for this app. Literals, so they
    /// always parse.
    static let writeReview = URL(string: "https://apps.apple.com/app/id6814911908?action=write-review")!
    static let sourceCode = URL(string: "https://github.com/ChestnutLUO/Dynamic-Glyph")!
}
