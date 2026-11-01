import Foundation

/// The game language a capture reads, shared by its readers. Text can only be
/// read in the right script, so when a screen confirmed by its shape (a
/// result page, an item panel, a notice box) yields unresolved text, the
/// readers try the other languages on that same frame. Only a language's own
/// labels or notices change the capture's language; a better item reader can
/// be remembered temporarily for one panel. A language the player chose
/// never changes.
public final class GameLanguageMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var language: GameLanguage
    private var lastAttempt: [Screen: Double] = [:]
    /// A better reader for one portal panel, without evidence for changing
    /// the game's language. Kept separately so successive samples can agree.
    private var panelReading: (language: GameLanguage, bounds: GearDropPanelBounds, time: Double)?
    private var confirmed = false
    public let isAutomatic: Bool
    /// Seconds between attempts on one kind of screen, so a screen no
    /// language reads, such as one under the floating window, costs little.
    /// Each kind waits on its own: a failed try on a result page must not
    /// block the notice that follows.
    public let retryInterval: Double

    public enum Screen: Sendable { case notice, result, panel }
    /// Told of each change, to remember it for the next capture.
    private let onChange: @Sendable (GameLanguage) -> Void

    public init(language: GameLanguage, isAutomatic: Bool, retryInterval: Double = 1,
                onChange: @escaping @Sendable (GameLanguage) -> Void = { _ in }) {
        self.language = language
        self.isAutomatic = isAutomatic
        self.retryInterval = retryInterval
        self.onChange = onChange
    }

    public var current: GameLanguage {
        lock.lock(); defer { lock.unlock() }
        return language
    }

    /// Automatic reading has seen `current` in its own words on a screen of
    /// this capture. Until then it is the starting guess: the last capture's
    /// language, the iPhone's, or English. Always false for a chosen language,
    /// which nothing confirms or changes.
    public var isConfirmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return confirmed
    }

    /// `current` and `isConfirmed` read together, so a language found
    /// between two reads can't pair one with the other.
    public var state: (language: GameLanguage, isConfirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (language, confirmed)
    }

    public func panelReadingLanguage(at time: Double, bounds: GearDropPanelBounds) -> GameLanguage? {
        lock.lock(); defer { lock.unlock() }
        guard isAutomatic, let reading = panelReading, time.isFinite,
              time >= reading.time, time - reading.time <= 5,
              abs(reading.bounds.top - bounds.top) <= 0.003,
              abs(reading.bounds.bottom - bounds.bottom) <= 0.003 else {
            panelReading = nil
            return nil
        }
        return reading.language
    }

    /// Item text can select a reader for this panel, but cannot name the
    /// capture's language or notify the app's persisted-language preference.
    public func rememberPanelReading(_ language: GameLanguage, at time: Double, bounds: GearDropPanelBounds) {
        lock.lock(); defer { lock.unlock() }
        guard isAutomatic, time.isFinite else { return }
        panelReading = (language, bounds, time)
    }

    /// The other languages to try on an unread screen now, in a fixed order;
    /// empty when the language was chosen or an attempt was made just now.
    public func alternatives(at time: Double, on screen: Screen) -> [GameLanguage] {
        lock.lock(); defer { lock.unlock() }
        let last = lastAttempt[screen] ?? -.infinity
        // Notices are small crops, cheap to read, and can last one sample.
        let interval = screen == .notice ? retryInterval / 2 : retryInterval
        guard isAutomatic, time.isFinite, time < last || time - last >= interval else { return [] }
        lastAttempt[screen] = time
        return GameLanguage.allCases.filter { $0 != language }
    }

    /// A language whose own text was just read on a confirmed screen: the
    /// current one, which this confirms, or another, which it becomes.
    public func found(_ found: GameLanguage) {
        lock.lock()
        let changed = isAutomatic && found != language
        if changed { language = found; panelReading = nil }
        if isAutomatic { confirmed = true }
        lock.unlock()
        if changed { onChange(found) }
    }

    /// Where automatic detection starts: the last language found, else the
    /// iPhone's language when a game language matches it, else English.
    public static func startingGuess(remembered: GameLanguage?, preferredLanguages: [String]) -> GameLanguage {
        if let remembered { return remembered }
        for identifier in preferredLanguages {
            let code = identifier.lowercased()
            if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") { return .traditionalChinese }
            if code.hasPrefix("zh") { return .simplifiedChinese }
            if code.hasPrefix("ja") { return .japanese }
            if code.hasPrefix("ko") { return .korean }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }
}
