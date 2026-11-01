import AVFoundation
import SwiftUI

private struct PiPHostActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// TabView may retain off-screen hosts in its hierarchy. Tab selection,
    /// not construction or layout order, decides which one may own the layer.
    var isPiPHostActive: Bool {
        get { self[PiPHostActiveKey.self] }
        set { self[PiPHostActiveKey.self] = newValue }
    }
}

/// Hosts the single PiP display layer in the selected tab's inline preview.
/// Inactive or detached hosts never claim it, resize it, or detach another
/// host's layer. This keeps a hidden tab from making PiP unavailable.
struct SampleBufferHostView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    @Environment(\.isPiPHostActive) private var isActive

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.attach(layer, isActive: isActive)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.attach(layer, isActive: isActive)
    }

    final class LayerView: UIView {
        private weak var hosted: AVSampleBufferDisplayLayer?
        private var isActive = false

        func attach(_ displayLayer: AVSampleBufferDisplayLayer, isActive: Bool = true) {
            if hosted !== displayLayer, hosted?.superlayer === layer {
                hosted?.removeFromSuperlayer()
            }
            hosted = displayLayer
            self.isActive = isActive
            backgroundColor = .black
            reconcileOwnership()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reconcileOwnership()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reconcileOwnership()
        }

        private func reconcileOwnership() {
            guard let hosted else { return }
            guard isActive, window != nil else {
                if hosted.superlayer === layer { hosted.removeFromSuperlayer() }
                return
            }
            // Wait for layout rather than attach an empty presentation layer.
            guard !bounds.isEmpty else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if hosted.superlayer !== layer { layer.addSublayer(hosted) }
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
