import Foundation
import Testing

@Suite("Control Center start request")
struct ControlStartRequestTests {
    typealias AppState = ControlStartRequest.AppState

    static let idle = AppState(isActive: true, isSettingUp: false, capture: .idle)
    static let launching = AppState(isActive: false, isSettingUp: false, capture: .idle)

    @Test("Nothing happens until the button asks")
    func nothingAsked() {
        var request = ControlStartRequest()
        #expect(request.resolve(Self.idle, at: 10) == .none)
        #expect(!request.isPending)
    }

    @Test("A cold launch keeps the request until the app is in front, then starts once")
    func coldLaunch() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        // The intent runs before the home screen is up and active.
        #expect(request.resolve(Self.launching, at: 0.1) == .wait)
        #expect(request.resolve(Self.launching, at: 0.8) == .wait)
        #expect(request.isPending)
        #expect(request.resolve(Self.idle, at: 1.2) == .start)
        #expect(!request.isPending)
        // Later activations, such as the sheet closing, start nothing more.
        #expect(request.resolve(Self.idle, at: 1.5) == .none)
        #expect(request.resolve(Self.idle, at: 40) == .none)
    }

    @Test("A warm launch starts as soon as the app is in front")
    func warmLaunch() {
        var request = ControlStartRequest()
        request.receive(at: 100)
        #expect(request.resolve(Self.idle, at: 100.05) == .start)
        #expect(!request.isPending)
    }

    @Test("Running or stopping capture only brings the app forward")
    func alreadyRunning() {
        var request = ControlStartRequest()
        request.receive(at: 5)
        let running = AppState(isActive: true, isSettingUp: false, capture: .running)
        #expect(request.resolve(running, at: 5.1) == .skip(.running))
        #expect(!request.isPending, "the request is answered, not kept for after Stop")
        #expect(request.resolve(Self.idle, at: 60) == .none)
    }

    @Test("While the sharing sheet is waiting, a tap asks for no second one")
    func waitingForSharing() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        #expect(request.resolve(Self.idle, at: 0.1) == .start)
        let waiting = AppState(isActive: true, isSettingUp: false, capture: .waitingForSharing)
        request.receive(at: 5)
        #expect(request.resolve(waiting, at: 5.1) == .skip(.waitingForSharing))
        #expect(!request.isPending)
    }

    @Test("Taps before the app looks are one request")
    func tapsBeforeLaunchMerge() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        request.receive(at: 0.2)
        request.receive(at: 0.3)
        #expect(request.resolve(Self.idle, at: 0.5) == .start)
        #expect(request.resolve(Self.idle, at: 0.6) == .none)
    }

    @Test("A tap right after a start is ignored, a later one starts again")
    func repeatedTaps() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        #expect(request.resolve(Self.idle, at: 0.1) == .start)
        // Start could not run, or the sheet closed at once: the engine is idle.
        request.receive(at: 0.9)
        #expect(request.resolve(Self.idle, at: 1.0) == .skip(.repeated))
        request.receive(at: 0.1 + ControlStartRequest.repeatInterval + 0.5)
        #expect(request.resolve(Self.idle, at: 0.1 + ControlStartRequest.repeatInterval + 0.6) == .start)
    }

    @Test("Unfinished setup is shown as it is, and the request is not kept for after it")
    func setupNotFinished() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        let settingUp = AppState(isActive: true, isSettingUp: true, capture: .idle)
        #expect(request.resolve(settingUp, at: 0.2) == .skip(.setup))
        #expect(!request.isPending)
        // Finishing setup does not start capture behind the player's back.
        #expect(request.resolve(Self.idle, at: 20) == .none)
    }

    @Test("Setup is checked only once the app is in front")
    func setupAfterLaunch() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        let launchingIntoSetup = AppState(isActive: false, isSettingUp: true, capture: .idle)
        #expect(request.resolve(launchingIntoSetup, at: 0.1) == .wait)
        let settingUp = AppState(isActive: true, isSettingUp: true, capture: .idle)
        #expect(request.resolve(settingUp, at: 0.5) == .skip(.setup))
    }

    @Test("A request the app never came forward for expires")
    func expiry() {
        var request = ControlStartRequest()
        request.receive(at: 0)
        #expect(request.resolve(Self.launching, at: 10) == .wait)
        #expect(request.resolve(Self.idle, at: ControlStartRequest.patience + 1) == .skip(.expired))
        #expect(!request.isPending)
        #expect(request.resolve(Self.idle, at: ControlStartRequest.patience + 2) == .none)
    }
}
