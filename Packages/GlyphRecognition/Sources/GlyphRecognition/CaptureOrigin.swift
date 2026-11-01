import Foundation

/// How and where a record was captured, stamped by the app when the record
/// is made. Absent in records from builds before it was kept, and never
/// filled in later: the iPhone exporting a record may not be the one, or
/// run the build, that captured it.
public struct CaptureOrigin: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable {
        /// Following Glyph hacks, with results and gear.
        case glyphAssistance
        /// Reading item panels only.
        case gearOnly
    }

    public enum LanguageSource: String, Sendable, Codable {
        /// The player chose the game's language.
        case chosen
        /// Automatic reading saw it in its own words on a screen of this
        /// capture.
        case detected
        /// Automatic reading's starting guess, not yet confirmed: the last
        /// capture's language, the iPhone's, or English.
        case assumed
    }

    /// The capturing app's marketing version and build.
    public var appVersion: String?
    public var appBuild: String?
    public var captureMode: Mode?
    public var gameLanguage: GameLanguage?
    public var gameLanguageSource: LanguageSource?
    /// The capturing iPhone's offset from UTC when the record was made.
    public var utcOffsetMinutes: Int?
    /// The player's faction as set in Settings when the record was made; nil
    /// when it wasn't set.
    public var playerFaction: PortalFaction?

    public init(appVersion: String?, appBuild: String?, captureMode: Mode?, gameLanguage: GameLanguage?,
                gameLanguageSource: LanguageSource?, utcOffsetMinutes: Int?, playerFaction: PortalFaction? = nil) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.captureMode = captureMode
        self.gameLanguage = gameLanguage
        self.gameLanguageSource = gameLanguageSource
        self.utcOffsetMinutes = utcOffsetMinutes
        self.playerFaction = playerFaction
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion, appBuild, captureMode, gameLanguage, gameLanguageSource, utcOffsetMinutes, playerFaction
    }

    /// A value this build doesn't know, written by a later one, reads as
    /// unknown rather than failing the record that carries it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try? values.decodeIfPresent(String.self, forKey: .appVersion)
        appBuild = try? values.decodeIfPresent(String.self, forKey: .appBuild)
        captureMode = (try? values.decodeIfPresent(String.self, forKey: .captureMode)).flatMap { $0.flatMap(Mode.init) }
        gameLanguage = (try? values.decodeIfPresent(String.self, forKey: .gameLanguage)).flatMap { $0.flatMap(GameLanguage.init) }
        gameLanguageSource = (try? values.decodeIfPresent(String.self, forKey: .gameLanguageSource))
            .flatMap { $0.flatMap(LanguageSource.init) }
        utcOffsetMinutes = try? values.decodeIfPresent(Int.self, forKey: .utcOffsetMinutes)
        playerFaction = (try? values.decodeIfPresent(String.self, forKey: .playerFaction))
            .flatMap { $0.flatMap(PortalFaction.init(rawValue:)) }
    }
}
