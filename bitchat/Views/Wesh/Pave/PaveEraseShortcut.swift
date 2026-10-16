import AppIntents
import SwiftUI

/// Carries a « Tout effacer » request from the App Shortcut to the visible app.
@MainActor
final class PaveEraseRequest: ObservableObject {
    static let shared = PaveEraseRequest()
    @Published var isPresented = false
}

/// Opens the hold-to-erase screen. It never erases by itself: the person still holds for three seconds.
struct PaveEraseEverythingIntent: AppIntent {
    static let title = LocalizedStringResource("pave.intent.erase.title", table: "Pave")
    static let description: IntentDescription? = IntentDescription(LocalizedStringResource("pave.intent.erase.description", table: "Pave"))
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PaveEraseRequest.shared.isPresented = true
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

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $request.isPresented) { screen }
        #else
        content.sheet(isPresented: $request.isPresented) { screen }
        #endif
    }

    private var screen: some View {
        PaveEraseScreen(erase: erase) { request.isPresented = false }
            .paveTheme(.nuit)
    }
}

extension View {
    /// Presents the hold-to-erase screen when the « Tout effacer » App Shortcut runs.
    func paveEraseShortcut(erase: @escaping () -> Bool) -> some View {
        modifier(PaveEraseShortcutPresenter(erase: erase))
    }
}
