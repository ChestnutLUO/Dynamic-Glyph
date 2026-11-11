import Foundation
import GlyphRecognition
import GlyphRecognitionImages

// Sparse screenshots do not establish presentation boundaries, so this tool
// never appends to a sequence predictor. Calibration may be reused explicitly.
// With --keys, the frames are key-inventory screenshots instead: each is read
// as a key card and the pass ends with the counts per portal name, the offline
// workflow of Choujingress' CountIngressKeys (MIT, see NOTICE.md).
let glyphUsage = "Usage: glyph-recognize --glyphs <name,shape.csv> [--calibration <empty-array.jpg>] <frame.jpg> [frame.jpg ...]"
let keysUsage = "Usage: glyph-recognize --keys [--name-languages en-US,zh-Hans] <frame.jpg> [frame.jpg ...]"
enum CLIError: Error, CustomStringConvertible {
    case invalidArguments(String), calibrationArrayNotFound, calibrationSizeMismatch(String), unreadableImage(String)
    var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .calibrationArrayNotFound: return "Cannot calibrate: provide an upright empty-array frame."
        case .calibrationSizeMismatch(let file): return "Frame dimensions differ from the supplied calibration: \(file)"
        case .unreadableImage(let file): return "Cannot read an image: \(file)"
        }
    }
}
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var glyphFile: String?, calibrationFile: String?
    var nameLanguages: String?
    var keys = false
    var filenames: [String] = []
    var index = 0, positionalOnly = false
    while index < arguments.count {
        let argument = arguments[index]
        if !positionalOnly && argument == "--help" { print(glyphUsage); print(keysUsage); exit(0) }
        if !positionalOnly && argument == "--" { positionalOnly = true }
        else if !positionalOnly && (["--glyphs", "--calibration", "--name-languages"].contains(argument)
                                    || argument == "--keys") {
            if argument == "--keys" {
                guard !keys else { throw CLIError.invalidArguments("Duplicate --keys option") }
                keys = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.invalidArguments("Missing value for \(argument)")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--glyphs":
                guard glyphFile == nil else { throw CLIError.invalidArguments("Duplicate --glyphs option") }
                glyphFile = value
            case "--calibration":
                guard calibrationFile == nil else { throw CLIError.invalidArguments("Duplicate --calibration option") }
                calibrationFile = value
            default:
                guard nameLanguages == nil else { throw CLIError.invalidArguments("Duplicate --name-languages option") }
                nameLanguages = value
            }
            index += 1
        } else if !positionalOnly && argument.hasPrefix("--") {
            throw CLIError.invalidArguments("Unknown option: \(argument)")
        } else { filenames.append(argument) }
        index += 1
    }
    guard !filenames.isEmpty else {
        throw CLIError.invalidArguments(keys ? "Provide at least one frame." : "Provide --glyphs and at least one frame.")
    }
    if keys {
        guard glyphFile == nil, calibrationFile == nil else {
            throw CLIError.invalidArguments("--keys takes no --glyphs or --calibration")
        }
        let languages = nameLanguages?.split(separator: ",").map(String.init) ?? ["en-US"]
        let reader = KeyCardScreenReader()
        var counter = PortalKeyCounter()
        for (frameIndex, filename) in filenames.enumerated() {
            let imageData = try Data(contentsOf: URL(fileURLWithPath: filename))
            guard let image = ImageDecoder.cgImage(from: imageData) else {
                throw CLIError.unreadableImage(filename)
            }
            var report: [String: Any] = ["file": filename, "kind": "card"]
            if let reading = try reader.read(image, sourceTime: Double(frameIndex + 1),
                                             nameLanguages: languages) {
                let accepted = counter.accept(reading.reading)
                report["disposition"] = accepted.rawValue
                report["card"] = ["x": reading.reading.card.x, "y": reading.reading.card.y,
                                  "width": reading.reading.card.width, "height": reading.reading.card.height,
                                  "kind": reading.reading.card.kind.rawValue]
                if let count = reading.reading.count { report["count"] = count }
                if let name = reading.reading.name { report["name"] = name }
                report["countText"] = reading.countText
                report["nameText"] = reading.nameText
            } else {
                report["disposition"] = "noCard"
            }
            let row = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: row, as: UTF8.self))
        }
        if let summary = counter.finish(at: Double(filenames.count + 1), reason: "framesExhausted") {
            let data = try JSONEncoder().encode(summary)
            print(String(decoding: data, as: UTF8.self))
        }
    } else {
        guard let glyphFile else { throw CLIError.invalidArguments("Provide --glyphs and at least one frame.") }
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
    }
} catch CLIError.invalidArguments(let message) {
    FileHandle.standardError.write(Data("glyph-recognize: \(message)\n\(glyphUsage)\n\(keysUsage)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("glyph-recognize: \(error)\n".utf8))
    exit(1)
}
