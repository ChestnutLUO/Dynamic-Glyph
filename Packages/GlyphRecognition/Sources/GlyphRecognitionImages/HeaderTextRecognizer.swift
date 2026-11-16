import CoreGraphics
import Foundation
import Vision
import GlyphRecognition

/// Reads the game's header text from a frame.
///
/// One implementation, shared by the live app and by the offline replay tool,
/// so what a device test exercises and what a regression run exercises are the
/// same code. Scheduling and back pressure are deliberately *not* here: the app
/// bounds this on its own terms, and the replay runs it on every frame.
@available(iOS 18.0, macOS 15.0, *)
public struct HeaderTextRecognizer: Sendable {
    public let layout: GameUILayout
    /// The Swift `HeaderPhraseMatcher`, or a logic arm's
    /// (`RecognitionLogicSet.headerPhraseMatcher`).
    public let matcher: any HeaderPhraseMatching
    public let recognitionLanguages: [Locale.Language]

    /// Chinese and Japanese need Vision's accurate recognition, which is
    /// slower but the only one that reads their script.
    public let accurate: Bool

    public init(layout: GameUILayout = GameUILayout(),
                matcher: HeaderPhraseMatcher = HeaderPhraseMatcher(),
                recognitionLanguages: [Locale.Language] = [Locale.Language(identifier: "en-US")],
                accurate: Bool = false) {
        self.layout = layout
        self.matcher = matcher
        self.recognitionLanguages = recognitionLanguages
        self.accurate = accurate
    }

    /// The headers of one game language, read in its script.
    public init(layout: GameUILayout = GameUILayout(), language: GameLanguage) {
        self.init(layout: layout, matcher: HeaderPhraseMatcher(language: language),
                  recognitionLanguages: language.recognitionLanguages.map { Locale.Language(identifier: $0) },
                  accurate: language.needsAccurateRecognition)
    }

    /// The headers of one game language, read in its script and matched by
    /// `matcher`, which a logic arm made for that language.
    public init(layout: GameUILayout = GameUILayout(), language: GameLanguage, matcher: any HeaderPhraseMatching) {
        self.layout = layout
        self.matcher = matcher
        recognitionLanguages = language.recognitionLanguages.map { Locale.Language(identifier: $0) }
        accurate = language.needsAccurateRecognition
    }

    /// The header region of a `width` by `height` frame, in top-left
    /// coordinates, from the layout's measured fractions: full width, above
    /// the slot indicators, below the status bar and the Dynamic Island
    /// cut-out.
    public func headerRect(width: Int, height: Int) -> CGRect {
        let height = Double(height)
        return CGRect(x: 0, y: layout.headerTextTop * height, width: Double(width),
                      height: (layout.headerTextBottom - layout.headerTextTop) * height).integral
    }

    /// The header region of a frame, cropped at `headerRect`.
    public func headerCrop(of image: CGImage) -> CGImage? {
        image.cropping(to: headerRect(width: image.width, height: image.height))
    }

    public func read(_ image: CGImage, sourceTime: Double) async throws -> HeaderReading {
        guard let crop = headerCrop(of: image) else {
            return HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: sourceTime)
        }
        return try await read(headerRegion: crop, sourceTime: sourceTime)
    }

    /// The same read of a frame's `headerRect` alone, such as a crop of it or
    /// that rectangle rendered on its own.
    public func read(headerRegion crop: CGImage, sourceTime: Double) async throws -> HeaderReading {
        var request = RecognizeTextRequest()
        // `fast`, and no language correction: the four headers are fixed
        // strings matched word by word, and correction has more ways to turn
        // "GO!" into something else than to help.
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = recognitionLanguages
        let observations: [RecognizedTextObservation]
        do {
            let started = TextReadProbe.start()
            defer { TextReadProbe.finish(accurate ? .headerAccurate : .headerFast, since: started) }
            observations = try await request.perform(on: crop)
        }
        let lines = observations.compactMap { observation -> (String, Double)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return (best.string, Double(best.confidence))
        }
        return matcher.read(lines: lines).at(sourceTime: sourceTime)
    }
}
