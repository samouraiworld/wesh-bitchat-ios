//
// PrivacyScreen.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import UIKit

/// Covers every window while the app is not frontmost, so the snapshot iOS takes
/// for the app switcher shows a placeholder instead of the open conversation —
/// including a window above the main one, such as the erase screen's.
///
/// The cover is added on `willResignActive` and removed on `didBecomeActive`.
/// Both are deliberately UIKit notifications rather than SwiftUI's `scenePhase`:
/// the snapshot is captured shortly after `willResignActive`, and adding an
/// opaque subview to the window synchronously in that callback is the only way
/// to guarantee it is in the render tree before the capture. A SwiftUI overlay
/// driven by state may not have been laid out yet.
///
/// Panic wipe separately deletes any snapshots already on disk; this keeps new
/// ones from containing anything worth deleting.
final class PrivacyScreen {
    static let shared = PrivacyScreen()

    private var covers: [UIView] = []
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Idempotent: repeated calls do not stack observers.
    ///
    /// `queue: nil` is required, not incidental. Passing an `OperationQueue`
    /// would enqueue the handler to run in a later runloop turn, which the
    /// snapshot can beat; with no queue the block runs synchronously on the
    /// thread that posted the notification — the main thread, for UIApplication
    /// lifecycle notifications.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                PrivacyScreen.shared.show()
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                PrivacyScreen.shared.hide()
            }
        ]
    }

    private func show() {
        guard covers.isEmpty else { return }
        covers = Self.visibleWindows().map(Self.cover)
    }

    private static func cover(_ window: UIWindow) -> UIView {
        // Opaque rather than a blur: blurred large text can stay partly
        // legible, and the snapshot is stored on disk.
        let view = UIView(frame: window.bounds)
        view.backgroundColor = .systemBackground
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = "Wesh"
        label.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        window.addSubview(view)
        return view
    }

    private func hide() {
        covers.forEach { $0.removeFromSuperview() }
        covers = []
    }

    /// Every shown window of every scene, whatever its level.
    private static func visibleWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
    }
}
#endif
