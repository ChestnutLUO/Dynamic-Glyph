import Foundation
import Testing
import Vision

@Suite("Vision header language diagnostic")
struct HeaderLanguageProbeTests {
    @Test("Print fast and accurate language support at Vision's current revision")
    func currentRevisionLanguages() throws {
        // Fixtures/Assets/Screenshots/Languages/README.md and the pixels were inspected:
        // zh-bonus and ja-portal-cut mask the entire header; zh-complex is
        // only a command notice crop (602x170), NOT the game's header.
        // No zh/ja header OCR/crop comparison is justified by these fixtures.
        // Keep production recognition levels unchanged pending real captures.
        let revision = VNRecognizeTextRequest.currentRevision
        for (name, level) in [("fast", VNRequestTextRecognitionLevel.fast), ("accurate", .accurate)] {
            let request = VNRecognizeTextRequest()
            request.revision = revision
            request.recognitionLevel = level
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let languages = try request.supportedRecognitionLanguages().sorted()
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                print("ZHPROBE level=\(name) revision=\(revision) support_ms=\(String(format: "%.3f", milliseconds)) languages=\(languages)")
                print("ZHPROBE level=\(name) zh_ja=\(languages.filter { $0.hasPrefix("zh") || $0.hasPrefix("ja") })")
            } catch {
                print("ZHPROBE level=\(name) revision=\(revision) support_error=\(error)")
                throw error
            }
        }
        print("ZHPROBE header_ocr=not_run: no real zh/ja header fixtures; notice/panel text is not header evidence")
    }
}
