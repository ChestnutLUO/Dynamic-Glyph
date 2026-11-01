import AVFoundation
import AVKit
import Combine
import Foundation
import UIKit
import GlyphRecognition

/// Owns the Picture in Picture session that shows the Glyph display while
/// Ingress is in front.
///
/// Rendering inline does not activate an audio session. A mixing playback
/// session is acquired only when PiP is requested and released when it closes.
/// Protected playback during screen capture still needs a device check.
///
/// The display layer can be marked as protected from capture, asking the
/// system to leave its pixels out of screenshots and screen recordings.
/// Whether that reaches the floating window, and this app's own capture of
/// the screen, needs a device check.
///
/// While the floating window is on, leaving the app always opens it. Closing
/// it in the game hides the display and leaves capture running; it stays
/// closed until the player next comes back to the app and leaves again. The
/// app's Stop Session stops everything.
@MainActor
final class GlyphPiPController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isActive = false
    @Published private(set) var isOpening = false
    @Published private(set) var isPossible = false
    @Published private(set) var status = "Picture in Picture off"
    /// Localized recovery message shown beside the manual Show button.
    @Published private(set) var openingProblem: String?
    @Published private(set) var stats = GlyphPiPRenderLoop.Stats()
    /// The user closed the window; automatic restart stays off until asked.
    @Published private(set) var wasDismissedByUser = false
    @Published private(set) var renderSize: String?
    @Published private(set) var ownsAudioSession = false
    /// Field-test preference: uses an undocumented API, not for App Store builds.
    @Published private(set) var hidesPlaybackControls =
        (UserDefaults.standard.object(forKey: "pip.hidePlaybackControls") as? NSNumber)?.boolValue ?? true
    @Published private(set) var playbackControlsNote: String?
    @Published private(set) var preventsCapture = AppPreferences().protectsFloatingWindowFromCapture
    @Published private(set) var canvas = PiPCanvasConfiguration(
        width: (UserDefaults.standard.object(forKey: "pip.canvas.width") as? NSNumber)?.intValue
            ?? PiPCanvasConfiguration.standard.width,
        height: (UserDefaults.standard.object(forKey: "pip.canvas.height") as? NSNumber)?.intValue
            ?? PiPCanvasConfiguration.standard.height,
        resolution: (UserDefaults.standard.object(forKey: "pip.canvas.resolution") as? NSNumber)?.intValue
            ?? PiPCanvasConfiguration.standard.resolution)

    let layer = AVSampleBufferDisplayLayer()
    var onEvent: ((String) -> Void)?

    private var controller: AVPictureInPictureController?
    private var originalControlsStyle: NSNumber?
    private var renderLoop: GlyphPiPRenderLoop?
    private var possibleObservation: NSKeyValueObservation?
    private var statsTimer: Timer?
    private var latest: GlyphDisplaySnapshot
    private var startRequest = PiPStartRequest()
    private var audioInterruptionObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?

    override init() {
        latest = .waiting(sessionID: CaptureSessionID(rawValue: 0), liveness: .starting,
                          acceptance: .provisionalOnly(reason: String(localized: "capture not started",
                                                                      comment: "Reason shown after 'Getting ready ·'.")))
        super.init()
        layer.videoGravity = .resizeAspect
        layer.preventsCapture = preventsCapture
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Starts rendering and prepares the controller. Does not open the window:
    /// the layer has to be live and inline first, and starting two pieces of
    /// system UI at once is exactly the ordering problem to avoid while the
    /// capture consent sheet may still be up.
    ///
    /// `collectsStats` samples the render loop's counters for the Diagnostics
    /// page twice a second; without session logs nothing reads them.
    func start(table: GlyphTable?, snapshot: GlyphDisplaySnapshot, collectsStats: Bool) {
        guard !isRunning else { return }
        guard isSupported else {
            status = "Picture in Picture is not supported on this device"
            log("PiP unsupported")
            return
        }
        openingProblem = nil
        latest = snapshot
        ReadingModeSignal.shared.applyPreference()
        let loop = GlyphPiPRenderLoop(layer: layer, table: table, initial: snapshot, canvas: canvas,
                                      readingMode: .shared)
        loop.onEvent = { [weak self] message in self?.log(message) }
        loop.start()
        renderLoop = loop

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
        originalControlsStyle = nil
        applyPlaybackControlsPreference()
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.controller === observed else { return }
                self.isPossible = possible
                self.log("readiness=\(possible); \(self.previewDiagnostics)")
                self.startPendingWindowIfPossible()
            }
        }

        isRunning = true
        wasDismissedByUser = false
        renderSize = nil
        status = "Rendering · open Picture in Picture when ready"
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in
                    guard let self else { return }
                    self.log("audio interruption type=\(type.map(String.init) ?? "unknown")")
                    if type == AVAudioSession.InterruptionType.began.rawValue {
                        self.ownsAudioSession = false
                    }
                    // Do not repeatedly reactivate over another media app.
                }
            }
        stats = .init()
        if collectsStats { startStatsTimer() }
        log("render loop started; capture protection \(preventsCapture ? "on" : "off")")
        // Armed only now that the renderer runs, after the capture consent
        // picker has gone, so the picker cannot pull the app into Picture in
        // Picture.
        applyAutomaticFromInline(true)
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rearmForNextLeave() }
            }
    }

    /// Back in the app, the next departure opens the window again, including
    /// after the player closed it in the game.
    private func rearmForNextLeave() {
        guard isRunning, controller != nil, !isActive, !isOpening, !isAutomaticFromInline else { return }
        if applyAutomaticFromInline(true) { wasDismissedByUser = false }
    }

    func update(_ snapshot: GlyphDisplaySnapshot) {
        latest = snapshot
        renderLoop?.update(snapshot)
    }

    func applyCanvas(_ configuration: PiPCanvasConfiguration) {
        canvas = configuration
        UserDefaults.standard.set(canvas.width, forKey: "pip.canvas.width")
        UserDefaults.standard.set(canvas.height, forKey: "pip.canvas.height")
        UserDefaults.standard.set(canvas.resolution, forKey: "pip.canvas.resolution")
        renderLoop?.updateCanvas(canvas)
        log("canvas requested: \(canvas.pixelWidth)x\(canvas.pixelHeight), aspect=\(canvas.aspectRatio)")
    }

    /// Applies at once, to an open window as well as the next one.
    func setPreventsCapture(_ enabled: Bool) {
        preventsCapture = enabled
        AppPreferences().protectsFloatingWindowFromCapture = enabled
        layer.preventsCapture = enabled
        log("capture protection \(enabled ? "on" : "off")")
    }

    func setHidesPlaybackControls(_ hidden: Bool) {
        hidesPlaybackControls = hidden
        UserDefaults.standard.set(hidden, forKey: "pip.hidePlaybackControls")
        applyPlaybackControlsPreference()
    }

    private func applyPlaybackControlsPreference() {
        guard let controller else {
            playbackControlsNote = nil
            return
        }
        // Undocumented KVC workaround for this locally installed field app.
        // Check both accessors before using KVC, avoiding an undefined-key
        // exception if a future OS removes the property. Do not ship this in
        // an App Store target. Style 1 requests transport controls hidden;
        // style 2 (all controls, including dismissal) is deliberately unused.
        guard controller.responds(to: NSSelectorFromString("controlsStyle")),
              controller.responds(to: NSSelectorFromString("setControlsStyle:")) else {
            playbackControlsNote = Self.controlsUnavailableNote
            log("playback controls: undocumented accessors unavailable; using system controls")
            return
        }
        if originalControlsStyle == nil {
            originalControlsStyle = controller.value(forKey: "controlsStyle") as? NSNumber
        }
        guard let originalControlsStyle else {
            playbackControlsNote = Self.controlsUnavailableNote
            log("playback controls: unexpected style value; using system controls")
            return
        }
        let requested = hidesPlaybackControls ? NSNumber(value: 1) : originalControlsStyle
        controller.setValue(requested, forKey: "controlsStyle")
        playbackControlsNote = hidesPlaybackControls
            ? String(localized: "If the playback controls still show, close and reopen the floating window.",
                     comment: "Settings footer under 'Hide playback controls'.")
            : nil
        log("playback controls: requested style=\(requested), hide=\(hidesPlaybackControls)")
    }

    private static var controlsUnavailableNote: String {
        String(localized: "Hiding playback controls isn't available on this version of iOS.",
               comment: "Settings footer under 'Hide playback controls'.")
    }

    /// Opens the window now, if the system currently allows it.
    func openWindow() {
        guard controller != nil, !isActive, !isOpening else { return }
        guard activateAudioForPiP() else { return }
        wasDismissedByUser = false
        openingProblem = nil
        isOpening = true
        status = "Waiting for Picture in Picture to become ready"
        let requestID = startRequest.begin()
        log("Show requested; possible=\(isPossible); \(previewDiagnostics)")
        startPendingWindowIfPossible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let phase = self.startRequest.expire(requestID) else { return }
            self.isOpening = false
            // A late did-start callback must not revive an expired request.
            self.controller?.canStartPictureInPictureAutomaticallyFromInline = false
            self.controller?.stopPictureInPicture()
            self.openingProblem = Self.openingFailureMessage
            self.status = "Picture in Picture is unavailable. Try opening it again."
            self.releaseAudioSession()
            self.log("PiP start timed out during \(phase); \(self.previewDiagnostics)")
        }
    }

    func closeWindow() {
        startRequest.finish()
        openingProblem = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        isOpening = false
        controller?.stopPictureInPicture()
        // An issued start is cancelled by its did-start callback if it wins
        // the race with Stop. A request still waiting for readiness owns no PiP.
        if !isActive { releaseAudioSession() }
        wasDismissedByUser = true
        status = "Picture in Picture closed · capture still running"
    }

    @discardableResult
    private func applyAutomaticFromInline(_ enabled: Bool) -> Bool {
        guard controller != nil else { return false }
        if enabled, !activateAudioForPiP() { return false }
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if !enabled, !isActive, !isOpening { releaseAudioSession() }
        log("automatic-from-inline \(enabled ? "enabled" : "disabled")")
        return true
    }

    var isAutomaticFromInline: Bool {
        controller?.canStartPictureInPictureAutomaticallyFromInline ?? false
    }

    func stop() {
        guard isRunning else { return }
        startRequest.finish()
        openingProblem = nil
        isOpening = false
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
            self.audioInterruptionObserver = nil
        }
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
            self.becameActiveObserver = nil
        }
        statsTimer?.invalidate(); statsTimer = nil
        possibleObservation?.invalidate(); possibleObservation = nil
        renderLoop?.stop(); renderLoop = nil
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        originalControlsStyle = nil
        playbackControlsNote = nil
        isRunning = false
        isActive = false
        isPossible = false
        status = "Picture in Picture off"
        // Leaving the session active would keep the audio route claimed for no
        // reason once nothing is being displayed.
        releaseAudioSession()
        log("render loop stopped")
    }

    private func startPendingWindowIfPossible() {
        guard let controller, controller.isPictureInPicturePossible, startRequest.issue() else { return }
        log("issuing startPictureInPicture; awaiting delegate acknowledgment")
        controller.startPictureInPicture()
    }

    private static var openingFailureMessage: String {
        String(localized: "Couldn't open the floating window. Keep its preview visible and tap Show again.",
               comment: "Recovery message beside Show floating window when PiP fails or does not acknowledge the start request.")
    }

    private var previewDiagnostics: String {
        let counts = renderLoop?.snapshotStats() ?? .init()
        return "layerAttached=\(layer.superlayer != nil), bounds=\(layer.bounds), "
            + "enqueued=\(counts.enqueued), rendererFailures=\(counts.rendererFailures), "
            + "poolExhausted=\(counts.poolExhausted), captureProtection=\(preventsCapture)"
    }

    private func activateAudioForPiP() -> Bool {
        guard !ownsAudioSession else { return true }
        let session = AVAudioSession.sharedInstance()
        log("PiP requested; otherAudioPlaying=\(session.isOtherAudioPlaying)")
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            ownsAudioSession = true
            log("mixing audio session active; otherAudioPlaying=\(session.isOtherAudioPlaying)")
            return true
        } catch {
            openingProblem = Self.openingFailureMessage
            status = "Picture in Picture audio setup failed: \(error.localizedDescription)"
            log("audio session ERROR \(error)")
            return false
        }
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // Back to the category that cannot interrupt anyone. Leaving
            // `.playback` claimed after the window closes keeps this app in the
            // frame for silencing other audio for the rest of the session.
            try session.setCategory(.ambient)
            ownsAudioSession = false
            log("audio session released, category back to ambient")
        } catch { log("audio session release failed: \(error)") }
    }

    private func startStatsTimer() {
        // The loop deliberately never hops to the main actor per frame, so the
        // UI samples it instead.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stats = self.renderLoop?.snapshotStats() ?? .init()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    fileprivate func log(_ message: String) {
        onEvent?("pip: \(message)")
    }
}

// MARK: - Sample buffer playback delegate

extension GlyphPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        Task { @MainActor in self.log("setPlaying \(playing) — the feed continues either way") }
    }

    /// An infinite range marks this as a live stream, which suppresses the
    /// scrubber. A finite range makes PiP present transport controls and tear
    /// the session down when playback "ends".
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // The canvas is a fixed size and the system scales it. Logged so the
        // smallest window actually used can be checked against legibility
        // rather than assumed.
        let size = "\(newRenderSize.width)x\(newRenderSize.height)"
        let width = Double(newRenderSize.width)
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.renderSize = size
            // The corner radius is fixed in window points, so the canvas's
            // share of it changes with every resize.
            self.renderLoop?.updateWindowWidth(width)
            self.log("render size \(size), source=\(self.canvas.pixelWidth)x\(self.canvas.pixelHeight)")
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - Controller delegate

extension GlyphPiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            guard self.isOpening || controller.canStartPictureInPictureAutomaticallyFromInline else {
                controller.stopPictureInPicture()
                return
            }
            self.startRequest.finish()
            self.openingProblem = nil
            self.isOpening = false
            self.isActive = true
            self.status = "Picture in Picture open"
            self.log("did start")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let description = String(describing: error)
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.startRequest.finish()
            self.isOpening = false
            self.isActive = false
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            self.releaseAudioSession()
            self.openingProblem = Self.openingFailureMessage
            self.status = "Picture in Picture failed to start"
            self.log("FAILED to start: \(description)")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.startRequest.finish()
            self.isOpening = false
            self.isActive = false
            // With the app in front, the system closed the window because the
            // player came back, or the player hid it here: re-arm for the next
            // departure. In the background the player closed it in the game,
            // so it stays closed until they come back to the app.
            let closedInGame = UIApplication.shared.applicationState == .background
            self.controller?.canStartPictureInPictureAutomaticallyFromInline = false
            self.releaseAudioSession()
            self.log("did stop\(closedInGame ? " in the background" : "")")
            if closedInGame {
                self.wasDismissedByUser = true
                self.status = "Picture in Picture closed · capture still running"
            } else if self.openingProblem == nil {
                self.status = "Picture in Picture closed · opens again when you leave the app"
                self.rearmForNextLeave()
            }
        }
    }
}
