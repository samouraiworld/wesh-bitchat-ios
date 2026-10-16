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
    /// Every run of the shortcut, including one while the screen is already up.
    private(set) var requestCount = 0

    func request() {
        requestCount += 1
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
    let erase: () -> Bool
    @ObservedObject private var request = PaveEraseRequest.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
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
        PaveEraseScreen(erase: erase) { request.close() }
            .paveTheme(.nuit)
    }
}

#if os(iOS)
/// The hold-to-erase screen in its own window, above every sheet and cover of the app.
@MainActor
private final class PaveEraseOverlayWindow {
    private var window: UIWindow?

    func show(_ screen: some View) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Before the scene is active (launched by the shortcut), `scenePhase` retries.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
#endif

extension View {
    /// Presents the hold-to-erase screen when the « Tout effacer » App Shortcut runs.
    func paveEraseShortcut(erase: @escaping () -> Bool) -> some View {
        modifier(PaveEraseShortcutPresenter(erase: erase))
    }
}
