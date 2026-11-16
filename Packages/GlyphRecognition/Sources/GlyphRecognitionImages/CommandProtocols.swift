import CoreGraphics
import GlyphRecognition

/// The command notices' objects as the app and the replay drive them, so
/// either arm, Swift or C++ (`GlyphRecognitionCxx`), can stand behind them.

/// One notice box's recognized lines to a reading: `CommandNoticeParser`.
public protocol CommandNoticeParsing: Sendable {
    func read(_ lines: [(String, Double)]) -> CommandNoticeReading
}

extension CommandNoticeParser: CommandNoticeParsing {}

/// The command band and the drone footer, frame by frame:
/// `CommandNoticeCapture`. The image-taking methods stay: the C++ arm runs
/// the same pixel detector and crops, and keeps only the decisions in C++.
public protocol CommandNoticeCapturing: AnyObject {
    var queue: [CommandNoticeFrame] { get }
    var showsNotice: Bool { get }
    var noticeReadAt: Double? { get }
    var modeCandidates: Int { get }
    var modeReads: Int { get }
    var modeReuses: Int { get }
    func observe(band: CGImage, at time: Double) throws
    /// `observe(band:)` for a band the planes show empty, without its render.
    func observeEmptyBand(at time: Double)
    /// Whether `observeMode` would probe a frame at `time`: asked before the
    /// frame is rendered, so a frame it would not probe is never rendered.
    func modeProbeDue(at time: Double, panelShowing: Bool) -> Bool
    @discardableResult
    func observeMode(in image: CGImage, at time: Double, panelShowing: Bool) throws -> Bool
    /// `observeMode(in:)` with only the footer's region of the frame:
    /// `DroneFooterProbe.textRect(width: frameWidth, height: frameHeight)`
    /// rendered on its own.
    @discardableResult
    func observeMode(footer: CGImage, frameWidth: Int, frameHeight: Int, at time: Double,
                     panelShowing: Bool) throws -> Bool
    func take(at time: Double) -> CommandNoticeFrame?
    func takeDropped() -> [Int]
    func interrupt(at time: Double)
    func invalidateQueue(at time: Double)
    func accept(_ read: CommandNoticeReading, frame: CommandNoticeFrame)
    func bind(hackID: Int)
    func cancel()
    func summary(hackID: Int) -> HackCommandSummary
}

extension CommandNoticeCapture: CommandNoticeCapturing {}

extension CommandNoticeFrame {
    /// For the C++ arm, which makes frames outside this module, where the
    /// memberwise initializer is not visible.
    public static func make(id: Int, sourceTime: Double, image: CGImage, isMode: Bool, generation: Int,
                            signature: [UInt8]?) -> Self {
        Self(id: id, sourceTime: sourceTime, image: image, isMode: isMode, generation: generation,
             signature: signature)
    }
}
