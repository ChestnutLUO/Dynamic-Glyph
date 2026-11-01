import Foundation
import Testing

@Suite("Support contact")
struct SupportContactTests {
    @Test("The email goes to the support address, with the versions in its body")
    func emailURL() throws {
        let url = try #require(SupportContact.emailURL(appVersion: "1.2 (34)", systemVersion: "27.0",
                                                       hardware: "iPhone17,1"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "dynamic-glyph@szres.org")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["subject"] == "Dynamic Glyph support")
        let body = try #require(items["body"] ?? nil)
        #expect(body.contains("Dynamic Glyph 1.2 (34)"))
        #expect(body.contains("iOS 27.0 · iPhone17,1"))
        // Spaces and line breaks must be encoded, or Mail truncates the body.
        #expect(!url.absoluteString.contains(" ") && !url.absoluteString.contains("\n"))
    }

    @Test("The Telegram link opens the project's channel")
    func telegram() {
        #expect(SupportContact.telegram.absoluteString == "https://t.me/Dynamic_Glyph")
        #expect(SupportContact.telegram.absoluteString.hasSuffix(SupportContact.telegramDisplay))
    }

    @Test("The hardware identifier is read, not left empty")
    func hardware() {
        #expect(!SupportContact.hardware.isEmpty)
    }
}
