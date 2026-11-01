import Foundation
import GlyphRecognition
import GlyphRecognitionImages

// Sparse screenshots do not establish presentation boundaries, so this tool
// never appends to a sequence predictor. Calibration may be reused explicitly.
let usage = "Usage: glyph-recognize --glyphs <name,shape.csv> [--calibration <empty-array.jpg>] <frame.jpg> [frame.jpg ...]"
enum CLIError: Error, CustomStringConvertible {
    case invalidArguments(String), calibrationArrayNotFound, calibrationSizeMismatch(String)
    var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .calibrationArrayNotFound: return "Cannot calibrate: provide an upright empty-array frame."
        case .calibrationSizeMismatch(let file): return "Frame dimensions differ from the supplied calibration: \(file)"
        }
    }
}
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var glyphFile: String?, calibrationFile: String?
    var filenames: [String] = []
    var index = 0, positionalOnly = false
    while index < arguments.count {
        let argument = arguments[index]
        if !positionalOnly && argument == "--help" { print(usage); exit(0) }
        if !positionalOnly && argument == "--" { positionalOnly = true }
        else if !positionalOnly && (argument == "--glyphs" || argument == "--calibration") {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.invalidArguments("Missing value for \(argument)")
            }
            let value = arguments[index + 1]
            if argument == "--glyphs" {
                guard glyphFile == nil else { throw CLIError.invalidArguments("Duplicate --glyphs option") }
                glyphFile = value
            } else {
                guard calibrationFile == nil else { throw CLIError.invalidArguments("Duplicate --calibration option") }
                calibrationFile = value
            }
            index += 1
        } else if !positionalOnly && argument.hasPrefix("--") {
            throw CLIError.invalidArguments("Unknown option: \(argument)")
        } else { filenames.append(argument) }
        index += 1
    }
    guard let glyphFile, !filenames.isEmpty else { throw CLIError.invalidArguments("Provide --glyphs and at least one frame.") }
    let table = try GlyphTable.parse(csv: String(contentsOfFile: glyphFile, encoding: .utf8))
    let recognizer = GlyphFrameRecognizer(table: table)
    var calibration: NodeArrayDetection?
    if let calibrationFile {
        let blank = try ImageDecoder.load(URL(fileURLWithPath: calibrationFile))
        guard let fit = NodeArrayDetector().detect(in: blank) else { throw CLIError.calibrationArrayNotFound }
        calibration = fit
    }
    for filename in filenames {
        let image = try ImageDecoder.load(URL(fileURLWithPath: filename))
        let result = calibration.map { recognizer.observe(image, calibration: $0) } ?? recognizer.calibrateAndObserve(image)
        guard result.state != .calibrationMismatch else { throw CLIError.calibrationSizeMismatch(filename) }
        var report: [String: Any] = [
            "file": filename, "width": image.width, "height": image.height,
            "state": result.state.rawValue, "strokePixels": result.strokePixelCount,
            "unexplainedInkPixels": result.unexplainedInkPixelCount,
            "extensions": result.extensions.map(\.name),
            "completion": "unconfirmed",
            "edges": result.edges.map { "\($0.lower)-\($0.upper)" }.sorted(),
            "candidates": result.candidates.map { ["glyph": $0.id.name, "edgeDistance": $0.distance] as [String: Any] }
        ]
        if let fit = result.calibration {
            report["array"] = ["origin": [fit.origin.x, fit.origin.y], "size": [fit.size.x, fit.size.y],
                               "matchedNodes": fit.matchedNodes.count, "errorPixels": fit.rootMeanSquareError]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
} catch CLIError.invalidArguments(let message) {
    FileHandle.standardError.write(Data("glyph-recognize: \(message)\n\(usage)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("glyph-recognize: \(error)\n".utf8))
    exit(1)
}
