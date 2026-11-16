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

    /// Whether a run of lit columns is an object at the band's left or right
    /// edge, such as a tucked window's tab, and no part of a notice box.
    ///
    /// A box is centred within w/16 and wider than w/5 but narrower than
    /// 4w/5. So it spans the centre column and stays about 0.06875 of the
    /// width from either edge (42 of 603 columns). A run that reaches within
    /// w/20 of an edge, which leaves about 0.01875 of the width spare, holds
    /// something that is no part of a box. Staying on that side of the
    /// centre column, it holds no whole box either.
    static func isEdgeObject(_ run: ClosedRange<Int>, width w: Int) -> Bool {
        let margin = w / 20
        return (run.lowerBound < margin && 2 * run.upperBound < w - 1)
            || (run.upperBound >= w - margin && 2 * run.lowerBound > w - 1)
    }

    public func detect(_ pixels: LuminanceImage) -> Box? {
        let w = pixels.width, h = pixels.height
        // Each column's first and last lit row, -1 when it has none.
        var firstRows = [Int](repeating: -1, count: w), lastRows = [Int](repeating: -1, count: w)
        for y in 0..<h {
            for x in 0..<w where pixels[x, y] > 45 {
                if firstRows[x] < 0 { firstRows[x] = y }
                lastRows[x] = y
            }
        }
        // The bounding box of every lit pixel, less objects at the edges.
        var left = w, right = 0, top = h, bottom = 0
        var x = 0
        while x < w {
            guard lastRows[x] >= 0 else { x += 1; continue }
            var end = x
            while end + 1 < w, lastRows[end + 1] >= 0 { end += 1 }
            if !Self.isEdgeObject(x...end, width: w) {
                left = min(left, x); right = max(right, end)
                for column in x...end {
                    top = min(top, firstRows[column]); bottom = max(bottom, lastRows[column])
                }
            }
            x = end + 1
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
    /// The text logic a read uses: the Swift `CommandNoticeParser` and
    /// `GameText`, or a logic arm's (`RecognitionLogicSet`), made per read.
    public struct Logic: Sendable {
        public var parser: @Sendable (GameLanguage) -> any CommandNoticeParsing
        public var text: @Sendable (GameLanguage) -> any GameTextMatching

        public init(parser: @escaping @Sendable (GameLanguage) -> any CommandNoticeParsing,
                    text: @escaping @Sendable (GameLanguage) -> any GameTextMatching) {
            self.parser = parser
            self.text = text
        }

        public static let swift = Logic(parser: { CommandNoticeParser(language: $0) }, text: { GameText($0) })
    }

    public let language: GameLanguage
    private let logic: Logic
    public init(language: GameLanguage = .english, logic: Logic = .swift) {
        self.language = language
        self.logic = logic
    }

    public func read(_ frame: CommandNoticeFrame) throws -> CommandNoticeReading {
        guard frame.isMode else { return logic.parser(language).read(try lines(frame, fast: false)) }
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
        let text = logic.text(language)
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
        guard beginFrame(at: time) else { return }
        let pixels = try ImageDecoder.decode(band)
        guard let current = CommandNoticeDetector().detect(pixels) else {
            // An overlay or unreadable box is not an empty command window.
            noBox(at: time, obscured: (pixels.height / 5..<pixels.height).contains { y in
                (0..<pixels.width).filter { pixels[$0, y] > 45 }.count > pixels.width / 8
            })
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

    /// `observe(band:)` for a band with no grey level above 45, known from
    /// the capture's planes without a render (`RegionGate.bandIsEmpty`): no
    /// box, and nothing covering the band.
    public func observeEmptyBand(at time: Double) {
        guard beginFrame(at: time) else { return }
        noBox(at: time, obscured: false)
    }

    /// A band frame's start: a repeated or non-finite time is ignored, an
    /// earlier one cancels, and the first frame opens the window.
    private func beginFrame(at time: Double) -> Bool {
        guard time.isFinite, time != lastFrameTime else { return false }
        if time < lastFrameTime { cancel() }
        lastFrameTime = time
        if !windowOpened {
            if let droneAt, time >= droneAt, time - droneAt <= 5 { observer.setMode(.drone) }
            droneAt = nil; windowOpened = true; windowStartedAt = time
            observer.markObserved()
        }
        return true
    }

    private func noBox(at time: Double, obscured: Bool) {
        box = nil; noticeID = nil; samples = 0
        if obscured {
            if !missing { observer.loseCoverage(at: time); missing = true }
        } else { missing = false }
    }

    /// `observeMode`'s first guard, which changes nothing: no command window
    /// open, no item panel, and a second since the last footer candidate
    /// that was read or reused.
    public func modeProbeDue(at time: Double, panelShowing: Bool = false) -> Bool {
        !windowOpened && !panelShowing && time - lastModeProbe >= 1
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
        guard modeProbeDue(at: time, panelShowing: panelShowing) else { return false }
        return probeMode(try DroneFooterProbe.textPixels(in: image), at: time) { DroneFooterProbe.readCrop(image) }
    }

    /// `observeMode(in:)` with the footer's region alone, rendered on its
    /// own: the same pixels, so the same decisions and the same read crop.
    @discardableResult
    public func observeMode(footer: CGImage, frameWidth: Int, frameHeight: Int, at time: Double,
                            panelShowing: Bool = false) throws -> Bool {
        guard modeProbeDue(at: time, panelShowing: panelShowing) else { return false }
        let pixels = try DroneFooterProbe.textPixels(region: footer, frameWidth: frameWidth, frameHeight: frameHeight)
        return probeMode(pixels, at: time) { DroneFooterProbe.readCrop(region: footer) }
    }

    private func probeMode(_ pixels: ColorImage, at time: Double, readCrop: () -> CGImage?) -> Bool {
        guard let candidate = DroneFooterProbe.candidate(pixels) else { return false }
        modeCandidates += 1
        if let droneSignature, DroneFooterProbe.matches(candidate.signature, droneSignature) {
            lastModeProbe = time
            modeReuses += 1
            droneAt = time
            return true
        }
        guard queue.count < 16, let crop = readCrop() else { return true }
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
    public static func read(_ frame: CommandNoticeFrame, languages memory: any GameLanguageRemembering,
                            logic: Logic = .swift) throws -> CommandNoticeReading {
        let current = memory.current
        let reading = try CommandNoticeReader(language: current, logic: logic).read(frame)
        guard reading.notice == nil else {
            // NO KEY is English in Japanese games too, so an English notice
            // confirms nothing.
            if current != .english, reading.language == current.rawValue { memory.found(current) }
            return reading
        }
        for language in memory.alternatives(at: frame.sourceTime, on: .notice) {
            let other = try CommandNoticeReader(language: language, logic: logic).read(frame)
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
