import Combine
import Foundation

/// The player's choice of recognition, as one setting over the engine (pixel
/// steps), the logic after it and the power cuts. New is what a player who
/// never chose runs: `AppPreferences`' defaults, the C++ engine with the Swift
/// logic and seven cuts. Old is the Swift engine and logic with no cuts, the
/// recognition every build shipped before the C++ engine became the default;
/// the Swift engine honours `lazyImage`, `planeGate`, `headerStillSkip` and
/// `gearLeanRead`, so Old turns the cuts off rather than leaving them as New
/// set them. Choosing either writes all three, replacing cuts set in
/// Diagnostics. Anything else, as Diagnostics can leave the preferences, is
/// custom and changes nothing until the player picks again.
enum RecognitionEngineSelection: Equatable, Sendable {
    /// Swift engine and Swift logic, no cuts.
    case old
    /// The defaults: C++ engine, Swift logic, `defaultRecognitionCuts`.
    case new
    /// Any other combination, set in Diagnostics.
    case custom

    /// What a choice writes, and what the preferences must hold to show it.
    struct Configuration: Equatable, Sendable {
        var engine: RecognitionEngineChoice
        var logic: RecognitionLogicChoice
        var cuts: Set<RecognitionCut>
    }

    /// The two choices the picker offers.
    static let choices: [RecognitionEngineSelection] = [.old, .new]

    /// Nil for custom, which stands for no one configuration.
    var configuration: Configuration? {
        switch self {
        case .old:
            return Configuration(engine: .swift, logic: .swift, cuts: [])
        case .new:
            return Configuration(engine: AppPreferences.defaultRecognitionEngine,
                                 logic: AppPreferences.defaultRecognitionLogic,
                                 cuts: AppPreferences.defaultRecognitionCuts)
        case .custom:
            return nil
        }
    }

    init(_ configuration: Configuration) {
        self = Self.choices.first { $0.configuration == configuration } ?? .custom
    }

    /// The selection the preferences hold now.
    init(_ preferences: AppPreferences) {
        self.init(Configuration(engine: preferences.recognitionEngine, logic: preferences.recognitionLogic,
                                cuts: preferences.recognitionCuts))
    }

    /// The selection after every change to the stored preferences, on the
    /// main queue, so Settings follows Diagnostics' pickers and switches. The
    /// cuts are a list, which `@AppStorage` can't observe.
    static var changes: AnyPublisher<RecognitionEngineSelection, Never> {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in RecognitionEngineSelection(AppPreferences()) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Writes the choice's engine, logic and cuts. `custom` is not a choice
    /// and leaves them as they are.
    func apply(to preferences: AppPreferences) {
        guard let configuration else { return }
        preferences.recognitionEngine = configuration.engine
        preferences.recognitionLogic = configuration.logic
        preferences.recognitionCuts = configuration.cuts
    }

    var label: String {
        switch self {
        case .old:
            return String(localized: "Old (Swift)",
                          comment: "Settings, recognition engine: the recognition the app used before the C++ engine became the default, written in Swift. Keep \"Swift\", a programming language.")
        case .new:
            return String(localized: "New (C++)",
                          comment: "Settings, recognition engine: the default, the same recognition with its pixel work rewritten in C++, which uses less power. Keep \"C++\", a programming language.")
        case .custom:
            return String(localized: "Custom (see Diagnostics)",
                          comment: "Settings, recognition engine: the engine, logic and power cuts were set in Diagnostics to something other than Old or New, so neither choice applies.")
        }
    }
}
