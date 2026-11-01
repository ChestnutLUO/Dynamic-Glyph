import Foundation
import CoreGraphics
import ImageIO

/// PNG compression runs off the recognition queue. Two outstanding images
/// bound memory use. snapshots.jsonl distinguishes queued images from files
/// actually saved, including failures. finish() must run off MainActor.
final class GlyphSnapshotWriter: @unchecked Sendable {
    private let directory: URL
    private let file: FileHandle
    private let queue = DispatchQueue(label: "spikeB.snapshots", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let capacity = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()

    init(directory: URL) throws {
        self.directory = directory
        let url = directory.appendingPathComponent("snapshots.jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
    }

    func enqueue(_ image: CGImage, name: String, sample: Int) -> Bool {
        guard capacity.wait(timeout: .now()) == .success else { return false }
        group.enter()
        queue.async { [self] in
            defer { capacity.signal(); group.leave() }
            let start = ProcessInfo.processInfo.systemUptime
            let url = directory.appendingPathComponent(name)
            var saved = false
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                saved = CGImageDestinationFinalize(destination)
            }
            var row: [String: Any] = ["sample": sample, "snapshot": name,
                                     "status": saved ? "saved" : "failed",
                                     "encodingMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000]
            if !saved { row["error"] = "PNG encoding or file write failed" }
            do {
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0A)
                try file.write(contentsOf: data)
                try file.synchronize()
            } catch { NSLog("[SpikeB] Snapshot log write failed: %@", error.localizedDescription) }
        }
        return true
    }

    /// Called once after recognition stops submitting images.
    func finish() {
        group.wait()
        try? file.synchronize()
        try? file.close()
    }
}
