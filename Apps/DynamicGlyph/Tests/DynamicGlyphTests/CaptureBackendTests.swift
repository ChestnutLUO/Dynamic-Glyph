import Testing

@Suite("Capture backend failures")
struct CaptureBackendFailureTests {
    @Test("Before capture runs, every failure abandons the start")
    func beforeCapture() {
        let all: [CaptureBackendFailure] = [.consentCancelled, .consentFailed, .startFailed, .interrupted,
                                            .stoppedFromControlCenter]
        #expect(all.allSatisfy { $0.endsSession(whileCapturing: false) })
    }

    @Test("While capture runs, only the capture itself failing ends the session")
    func whileCapturing() {
        #expect(!CaptureBackendFailure.consentCancelled.endsSession(whileCapturing: true))
        #expect(!CaptureBackendFailure.consentFailed.endsSession(whileCapturing: true))
        #expect(CaptureBackendFailure.startFailed.endsSession(whileCapturing: true))
        #expect(CaptureBackendFailure.interrupted.endsSession(whileCapturing: true))
        #expect(CaptureBackendFailure.stoppedFromControlCenter.endsSession(whileCapturing: true))
    }

    @Test("A stop from the Control Center switch ends the capture quietly; an interruption says sharing stopped")
    func quietControlCenterStop() {
        #expect(CaptureBackendFailure.stoppedFromControlCenter.problem == nil)
        #expect(CaptureBackendFailure.stoppedFromControlCenter.endsRunningCapture)
        #expect(CaptureBackendFailure.interrupted.problem
                == String(localized: "Screen sharing stopped. Tap Start to pick up again.",
                          comment: "Shown when iOS or the player ends screen sharing."))
        #expect(CaptureBackendFailure.interrupted.endsRunningCapture)
        #expect(CaptureBackendFailure.consentCancelled.problem == nil)
        #expect(!CaptureBackendFailure.consentCancelled.endsRunningCapture)
        #expect(CaptureBackendFailure.consentFailed.problem != nil)
        #expect(CaptureBackendFailure.startFailed.problem != nil)
        #expect(!CaptureBackendFailure.startFailed.endsRunningCapture, "never began")
    }

    @Test("A broadcast the extension ended on request was the Control Center switch's stop; any other end interrupts")
    func broadcastEnded() {
        // Attached, the app never asks itself: its Stop detaches first.
        #expect(CaptureBackendFailure.broadcastEnded(.stopRequested) == .stoppedFromControlCenter)
        #expect(CaptureBackendFailure.broadcastEnded(.broadcastFinished) == .interrupted)
        #expect(CaptureBackendFailure.broadcastEnded(FrameRingEndReason.none) == .interrupted, "killed extension")
        #expect(CaptureBackendFailure.broadcastEnded(nil) == .interrupted, "unknown reason")
    }
}

@Suite("Capture request callbacks")
@MainActor
struct CaptureRequestTests {
    @Test("Stop silences an already queued successful startup")
    func stopBeforeStartupCompletes() async {
        let delegate = CaptureDelegateSpy()
        let request = CaptureRequest(delegate: delegate)
        // This task cannot run until the current MainActor turn yields.
        let completion = Task { @MainActor in request.didStart() }
        request.invalidate() // The synchronous part of backend.stop().
        await completion.value
        #expect(delegate.starts == 0)
        #expect(delegate.notes.isEmpty)
        #expect(delegate.failures.isEmpty)
    }

    @Test("Reset silences queued consent cancellation and failure",
          arguments: [CaptureBackendFailure.consentCancelled, .consentFailed])
    func resetBeforeConsentCallback(_ failure: CaptureBackendFailure) async {
        let delegate = CaptureDelegateSpy()
        let request = CaptureRequest(delegate: delegate)
        let callback = Task { @MainActor in
            request.fail(failure, message: "old callback", status: "old status")
        }
        request.invalidate()
        await callback.value
        #expect(delegate.notes.isEmpty)
        #expect(delegate.failures.isEmpty)
    }

    @Test("Old consent and startup callbacks cannot affect a new request")
    func replacementRequest() async {
        let delegate = CaptureDelegateSpy()
        let old = CaptureRequest(delegate: delegate)
        var filtersAccepted = 0
        let queued = Task { @MainActor in
            old.perform { filtersAccepted += 1 }
            old.fail(.consentCancelled, message: "old cancellation", status: "cancelled")
            old.fail(.consentFailed, message: "old failure", status: "failed")
            old.fail(.startFailed, message: "old start failure", status: "failed")
            old.didStart()
        }
        old.invalidate()
        let current = CaptureRequest(delegate: delegate)
        await queued.value
        #expect(filtersAccepted == 0)
        #expect(delegate.starts == 0)
        #expect(delegate.notes.isEmpty)
        #expect(delegate.failures.isEmpty)
        #expect(current.isActive)

        current.perform { filtersAccepted += 1 }
        current.didStart()
        #expect(filtersAccepted == 1)
        #expect(delegate.starts == 1)
    }

    @Test("Current consent failures still deliver their status and failure")
    func currentFailure() {
        let delegate = CaptureDelegateSpy()
        let request = CaptureRequest(delegate: delegate)
        request.fail(.consentCancelled, message: "didCancelFor", status: "picker cancelled")
        #expect(delegate.notes == ["didCancelFor:picker cancelled"])
        #expect(delegate.failures == [.consentCancelled])
    }
}

@MainActor
private final class CaptureDelegateSpy: CaptureBackendDelegate {
    var starts = 0
    var notes: [String] = []
    var failures: [CaptureBackendFailure] = []

    func captureBackendWillStart() -> CaptureSinks? { nil }
    func captureBackendDidStart() { starts += 1 }
    func captureBackend(didFail failure: CaptureBackendFailure) { failures.append(failure) }
    func captureBackendNote(_ message: String, status: String?) {
        notes.append("\(message):\(status ?? "")")
    }
}
