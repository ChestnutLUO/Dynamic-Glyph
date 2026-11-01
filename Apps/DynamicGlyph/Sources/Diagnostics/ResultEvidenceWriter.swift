import Foundation
import CoreGraphics
import ImageIO

/// Two ordinary crops plus two reserved decision crops, never a frame queue.
/// Each saved image is linked to its OCR source time, not callback arrival.
final class ResultEvidenceWriter: @unchecked Sendable {
    private let directory: URL
    private let file: FileHandle
    private let queue = DispatchQueue(label: "dynamicglyph.result-evidence", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let ordinary = DispatchSemaphore(value: 2)
    private let decisions = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()

    init(directory: URL) throws {
        self.directory = directory
        let url = directory.appendingPathComponent("result-frames.jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: url)
    }

    /// Nil means queued. The caller logs an explicit drop reason otherwise.
    func enqueue(_ image: CGImage, hackID: Int, sourceTime: Double, decision: Bool) -> String? {
        guard image.width <= 3000, image.height <= 6000 else { return "imageSizeLimit" }
        let capacity = decision ? decisions : ordinary
        guard capacity.wait(timeout: .now()) == .success else { return "writerBusy" }
        let rect = CGRect(x: 0, y: Double(image.height) * 0.10,
                          width: Double(image.width), height: Double(image.height) * 0.55).integral
        guard let crop = image.cropping(to: rect) else { capacity.signal(); return "cropFailed" }
        let sourceWidth = image.width, sourceHeight = image.height
        group.enter()
        queue.async { [self] in
            defer { capacity.signal(); group.leave() }
            let started = ProcessInfo.processInfo.systemUptime
            let name = String(format: "result-%d-%.6f.jpg", hackID, sourceTime)
            let url = directory.appendingPathComponent(name)
            var saved = false
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, crop,
                    [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                saved = CGImageDestinationFinalize(destination)
            }
            let row: [String: Any] = ["schemaVersion": 1, "hackID": hackID, "sourceTime": sourceTime,
                "file": name, "status": saved ? "saved" : "failed", "decision": decision,
                "sourceWidth": sourceWidth, "sourceHeight": sourceHeight,
                "crop": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
                "encodingMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000]
            do {
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0A)
                try file.write(contentsOf: data)
            } catch { NSLog("[DynamicGlyph] Result evidence log failed: %@", error.localizedDescription) }
        }
        return nil
    }

    func finish() {
        group.wait()
        try? file.synchronize()
        try? file.close()
    }
}
