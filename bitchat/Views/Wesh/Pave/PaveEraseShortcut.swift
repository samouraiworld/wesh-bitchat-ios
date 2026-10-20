import AppIntents
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Carries a « Tout effacer » request from the App Shortcut to the visible app.
@MainActor
final class PaveEraseRequest: ObservableObject {
    static let shared = PaveEraseRequest()
    @Published private(set) var isPresented = false
    /// Where the screen opens: the hold, or the result of a wipe already run from Settings.
    private(set) var outcome: PaveEraseScreen.Outcome = .ready
    /// Every run of the shortcut, including one while the screen is already up.
    private(set) var requestCount = 0

    func request() {
        requestCount += 1
        outcome = .ready
        isPresented = true
    }

    /// Settings ran the wipe itself: show its result above the app, which the wipe rebuilds.
    func show(_ outcome: PaveEraseScreen.Outcome) {
        self.outcome = outcome
        isPresented = true
    }

    /// The erase screen closed: the next run of the shortcut presents it again.
    func close() {
        isPresented = false
    }
}

/// Opens the hold-to-erase screen. It never erases by itself: the person still holds for three seconds.
struct PaveEraseEverythingIntent: AppIntent {
    static let title = LocalizedStringResource("pave.intent.erase.title", table: "Pave")
    static let description: IntentDescription? = IntentDescription(LocalizedStringResource("pave.intent.erase.description", table: "Pave"))
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PaveEraseRequest.shared.request()
        return .result()
    }
}

// periphery:ignore - discovered by the system through App Intents metadata, never referenced in code
struct WeshAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PaveEraseEverythingIntent(),
            phrases: [
                "Erase everything in \(.applicationName)",
                "Erase \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("pave.intent.erase.shortTitle", table: "Pave"),
            systemImageName: "flame.fill"
        )
    }
}

private struct PaveEraseShortcutPresenter: ViewModifier {
    let command: PanicEraseCommand
    @ObservedObject private var request = PaveEraseRequest.shared
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var overlay = PaveEraseOverlayWindow()
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        // A window above the app's own, so the screen shows even over an open sheet or cover
        // (contact, Échanger, shared content), where a root presentation would silently not appear.
        content
            .onReceive(request.$isPresented) { shown in shown ? overlay.show(screen) : overlay.hide() }
            .onChange(of: scenePhase) { phase in
                if phase == .active, request.isPresented { overlay.show(screen) }
            }
        #else
        content.sheet(isPresented: Binding(get: { request.isPresented }, set: { if !$0 { request.close() } })) {
            screen
        }
        #endif
    }

    private var screen: some View {
        PaveEraseScreen(outcome: request.outcome, command: command) { request.close() }
            .paveTheme(.nuit)
    }
}

/// Key status around the erase overlay window.
enum PaveWindowOrder {
    /// The window that takes key status back when the overlay closes: the one that had it before,
    /// if still in the scene, else the first other window; never the overlay.
    static func keyAfterOverlay<Window: AnyObject>(previous: Window?, overlay: Window, windows: [Window]) -> Window? {
        if let previous, previous !== overlay, windows.contains(where: { $0 === previous }) { return previous }
        return windows.first { $0 !== overlay }
    }
}

#if os(iOS)
/// The hold-to-erase screen in its own window, above every sheet and cover of the app. It takes
/// key status while shown and gives it back on close. `PrivacyScreen` covers every window of the
/// scene, this one included, before the app switcher snapshot.
@MainActor
private final class PaveEraseOverlayWindow {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func show(_ screen: some View) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Before the scene is active (launched by the shortcut), `scenePhase` retries.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return }
        previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        guard let window else { return }
        window.isHidden = true
        let others = window.windowScene?.windows ?? []
        PaveWindowOrder.keyAfterOverlay(previous: previousKeyWindow, overlay: window, windows: others)?.makeKey()
        self.window = nil
        previousKeyWindow = nil
    }
}
#endif

extension View {
    /// Presents the hold-to-erase screen when the « Tout effacer » App Shortcut runs.
    func paveEraseShortcut(command: PanicEraseCommand) -> some View {
        modifier(PaveEraseShortcutPresenter(command: command))
    }
}
