// ScreenCaptureKit is not in the iOS Simulator SDK; the simulator build
// falls back to ReplayKitBackend so the app can be previewed there.
#if canImport(ScreenCaptureKit)
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Capture through ScreenCaptureKit, which iOS offers from iOS 27.
///
/// On iOS the picker is the only source of an `SCContentFilter`: every
/// `SCContentFilter` initialiser is `API_UNAVAILABLE(ios)`, and
/// `SCShareableContent` -- the type that enumerates displays, windows and
/// applications -- is unavailable too. The filter arrives as a read-only token
/// exposing only `style`, `pointPixelScale` and `contentRect`. There is no
/// supported way to aim capture at a particular app.
@available(iOS 27, *)
@MainActor
final class ScreenCaptureBackend: NSObject, CaptureBackend {
    weak var delegate: CaptureBackendDelegate?
    /// The `screen-capture` background mode keeps the app running without it.
    let requiresFloatingWindow = false

    private var request: CaptureRequest?
    private var consentObserver: ScreenCaptureConsentObserver?
    private var stream: SCStream?
    /// The stream is not relied on to keep its outputs alive.
    private var screenOutput: ScreenCaptureFrameOutput?
    private var audioOutput: RecordingAudioOutput?
    private let audioQueue = DispatchQueue(label: "spikeB.audio", qos: .userInitiated)

    var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }
    var hasSession: Bool { stream != nil }

    func requestConsent() {
        guard request == nil else { return }
        let request = CaptureRequest(delegate: delegate)
        self.request = request
        let observer = ScreenCaptureConsentObserver(request: request) { [weak self] filter in
            self?.delegate?.captureBackendNote("didUpdateWith filter", status: nil)
            self?.start(with: filter)
        }
        consentObserver = observer
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.add(observer)
        picker.isActive = true
        // `.display` is the whole-screen style. `.application` exists in the
        // enum but is API_UNAVAILABLE(ios), so display or window are the only
        // choices here.
        picker.present(using: .display)
        delegate?.captureBackendNote("picker presented using .display",
                                     status: "picker presented -- choose the whole display")
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        let stopping = stream
        let stoppingAudio = audioOutput
        forget()
        return Task {
            try? await stopping?.stopCapture()
            withExtendedLifetime(stoppingAudio) {}
        }
    }

    func reset() {
        // A start given up on while its stream was starting: the stream is
        // stopped here or, if its start is still in flight, when it finishes.
        let abandoned = stream
        forget()
        if let abandoned { Task { try? await abandoned.stopCapture() } }
    }

    private func forget() {
        // Invalidate before unregistering: callbacks may already be waiting
        // on MainActor, or the framework may still hold the old observer.
        request?.invalidate()
        request = nil
        stream = nil
        screenOutput = nil
        audioOutput = nil
        SCContentSharingPicker.shared.isActive = false
        if let consentObserver { SCContentSharingPicker.shared.remove(consentObserver) }
        consentObserver = nil
    }

    private func start(with filter: SCContentFilter) {
        guard let request, request.isActive else { return }
        guard stream == nil else {
            delegate?.captureBackendNote("Ignoring filter update while a stream is already active", status: nil)
            return
        }
        guard let sinks = delegate?.captureBackendWillStart() else { return }
        let config = SCStreamConfiguration()
        // Width and height are settable on iOS. `minimumFrameInterval` and
        // `pixelFormat` are NOT (API_UNAVAILABLE(ios)) -- so the frame rate
        // cannot be requested and has to be handled by dropping, and the pixel
        // format is whatever the system decides. Both are logged rather than
        // assumed.
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(rect.width * scale / 2)
        config.height = Int(rect.height * scale / 2)
        // Sound is captured only when a recording that wants it actually started.
        let capturesSound = sinks.soundRecorder != nil
        config.capturesAudio = capturesSound
        if capturesSound {
            config.sampleRate = DebugRecordingLimits.audioSampleRate
            config.channelCount = DebugRecordingLimits.audioChannelCount
            config.excludesCurrentProcessAudio = true
        }
        // iOS has no captureMicrophone setter. The picker hides its microphone
        // control, and the only sound captured is the device's, for a Photos
        // recording the player asked to include it in.
        delegate?.captureBackendNote(capturesSound
                                     ? "capture audio enabled for the Photos recording; microphone not requested"
                                     : "capture audio disabled; microphone output not requested", status: nil)
        delegate?.captureBackendNote(String(format: "filter style=%d contentRect=%.0fx%.0f scale=%.2f -> %dx%d",
                                            filter.style.rawValue, rect.width, rect.height,
                                            filter.pointPixelScale, config.width, config.height), status: nil)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            // One screen receiver fans out telemetry and recognition. In the
            // first field run the separate telemetry receiver produced no rows.
            let screen = ScreenCaptureFrameOutput(recognition: sinks.recognition)
            screenOutput = screen
            try newStream.addStreamOutput(screen, type: .screen, sampleHandlerQueue: sinks.recognitionQueue)
            if let recorder = sinks.soundRecorder {
                let sound = RecordingAudioOutput(recorder: recorder)
                audioOutput = sound
                try newStream.addStreamOutput(sound, type: .audio, sampleHandlerQueue: audioQueue)
            }
        } catch {
            delegate?.captureBackendNote("addStreamOutput FAILED \(error)",
                                         status: "addStreamOutput failed: \(error.localizedDescription)")
            delegate?.captureBackend(didFail: .startFailed)
            return
        }
        stream = newStream

        Task {
            guard request.isActive else { return }
            do {
                try await newStream.startCapture()
                guard self.stream === newStream else {
                    try? await newStream.stopCapture()
                    return
                }
                request.didStart()
            } catch {
                guard self.stream === newStream else { return }
                request.fail(.startFailed, message: "startCapture FAILED \(error)",
                             status: "startCapture failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Picker observer

@available(iOS 27, *)
private final class ScreenCaptureConsentObserver: NSObject, SCContentSharingPickerObserver {
    // A fresh observer per request captures its identity before any actor hop.
    // Reading the backend's current request inside the task would let an old
    // callback cancel or start a newer session.
    private let request: CaptureRequest
    private let didSelect: @MainActor (SCContentFilter) -> Void

    init(request: CaptureRequest, didSelect: @escaping @MainActor (SCContentFilter) -> Void) {
        self.request = request
        self.didSelect = didSelect
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        Task { @MainActor [request, didSelect] in
            request.perform { didSelect(filter) }
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [request] in
            request.fail(.consentCancelled, message: "didCancelFor", status: "picker cancelled")
        }
    }

    /// If iOS refuses to vend foreign content at all, the error surfaces here.
    /// Log it verbatim -- it is the answer to the spike's first question.
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let description = String(describing: error)
        Task { @MainActor [request] in
            request.fail(.consentFailed, message: "startDidFailWithError \(description)",
                         status: "picker start failed")
        }
    }
}

// MARK: - Stream delegate

@available(iOS 27, *)
extension ScreenCaptureBackend: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let description = String(describing: error)
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.delegate?.captureBackendNote("didStopWithError \(description)", status: "stream stopped with error")
            self.delegate?.captureBackend(didFail: .interrupted)
        }
    }
}

#endif
