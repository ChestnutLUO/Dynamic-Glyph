import Combine
import SwiftUI
import UIKit

/// Closes whatever the app is presenting -- sheets, alerts, confirmation
/// dialogs, the file importer, share sheets -- so the Control Center button's
/// screen-sharing request is not presented under it or refused by it.
///
/// One signal for every view that presents something: each resets its own
/// state through `closesForControlStart`, so SwiftUI never re-presents what
/// was closed. Anything still in front afterwards is dismissed through UIKit.
/// iOS's own screen-sharing sheet is left as it is.
@MainActor
enum PresentationDismisser {
    /// Observed by views with a presentation; see `closesForControlStart`.
    static let closeAll = PassthroughSubject<Void, Never>()

    /// Whether the window is clear once everything has been asked to close.
    static func clear() async -> Bool {
        closeAll.send()
        var clearance = PresentationClearance()
        while true {
            try? await Task.sleep(for: .seconds(PresentationClearance.interval))
            guard let root = keyWindow?.rootViewController else { return false }
            switch clearance.next(front(of: root)) {
            case .proceed:
                return true
            case .abandon:
                return false
            case .wait:
                continue
            case .dismiss:
                // Dismissing from the root closes the whole chain above it.
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    root.dismiss(animated: false) { done.resume() }
                }
            }
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static func front(of root: UIViewController) -> PresentationClearance.Front {
        var chain: [UIViewController] = []
        var next = root.presentedViewController
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        if chain.isEmpty { return .nothing }
        if chain.contains(where: isSharingSheet) { return .sharingSheet }
        if chain.contains(where: { $0.isBeingPresented || $0.isBeingDismissed }) { return .moving }
        return .presented
    }

    /// The ReplayKit broadcast picker's or ScreenCaptureKit's sheet.
    private static func isSharingSheet(_ controller: UIViewController) -> Bool {
        let controllerType = type(of: controller)
        if String(describing: controllerType).hasPrefix("RP") { return true }
        let framework = Bundle(for: controllerType).bundleIdentifier ?? ""
        return framework == "com.apple.ReplayKit" || framework == "com.apple.ScreenCaptureKit"
    }
}

extension View {
    /// Closes the presentation `isPresented` drives when the Control Center
    /// button is about to ask for screen sharing.
    func closesForControlStart(_ isPresented: Binding<Bool>) -> some View {
        onReceive(PresentationDismisser.closeAll) { _ in
            closeWithoutAnimation { isPresented.wrappedValue = false }
        }
    }

    /// Closes the presentation `item` drives, as above.
    func closesForControlStart<Item>(_ item: Binding<Item?>) -> some View {
        onReceive(PresentationDismisser.closeAll) { _ in
            closeWithoutAnimation { item.wrappedValue = nil }
        }
    }
}

private func closeWithoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}
