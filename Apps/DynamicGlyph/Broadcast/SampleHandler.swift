import ReplayKit

/// The broadcast upload extension's entry point: frames go to the app through
/// the ring; sound is not captured on this path.
final class SampleHandler: RPBroadcastSampleHandler {
    private var publisher: FramePublisher?

    /// The Control Center switch reads the ring, so it is reloaded whenever
    /// the ring says the broadcast started or ended.
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            publisher = try FramePublisher { [weak self] in
                // Asked to stop by the app or the Control Center switch. The
                // ring already says so, and ending may end this process
                // before broadcastFinished.
                ControlChannel.reload()
                self?.finishBroadcastWithError(NSError(domain: "org.szres.DynamicGlyph.broadcast", code: 1,
                                                       userInfo: [NSLocalizedDescriptionKey: Self.stoppedByApp]))
            }
            ControlChannel.reload()
        } catch {
            finishBroadcastWithError(error)
        }
    }

    override func broadcastPaused() { publisher?.pause() }
    override func broadcastResumed() { publisher?.resume() }
    override func broadcastFinished() {
        publisher?.finish()
        ControlChannel.reload()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        publisher?.offer(sampleBuffer)
    }

    /// iOS shows this when the app ends the broadcast: an extension can only
    /// end one by reporting an error.
    private static let stoppedByApp = String(
        localized: "Dynamic Glyph stopped watching the screen.",
        comment: "Shown by iOS when the player stops Dynamic Glyph and the screen broadcast ends.")
}
