import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// Only this small band is decoded on the frames skipped by Glyph analysis.
public struct CommandNoticeDetector {
    public static func band(width: Int, height: Int) -> CGRect {
        CGRect(x: 0, y: Double(height) * 0.16, width: Double(width), height: Double(height) * 0.13).integral
    }
    public struct Box {
        public let rect: CGRect
        public let signature: [UInt8]
    }
    public init() {}
    public func detect(_ image: CGImage) throws -> Box? { detect(try ImageDecoder.decode(image)) }

    public func detect(_ pixels: LuminanceImage) -> Box? {
        let w = pixels.width, h = pixels.height
        var left = w, right = 0, top = h, bottom = 0
        for y in 0..<h {
            for x in 0..<w where pixels[x, y] > 45 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        let width = right - left, height = bottom - top
        guard width > w / 5, width < w * 4 / 5, height > h / 4, height < h * 3 / 4,
              abs(left + right - w) < w / 16, top > 1, bottom < h - 2 else { return nil }
        // Require horizontal borders on both sides of the text, not just a
        // centered phrase on a result or a floating window.
        func border(_ start: Int, _ end: Int) -> Bool {
            (start...end).contains { y in
                let hits = (left...right).filter { pixels[$0, y] > 45 }.count
                return hits > width * 4 / 5
            }
        }
        guard border(top, min(bottom, top + 5)), border(max(top, bottom - 5), bottom) else { return nil }
        var signature: [UInt8] = []
        for y in 0..<16 {
            for x in 0..<64 {
                signature.append(pixels[left + x * width / 64, top + y * height / 16] > 140 ? 1 : 0)
            }
        }
        return Box(rect: CGRect(x: left - 1, y: top - 1, width: width + 3, height: height + 3), signature: signature)
    }
}

public struct CommandNoticeFrame: @unchecked Sendable {
    public let id: Int
    public let sourceTime: Double
    public let image: CGImage
    public let isMode: Bool
    public let generation: Int
    /// A drone footer candidate's yellow cells, to know the same footer
    /// again once a read confirms it. Nil for notices.
    public var signature: [UInt8]? = nil
}

public struct CommandNoticeReader: Sendable {
    public let language: GameLanguage
    public init(language: GameLanguage = .english) { self.language = language }
    public func read(_ frame: CommandNoticeFrame) throws -> CommandNoticeReading {
        guard frame.isMode else { return CommandNoticeParser(language: language).read(try lines(frame, fast: false)) }
        // The drone footer is one short fixed phrase in a small crop. Fast
        // recognition reads Latin script only, so it is tried for English
        // alone; a miss is read again accurately, so fast can only save.
        if !language.needsAccurateRecognition {
            let fast = droneReading(try lines(frame, fast: true), fast: true)
            if fast.notice != nil { return fast }
        }
        return droneReading(try lines(frame, fast: false), fast: false)
    }

    /// Whether the fast read alone finds the drone footer, for tests.
    public func readsDroneFooterFast(_ frame: CommandNoticeFrame) throws -> Bool {
        droneReading(try lines(frame, fast: true), fast: true).notice == .drone
    }

    private func lines(_ frame: CommandNoticeFrame, fast: Bool) throws -> [(String, Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = language.recognitionLanguages
        try TextReadProbe.measure(!frame.isMode ? .commandNotice : fast ? .droneFooterFast : .droneFooter) {
            try VNImageRequestHandler(cgImage: frame.image).perform([request])
        }
        return (request.results ?? []).compactMap {
            $0.topCandidates(1).first.map { ($0.string, Double($0.confidence)) }
        }
    }

    private func droneReading(_ lines: [(String, Double)], fast: Bool) -> CommandNoticeReading {
        let text = GameText(language)
        // Fast recognition scores coarsely: the real footer, read letter for
        // letter, comes back at 0.5 where accurate gives 1.0. The phrase must
        // match exactly either way, in a crop already gated on a centred
        // yellow label, so 0.5 is enough there.
        let floor = fast ? 0.5 : language == .english ? 0.95 : language.confidence.notice
        let found = lines.contains { text.isDroneFooter($0.0) && $0.1 >= floor }
        return .init(notice: found ? .drone : nil, confidence: found ? 1 : 0,
                     language: found ? language.rawValue : nil)
    }
}

/// Confined to the capture/replay queue. Keeps two distinct frames per changed
/// notice; OCR itself remains on the shared lane. No full-screen surfaces retained.
public final class CommandNoticeCapture {
    public private(set) var observer = CommandObservationSession()
    public private(set) var queue: [CommandNoticeFrame] = []
    private var box: CommandNoticeDetector.Box?
    private var noticeID: Int?
    private var samples = 0
    private var lastSampleTime = -Double.infinity
    /// Notice IDs whose crops expired before OCR, for the session log.
    private var dropped: [Int] = []
    private var lastFrameTime = -Double.infinity
    private var missing = false
    private var droneAt: Double?
    private var lastModeProbe = -Double.infinity
    /// The last footer a read confirmed as the drone view's: the same
    /// pixels again are the same footer, with no read. Kept for the capture.
    private var droneSignature: [UInt8]?
    /// Footer candidates, those queued for a read, and those recognized as
    /// the confirmed footer without one.
    public private(set) var modeCandidates = 0
    public private(set) var modeReads = 0
    public private(set) var modeReuses = 0
    private var windowOpened = false
    private var windowStartedAt: Double?
    private var generation = 0
    private var minimumGeneration = 0
    public init() {}

    /// The last observed band showed a notice box: a command is being entered.
    public var showsNotice: Bool { box != nil }

    /// Source time of the latest notice crop whose read found a known notice,
    /// in the command window now open: captured since the last bind, cancel
    /// or epoch break. Nil when it has none. Footer probes don't count.
    public private(set) var noticeReadAt: Double?

    public func observe(band: CGImage, at time: Double) throws {
        guard time.isFinite, time != lastFrameTime else { return }
        if time < lastFrameTime { cancel() }
        lastFrameTime = time
        if !windowOpened {
            if let droneAt, time >= droneAt, time - droneAt <= 5 { observer.setMode(.drone) }
            droneAt = nil; windowOpened = true; windowStartedAt = time
            observer.markObserved()
        }
        let pixels = try ImageDecoder.decode(band)
        guard let current = CommandNoticeDetector().detect(pixels) else {
            box = nil; noticeID = nil; samples = 0
            // An overlay or unreadable box is not an empty command window.
            let obscured = (pixels.height / 5..<pixels.height).contains { y in
                (0..<pixels.width).filter { pixels[$0, y] > 45 }.count > pixels.width / 8
            }
            if obscured {
                if !missing { observer.loseCoverage(at: time); missing = true }
            } else { missing = false }
            return
        }
        missing = false
        let difference = box.map { old in
            zip(old.signature, current.signature).filter { $0 != $1 }.count
        } ?? Int.max
        if box == nil || difference > 35 || abs((box?.rect.width ?? 0) - current.rect.width) > 3 {
            noticeID = observer.beginNotice(at: time); samples = 0; box = current
        }
        // The second sample waits for a settled frame: at 60 Hz the next frame
        // may still be mid-change, at 20 Hz it is the next sample anyway.
        guard samples < 2, samples == 0 || time - lastSampleTime >= 0.045,
              let id = noticeID, let crop = band.cropping(to: current.rect) else { return }
        samples += 1; lastSampleTime = time
        // A queue dropped before OCR still has an unresolved observer event.
        if queue.count >= 16 { queue.removeFirst() }
        queue.append(CommandNoticeFrame(id: id, sourceTime: time, image: crop, isMode: false, generation: generation))
    }

    /// Pixel-gated footer probe: yellow lettering is a candidate, never a
    /// drone verdict. One bounded OCR request on the label's small crop
    /// checks the fixed footer phrase; once one has, the same pixels are
    /// taken as that footer without another. `panelShowing` (an item drop
    /// panel on screen or its group still being read) skips the probe: the
    /// panel comes after a hack, and the next one's probe runs once it is
    /// gone. Returns whether the frame was a candidate.
    @discardableResult
    public func observeMode(in image: CGImage, at time: Double, panelShowing: Bool = false) throws -> Bool {
        guard !windowOpened, !panelShowing, time - lastModeProbe >= 1 else { return false }
        let rect = DroneFooterProbe.textRect(width: image.width, height: image.height)
        guard let candidate = DroneFooterProbe.candidate(try ImageDecoder.decodeColor(image, in: rect)) else {
            return false
        }
        modeCandidates += 1
        if let droneSignature, DroneFooterProbe.matches(candidate.signature, droneSignature) {
            lastModeProbe = time
            modeReuses += 1
            droneAt = time
            return true
        }
        guard queue.count < 16, let crop = DroneFooterProbe.readCrop(image) else { return true }
        lastModeProbe = time
        modeReads += 1
        queue.append(CommandNoticeFrame(id: 0, sourceTime: time, image: crop, isMode: true, generation: generation,
                                        signature: candidate.signature))
        return true
    }

    public func take(at time: Double) -> CommandNoticeFrame? {
        // An expired crop leaves its notice unread, so the result is uncertain.
        dropped += queue.filter { !$0.isMode && (time < $0.sourceTime || time - $0.sourceTime > 1) }.map(\.id)
        queue.removeAll { time < $0.sourceTime || time - $0.sourceTime > 1 }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Notices whose crops expired unread since the last call.
    public func takeDropped() -> [Int] {
        defer { dropped = [] }
        return dropped
    }

    /// A dropped frame, a discontinuity or a brief loss of the command screen:
    /// the window goes on, but a notice may have been missed.
    public func interrupt(at time: Double) {
        guard windowOpened else { return }
        observer.loseCoverage(at: time)
        box = nil; noticeID = nil; samples = 0
    }
    /// Discard old-epoch pending pixels/completions without cancelling the
    /// observer's uncertain window or any already bound hack summary.
    public func invalidateQueue(at time: Double) {
        if windowOpened { observer.beginEpoch(at: time) }
        generation += 1
        minimumGeneration = generation
        queue = []; box = nil; noticeID = nil; samples = 0; dropped = []
        lastFrameTime = -.infinity; lastSampleTime = -.infinity
        lastModeProbe = -.infinity; droneAt = nil
        missing = false; noticeReadAt = nil
    }
    public func accept(_ read: CommandNoticeReading, frame: CommandNoticeFrame) {
        guard frame.generation >= minimumGeneration else { return }
        if frame.isMode {
            // A read from before a bind still shows what the footer looks like.
            if read.notice == .drone, let signature = frame.signature { droneSignature = signature }
            guard frame.generation == generation else { return }
            if read.notice == .drone {
                if let start = windowStartedAt, frame.sourceTime <= start, start - frame.sourceTime <= 5 {
                    observer.setMode(.drone)
                } else if !windowOpened { droneAt = frame.sourceTime }
            }
            return
        }
        if read.notice != nil, frame.generation == generation {
            noticeReadAt = max(noticeReadAt ?? frame.sourceTime, frame.sourceTime)
        }
        observer.accept(read, id: frame.id, at: frame.sourceTime)
    }
    public func bind(hackID: Int) {
        observer.bind(hackID: hackID)
        generation += 1; box = nil; noticeID = nil; samples = 0
        windowOpened = false; windowStartedAt = nil; droneAt = nil; noticeReadAt = nil
    }
    public func cancel() {
        observer.cancel(); queue = []; box = nil; noticeID = nil; samples = 0; dropped = []
        missing = false; windowOpened = false; windowStartedAt = nil; droneAt = nil
        generation += 1; lastFrameTime = -.infinity; lastModeProbe = -.infinity; noticeReadAt = nil
    }
    public func summary(hackID: Int) -> HackCommandSummary { observer.summary(hackID: hackID) }
}

extension CommandNoticeReader {
    /// Reads a notice box in the capture's language, trying the others when
    /// the box holds no known phrase. The drone footer is tried the same way.
    public static func read(_ frame: CommandNoticeFrame, languages memory: GameLanguageMemory) throws -> CommandNoticeReading {
        let current = memory.current
        let reading = try CommandNoticeReader(language: current).read(frame)
        guard reading.notice == nil else {
            // NO KEY is English in Japanese games too, so an English notice
            // confirms nothing.
            if current != .english, reading.language == current.rawValue { memory.found(current) }
            return reading
        }
        for language in memory.alternatives(at: frame.sourceTime, on: .notice) {
            let other = try CommandNoticeReader(language: language).read(frame)
            // English phrases stay readable in every pack, so only a phrase of
            // this language's own names it.
            if other.notice != nil, other.language == language.rawValue {
                memory.found(language)
                return other
            }
        }
        return reading
    }
}
