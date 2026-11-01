import Foundation
import WidgetKit

/// What the app, the broadcast extension and the Control Center switch agree
/// on: the switch's kind, the Darwin notification its Stop posts, and where
/// the app keeps the files the switch reads. Like `BroadcastChannel`, a
/// notification carries nothing; the files and the ring are the truth.
enum ControlChannel {
    /// Unchanged from the start-only button, so a switch already placed in
    /// Control Center stays there.
    static let kind = "org.szres.DynamicGlyph.StartControl"
    /// Posted by the switch's Stop after it has written its request.
    static let stopRequested = "org.szres.DynamicGlyph.controlStop"

    static var directory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: BroadcastChannel.appGroup) else { return nil }
        let directory = container.appendingPathComponent("ControlCenter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Asks the system to read the switch's state again, after whatever
    /// changed it has been written.
    static func reload() {
        ControlCenter.shared.reloadControls(ofKind: kind)
    }
}
