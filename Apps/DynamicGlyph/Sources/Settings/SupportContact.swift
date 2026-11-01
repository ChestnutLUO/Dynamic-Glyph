import Foundation

/// Where players report problems. The email opens with the app, system and
/// device already filled in: a report is little use without them, and players
/// rarely know their build number.
enum SupportContact {
    static let email = "dynamic-glyph@szres.org"
    /// A literal, so it always parses.
    static let telegram = URL(string: "https://t.me/Dynamic_Glyph")!
    static let telegramDisplay = "t.me/Dynamic_Glyph"

    /// Nil only if the address could not form a URL, which a fixed address
    /// never does; the caller then leaves the row out rather than crash.
    static func emailURL(appVersion: String, systemVersion: String, hardware: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        // Technical lines stay in English, like the app's logs: they are read
        // by whoever answers, not by the player.
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Dynamic Glyph support"),
            URLQueryItem(name: "body", value: "\n\n--\nDynamic Glyph \(appVersion)\niOS \(systemVersion) · \(hardware)"),
        ]
        return components.url
    }

    /// "1.2 (34)": the marketing version and the build.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The hardware identifier, such as iPhone17,1, which the marketing name
    /// in UIDevice leaves out.
    static var hardware: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
