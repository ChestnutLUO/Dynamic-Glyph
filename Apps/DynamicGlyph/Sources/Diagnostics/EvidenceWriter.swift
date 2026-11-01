import Foundation
import CoreImage
import CoreMedia
import UIKit

/// Writes the artifacts the verdict actually rests on.
///
/// The acceptance criterion for this spike is a human looking at a JPEG and
/// seeing Ingress in it. A frame counter cannot tell "capturing the game" from
/// "delivering a frozen frame of our own app at 15 fps", so the images are the
/// evidence and the CSV is only the supporting detail.
final class EvidenceWriter {
    let directory: URL
    private let csv: FileHandle
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var written = 0
    private var rows = 0
    private let maxImages = 200

    init() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("spikeB-\(stamp)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let header = "wallClock,uptime,elapsed,frame,status,width,height,pixelFormat,"
            + "scaleFactor,contentScale,contentRect,orientation,hash,hashChanged,"
            + "appState,thermal,footprintMB,cpuSeconds,pipActive\n"
        let url = directory.appendingPathComponent("frames.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        csv = try FileHandle(forWritingTo: url)
        csv.seekToEndOfFile()
    }

    func appendRow(_ fields: [String]) {
        csv.write(Data((fields.joined(separator: ",") + "\n").utf8))
        rows += 1
        // A disk barrier on every 60 Hz frame competes with live recognition.
        if rows % 60 == 0 { try? csv.synchronize() }
    }

    func note(_ text: String) {
        let url = directory.appendingPathComponent("events.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        NSLog("[SpikeB] %@", text)
    }

    /// Saves a frame as JPEG. Goes through Core Image so whatever pixel format
    /// iOS chose is handled -- the format cannot be requested on iOS, so it is
    /// discovered rather than assumed.
    @discardableResult
    func saveImage(_ sampleBuffer: CMSampleBuffer, index: Int) -> Bool {
        guard written < maxImages,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
        else { return false }
        let url = directory.appendingPathComponent(String(format: "frame-%05d.jpg", index))
        try? data.write(to: url)
        written += 1
        return true
    }

    func close() {
        try? csv.synchronize()
        try? csv.close()
    }
}

enum Metrics {
    static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func cpuSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000_000
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    nonisolated(unsafe) static var appStateDescription = "active"

    static func observeAppState() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { _ in appStateDescription = "background" }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in appStateDescription = "active" }
        nc.addObserver(forName: UIApplication.willResignActiveNotification,
                       object: nil, queue: .main) { _ in appStateDescription = "inactive" }
    }
}
