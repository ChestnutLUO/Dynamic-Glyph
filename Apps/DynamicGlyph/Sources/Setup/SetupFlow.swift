import GlyphRecognition

/// One page of first-run setup.
enum SetupStep: Equatable {
    case welcome, accountWarning, dynamicIsland, liveActivities, floatingWindow, done
}

/// Which setup page follows which, from what is known about the phone and
/// what the player has chosen so far. Pure, so every path can be tested.
struct SetupFlow: Equatable {
    var detected: DynamicIslandSupport
    /// The player's own answer to "Does your iPhone have a Dynamic Island?",
    /// when the model was unknown or they corrected the detection.
    var reportedIsland: Bool?
    var wantsIsland: Bool
    var activitiesEnabled: Bool
    /// The floating-window switch, which only Island users are offered.
    var floatingWindowEnabled: Bool
    /// On iOS 18-26 the app runs over Ingress only while the window is open.
    var floatingWindowRequired = false

    /// Nil until the model or the player has settled it.
    var hasIsland: Bool? {
        if let reportedIsland { return reportedIsland }
        switch detected {
        case .hasIsland: return true
        case .noIsland: return false
        case .unknown: return nil
        }
    }

    /// Only an Island the player chose to use counts toward the display.
    var usesIsland: Bool { hasIsland == true && wantsIsland }

    /// The Island can actually show the sequence: chosen, and Live Activities
    /// on. Chosen with them off, the activity controller refuses to start it.
    var islandShowsSequence: Bool { usesIsland && activitiesEnabled }

    /// Setup never finishes with nothing on screen over Ingress: until the
    /// Island can show the sequence, the floating window cannot be turned off.
    /// Where the app needs the window to keep running, it never can.
    var canTurnOffFloatingWindow: Bool { !floatingWindowRequired && islandShowsSequence }

    var showsFloatingWindow: Bool { !canTurnOffFloatingWindow || floatingWindowEnabled }

    /// Where the floating-window sliders start. A shape setup offers was the
    /// player's own choice and is kept; anything else, such as the 384 x 96
    /// every install saved before 1280 x 128 became the standard, starts setup
    /// from the standard instead of from the nearest tick.
    static func startingCanvas(saved: PiPCanvasConfiguration) -> PiPCanvasConfiguration {
        let offered = PiPCanvasConfiguration.presets.contains {
            $0.width == saved.width && $0.height == saved.height
        }
        return offered ? saved : .standard
    }

    func next(after step: SetupStep) -> SetupStep {
        switch step {
        case .welcome:
            return .accountWarning
        case .accountWarning:
            // A phone known to have no Island goes straight to the floating window.
            // Setup asks nothing about Glyphs: the Glyph list is added in Settings.
            return hasIsland == false ? .floatingWindow : .dynamicIsland
        case .dynamicIsland:
            return usesIsland && !activitiesEnabled ? .liveActivities : .floatingWindow
        case .liveActivities:
            return .floatingWindow
        case .floatingWindow, .done:
            return .done
        }
    }
}
