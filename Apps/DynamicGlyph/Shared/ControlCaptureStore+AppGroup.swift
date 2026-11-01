import Foundation

extension ControlCaptureStore {
    /// The store the app, its widget extension and the switch share.
    static var appGroup: ControlCaptureStore? {
        ControlChannel.directory.map { ControlCaptureStore(directory: $0, ringURL: BroadcastChannel.ringURL) }
    }
}
