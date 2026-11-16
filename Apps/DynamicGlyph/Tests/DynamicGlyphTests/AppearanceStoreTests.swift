import Foundation
import Testing

/// The Home Screen icon as a test wants it.
@MainActor
final class FakeIcons: AlternateIconSetting {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var sets: [String?] = []
    var failure: Error?

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        if let failure { throw failure }
        sets.append(alternateIconName)
        self.alternateIconName = alternateIconName
    }
}

/// Themes and app icons are free in 1.2: nothing is bought, nothing is
/// locked, and nothing puts the default back on its own.
@MainActor
@Suite("Appearance store", .serialized)
struct AppearanceStoreTests {
    let suite = "AppearanceStoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let mirror: AppThemeMirror
    let icons = FakeIcons()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mirror = AppThemeMirror(url: directory.appendingPathComponent(AppTheme.mirrorFileName))
    }

    var preferences: AppearancePreferences { AppearancePreferences(defaults: defaults, mirror: mirror) }

    func makeStore(themeChanges: (() -> Void)? = nil) -> AppearanceStore {
        let icons = icons
        return AppearanceStore(iconSetter: { icons }, appearance: preferences, onThemeChange: { themeChanges?() })
    }

    @Test("Six themes besides the default, and six alternate icons")
    func counts() {
        #expect(AppTheme.allCases.filter { $0 != .default }.count == 6)
        #expect(AppIconChoice.allCases.compactMap(\.alternateIconName).count == 6)
    }

    @Test("Any theme applies at once, with no purchase, and reaches the App Group")
    func anyTheme() {
        var changes = 0
        let store = makeStore(themeChanges: { changes += 1 })
        #expect(store.theme == .default)
        for theme in AppTheme.allCases.reversed() {
            store.setTheme(theme)
            #expect(store.theme == theme && mirror.read() == theme, "\(theme)")
            #expect(preferences.theme == theme, "\(theme)")
        }
        #expect(changes == AppTheme.allCases.count)
    }

    @Test("Any icon is set through the system, with no purchase")
    func anyIcon() async {
        let store = makeStore()
        for choice in AppIconChoice.allCases.reversed() {
            await store.setIcon(choice, isBundled: { _ in true })
            #expect(icons.alternateIconName == choice.alternateIconName && store.iconChoice == choice, "\(choice.id)")
        }
        #expect(icons.sets.count == AppIconChoice.allCases.count)
    }

    @Test("An icon the build lacks, or a failed change, leaves the icon as it was")
    func iconFailures() async {
        let store = makeStore()
        let emerald = AppIconChoice(theme: .emerald)
        await store.setIcon(emerald, isBundled: { _ in true })
        #expect(icons.alternateIconName == "DynamicGlyphEmerald" && store.iconChoice == emerald)
        await store.setIcon(AppIconChoice(theme: .crimson), isBundled: { _ in false })
        #expect(icons.alternateIconName == "DynamicGlyphEmerald" && store.iconChoice == emerald)
        icons.failure = CocoaError(.featureUnsupported)
        await store.setIcon(.default, isBundled: { _ in true })
        #expect(store.iconChoice == emerald, "A failed change reverts the selection")
        icons.failure = nil
        await store.setIcon(.default, isBundled: { _ in true })
        #expect(icons.alternateIconName == nil && store.iconChoice == .default)
    }

    @Test("Launch keeps the chosen theme and icon, and only repairs the App Group copy")
    func noResetAtLaunch() {
        preferences.theme = .orchid
        icons.alternateIconName = "DynamicGlyphOrchid"
        // A restore from backup that left the App Group behind.
        #expect(mirror.write(.default))
        // Keys an earlier version left behind mean nothing now.
        defaults.set(true, forKey: "supporter.packOwnedLastKnown")
        defaults.set(true, forKey: "supporter.revokedNoticePending")
        var changes = 0
        let store = makeStore(themeChanges: { changes += 1 })
        store.start()
        store.refreshIconChoice()
        #expect(store.theme == .orchid && preferences.theme == .orchid)
        #expect(mirror.read() == .orchid)
        #expect(store.iconChoice == AppIconChoice(theme: .orchid))
        #expect(icons.sets.isEmpty, "Launch never changes the icon")
        #expect(changes == 0)
    }
}

/// No purchase is left in the app. StoreKit is imported by one file only,
/// the review request (Apple's rating sheet), and no source -- that one
/// included -- uses a purchase API; the local StoreKit configuration is
/// gone. Read from the source tree, so skipped where there is no checkout.
@Suite("No in-app purchases in the project")
struct NoInAppPurchaseTests {
    static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var checkoutAvailable: Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent("project.yml").path)
    }

    /// The one file allowed to import StoreKit, relative to the app folder.
    static let reviewRequest = "Sources/Rating/ReviewRequester.swift"

    /// StoreKit's purchase, entitlement and store-view API, as whole words:
    /// `Transaction` alone would also catch SwiftUI's `Transaction()`,
    /// `withTransaction` and `CATransaction`, which buy nothing. Simple
    /// word boundaries: by Unicode's, `Transaction.updates` is one word.
    static let purchaseAPIs: [(name: String, pattern: Regex<Substring>)] = ([
        ("Product.", #/\bProduct\./#), ("Product(", #/\bProduct\(/#),
        ("Transaction", #/\bTransaction\b(?!\s*\()/#), (".purchase(", #/\.purchase\(/#),
        ("SKPaymentQueue", #/\bSKPaymentQueue\b/#), ("SKProduct", #/\bSKProduct/#),
        ("AppStore.sync", #/\bAppStore\.sync\b/#), ("StoreView", #/\bStoreView\b/#),
        ("ProductView", #/\bProductView\b/#), ("SubscriptionStoreView", #/\bSubscriptionStoreView\b/#),
        ("currentEntitlements", #/\bcurrentEntitlements\b/#),
    ] as [(name: String, pattern: Regex<Substring>)]).map { ($0.name, $0.pattern.wordBoundaryKind(.simple)) }

    /// Every Swift source of the app, widget and broadcast extension, by
    /// path relative to the app folder.
    static func sources() throws -> [(path: String, text: String)] {
        var found: [(path: String, text: String)] = []
        let prefix = app.standardizedFileURL.path + "/"
        for folder in ["Sources", "Shared", "Widget", "Broadcast"] {
            let root = app.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
                found.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return found
    }

    @Test("Only the review request uses StoreKit; no purchase APIs", .enabled(if: checkoutAvailable))
    func noStoreKit() throws {
        let sources = try Self.sources()
        #expect(sources.contains { $0.path == Self.reviewRequest }, "\(Self.reviewRequest) moved: update this test")
        let importers = sources.filter { $0.text.contains("import StoreKit") }.map(\.path)
        #expect(importers.allSatisfy { $0 == Self.reviewRequest }, "\(importers)")
        var purchases: [String] = []
        for source in sources {
            for api in Self.purchaseAPIs where source.text.contains(api.pattern) {
                purchases.append("\(source.path): \(api.name)")
            }
        }
        #expect(purchases.isEmpty, "\(purchases)")
    }

    @Test("The purchase scan finds StoreKit's purchase calls and not SwiftUI's or Core Animation's transactions")
    func purchaseScan() {
        func flagged(_ text: String) -> [String] {
            Self.purchaseAPIs.filter { text.contains($0.pattern) }.map(\.name)
        }
        #expect(flagged("for await update in Transaction.updates {}") == ["Transaction"])
        #expect(flagged("let products = try await Product.products(for: ids)") == ["Product."])
        #expect(flagged("let result = try await product.purchase()") == [".purchase("])
        #expect(flagged("for await e in Transaction.currentEntitlements {}") == ["Transaction", "currentEntitlements"])
        #expect(flagged("SubscriptionStoreView(groupID: id)") == ["SubscriptionStoreView"])
        #expect(flagged("var t = Transaction(); withTransaction(t) {}; CATransaction.begin()").isEmpty)
        #expect(flagged("@Environment(\\.requestReview) private var requestReview").isEmpty)
    }

    @Test("No StoreKit configuration in the project", .enabled(if: checkoutAvailable))
    func noConfiguration() throws {
        let project = try String(contentsOf: Self.app.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(!project.contains(".storekit"))
        #expect(!FileManager.default.fileExists(atPath: Self.app.appendingPathComponent("StoreKit").path))
    }
}
