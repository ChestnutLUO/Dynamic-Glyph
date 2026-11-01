import Foundation
import CoreGraphics
import ImageIO
import GlyphRecognitionImages

/// Already cropped command acknowledgements only. This writer never receives
/// a whole frame or an unrecognized notice that could contain private text.
final class CommandEvidenceWriter: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "dynamicglyph.command-evidence", qos: .utility)
    private let capacity = DispatchSemaphore(value: 2)
    private let group = DispatchGroup()
    private var seen: Set<Int> = []
    private var count = 0
    private var lastTime = -Double.infinity
    init(directory: URL) { self.directory = directory }

    // Called only on the capture queue. At most 32 unique notices per hack,
    // 512 per session and one picture per 100 ms. Recognition has no such cap.
    func enqueue(_ frame: CommandNoticeFrame) -> String? {
        guard !frame.isMode, seen.count < 32, count < 512, !seen.contains(frame.id),
              frame.sourceTime - lastTime >= 0.1,
              capacity.wait(timeout: .now()) == .success else { return nil }
        seen.insert(frame.id); count += 1; lastTime = frame.sourceTime
        let name = String(format: "command-%d-%.6f.jpg", frame.id, frame.sourceTime)
        let url = directory.appendingPathComponent(name)
        group.enter()
        queue.async { [capacity, group] in
            defer { capacity.signal(); group.leave() }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, frame.image,
                                      [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if !CGImageDestinationFinalize(destination) { NSLog("[DynamicGlyph] Command evidence write failed") }
        }
        return name
    }
    func nextHack() { seen = [] }
    func finish() { group.wait() }
}
