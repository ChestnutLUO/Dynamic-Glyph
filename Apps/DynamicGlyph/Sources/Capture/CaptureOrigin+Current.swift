import Foundation
import GlyphRecognition

extension CaptureOrigin {
    /// This build, the capture's mode and language, and this iPhone's UTC
    /// offset now: the origin of a record made at this moment.
    static func current(mode: Mode, languages: GameLanguageMemory,
                        playerFaction: PortalFaction? = AppPreferences().playerFaction, bundle: Bundle = .main,
                        timeZone: TimeZone = .current, now: Date = Date()) -> CaptureOrigin {
        let info = bundle.infoDictionary
        let language = languages.state
        return CaptureOrigin(appVersion: info?["CFBundleShortVersionString"] as? String,
                             appBuild: info?["CFBundleVersion"] as? String,
                             captureMode: mode, gameLanguage: language.language,
                             gameLanguageSource: !languages.isAutomatic ? .chosen
                                 : language.isConfirmed ? .detected : .assumed,
                             utcOffsetMinutes: timeZone.secondsFromGMT(for: now) / 60,
                             playerFaction: playerFaction)
    }
}
