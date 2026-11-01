import Foundation

/// What the app and its broadcast extension agree on besides the ring's
/// layout: where the ring lives, and the Darwin notifications that prompt
/// each side to read it. A notification carries nothing; the file is the truth.
enum BroadcastChannel {
    static let appGroup = "group.org.szres.DynamicGlyph"
    static let extensionBundleID = "org.szres.DynamicGlyph.GlyphBroadcast"
    /// Posted by the extension after each frame it publishes.
    static let framesPublished = "org.szres.DynamicGlyph.frames"
    /// Posted by the app after it stores `stopRequested`.
    static let stopRequested = "org.szres.DynamicGlyph.stop"

    /// Six slots are 300 ms at 20 Hz: the app's copier only has to keep up
    /// with itself, not with recognition. A slot fits a `targetWidth` frame of
    /// any iPhone's proportions in 4:2:0, with row padding.
    static let layout = FrameRingLayout(slotCount: 6, slotCapacity: 2 << 20)

    /// The layout fractions and thresholds were measured on 603-pixel-wide
    /// frames (ScreenCaptureKit at half an iPhone 17 Pro's pixels). ReplayKit
    /// delivers its own size, 886 wide on an iOS 26 phone, so halving it would
    /// leave 443 and thin the strokes and slot markers recognition reads.
    static let targetWidth = 603

    /// The size a broadcast frame is scaled to: `targetWidth`, in proportion,
    /// and never larger than it arrived, since scaling up adds no detail.
    static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scaledWidth = min(width, targetWidth)
        return (scaledWidth, (height * scaledWidth + width / 2) / width)
    }

    static var ringURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let directory = container.appendingPathComponent("FrameTransport", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ring-v1")
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Calls `handler` each time a Darwin notification is posted, on a thread of
/// the system's choosing, until released.
final class DarwinObserver {
    private let name: String
    private let handler: @Sendable () -> Void

    init(_ name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }
}
