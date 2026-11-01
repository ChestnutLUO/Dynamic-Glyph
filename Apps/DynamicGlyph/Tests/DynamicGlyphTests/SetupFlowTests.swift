import Testing
import GlyphRecognition

@Suite("First-run setup")
struct SetupFlowTests {
    private func flow(_ detected: DynamicIslandSupport, reported: Bool? = nil, wantsIsland: Bool = false,
                      activitiesEnabled: Bool = true, floatingWindow: Bool = true) -> SetupFlow {
        SetupFlow(detected: detected, reportedIsland: reported, wantsIsland: wantsIsland,
                  activitiesEnabled: activitiesEnabled, floatingWindowEnabled: floatingWindow)
    }

    private func path(_ flow: SetupFlow) -> [SetupStep] {
        var steps: [SetupStep] = [.welcome]
        while steps.last != .done { steps.append(flow.next(after: steps.last!)) }
        return steps
    }

    private let window: [SetupStep] = [.floatingWindow]

    @Test("The account warning always follows the welcome")
    func warningFirst() {
        for detected: DynamicIslandSupport in [.hasIsland, .noIsland, .unknown] {
            #expect(Array(path(flow(detected)).prefix(2)) == [.welcome, .accountWarning])
        }
    }

    @Test("A phone with an Island asks about it; turning it on with Live Activities off adds the tip")
    func islandPaths() {
        #expect(path(flow(.hasIsland, wantsIsland: true))
                == [.welcome, .accountWarning, .dynamicIsland] + window + [.done])
        #expect(path(flow(.hasIsland, wantsIsland: true, activitiesEnabled: false))
                == [.welcome, .accountWarning, .dynamicIsland, .liveActivities] + window + [.done])
        #expect(path(flow(.hasIsland, wantsIsland: false, activitiesEnabled: false))
                == [.welcome, .accountWarning, .dynamicIsland] + window + [.done])
        #expect(flow(.hasIsland, wantsIsland: true).usesIsland)
    }

    @Test("Only an Island that can show the sequence lets the floating window be turned off")
    func islandOnly() {
        #expect(!flow(.hasIsland, wantsIsland: true, floatingWindow: false).showsFloatingWindow)
        #expect(flow(.hasIsland, wantsIsland: false, floatingWindow: false).showsFloatingWindow)
        #expect(flow(.noIsland, floatingWindow: false).showsFloatingWindow)
    }

    /// On iOS 18-26 the app keeps running over Ingress only while the window
    /// is open, so an Island that could show the sequence does not free it.
    @Test("Where the floating window is required, it cannot be turned off even with a working Island")
    func windowRequired() {
        var required = flow(.hasIsland, wantsIsland: true, activitiesEnabled: true, floatingWindow: false)
        #expect(required.canTurnOffFloatingWindow)
        required.floatingWindowRequired = true
        #expect(required.islandShowsSequence)
        #expect(!required.canTurnOffFloatingWindow)
        #expect(required.showsFloatingWindow)
    }

    /// Chosen with Live Activities off, the Island shows nothing: turning the
    /// floating window off there would finish setup with no display at all.
    @Test("An Island with Live Activities off keeps the floating window on")
    func islandWithoutLiveActivities() {
        let blocked = flow(.hasIsland, wantsIsland: true, activitiesEnabled: false, floatingWindow: false)
        #expect(blocked.usesIsland)
        #expect(!blocked.islandShowsSequence)
        #expect(!blocked.canTurnOffFloatingWindow)
        #expect(blocked.showsFloatingWindow)
        var allowed = blocked
        allowed.activitiesEnabled = true
        #expect(allowed.canTurnOffFloatingWindow)
        #expect(!allowed.showsFloatingWindow)
        // Every finished setup leaves at least one display able to show the sequence.
        for detected: DynamicIslandSupport in [.hasIsland, .noIsland, .unknown] {
            for wants in [false, true] {
                for enabled in [false, true] {
                    for window in [false, true] {
                        let f = flow(detected, wantsIsland: wants, activitiesEnabled: enabled, floatingWindow: window)
                        #expect(f.showsFloatingWindow || f.islandShowsSequence)
                    }
                }
            }
        }
    }

    @Test("A phone without an Island goes straight to the floating window")
    func noIsland() {
        #expect(path(flow(.noIsland, wantsIsland: true, activitiesEnabled: false))
                == [.welcome, .accountWarning] + window + [.done])
        #expect(!flow(.noIsland, wantsIsland: true).usesIsland)
    }

    @Test("An unknown model asks; the answer or a correction decides the rest")
    func unknownModel() {
        let unanswered = flow(.unknown, wantsIsland: true, activitiesEnabled: false)
        #expect(unanswered.hasIsland == nil)
        #expect(unanswered.next(after: .accountWarning) == .dynamicIsland)
        #expect(unanswered.next(after: .dynamicIsland) == .floatingWindow, "no answer never shows the tip")
        #expect(path(flow(.unknown, reported: false, wantsIsland: true, activitiesEnabled: false))
                == [.welcome, .accountWarning] + window + [.done])
        #expect(path(flow(.unknown, reported: true, wantsIsland: true, activitiesEnabled: false))
                == [.welcome, .accountWarning, .dynamicIsland, .liveActivities] + window + [.done])
        // The player's own answer outranks the model table.
        #expect(flow(.noIsland, reported: true).hasIsland == true)
        #expect(flow(.hasIsland, reported: false).hasIsland == false)
    }

    @Test("Setup starts at 10:1 at 2x unless the saved shape is one it offers")
    func startingCanvas() {
        #expect(PiPCanvasConfiguration.standard.aspectRatio == 10)
        // The pre-2026-09-23 default, and any shape set only in Settings.
        #expect(SetupFlow.startingCanvas(saved: PiPCanvasConfiguration(width: 384, height: 96, resolution: 1))
                == .standard)
        #expect(SetupFlow.startingCanvas(saved: PiPCanvasConfiguration(width: 400, height: 64, resolution: 3))
                == .standard)
        // A shape chosen in setup keeps its sharpness too.
        let chosen = PiPCanvasConfiguration(width: 640, height: 128, resolution: 3)
        #expect(SetupFlow.startingCanvas(saved: chosen) == chosen)
        #expect(SetupFlow.startingCanvas(saved: .standard) == .standard)
    }

    /// The Glyph list is added in Settings, so setup has no choice of what
    /// to read and no page asking for the list, whatever the phone.
    @Test("Setup never asks what to read or for a Glyph list: the window page leads to the end")
    func noGlyphPages() {
        #expect(path(flow(.noIsland)) == [.welcome, .accountWarning] + window + [.done])
        #expect(path(flow(.hasIsland, wantsIsland: true))
                == [.welcome, .accountWarning, .dynamicIsland] + window + [.done])
        for detected: DynamicIslandSupport in [.hasIsland, .noIsland, .unknown] {
            for wants in [false, true] {
                for enabled in [false, true] {
                    let f = flow(detected, wantsIsland: wants, activitiesEnabled: enabled)
                    #expect(f.next(after: .floatingWindow) == .done)
                    #expect(path(f).suffix(2) == [.floatingWindow, .done])
                }
            }
        }
    }

    @Test("Model identifiers: known Islands, known notches, older phones, and anything newer")
    func detection() {
        for id in ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone16,2", "iPhone17,3", "iPhone18,1", "iPhone18,4"] {
            #expect(DynamicIslandSupport.detect(modelIdentifier: id) == .hasIsland, "\(id)")
        }
        for id in ["iPhone17,5", "iPhone18,5", "iPhone14,7", "iPhone14,8", "iPhone14,6", "iPhone10,3",
                   "iPad13,1", "iPod9,1"] {
            #expect(DynamicIslandSupport.detect(modelIdentifier: id) == .noIsland, "\(id)")
        }
        for id in ["iPhone19,2", "iPhone19,4", "iPhone20,1", "arm64", "", "iPhone"] {
            #expect(DynamicIslandSupport.detect(modelIdentifier: id) == .unknown, "\(id)")
        }
        #expect(!DynamicIslandSupport.currentModelIdentifier.isEmpty)
    }
}
