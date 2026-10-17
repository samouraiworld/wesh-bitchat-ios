import Foundation
import Testing
@testable import bitchat

/// The store screens are the ones the app mounts: welcome and terms at first launch, Échanger,
/// Connexion, Réglages and the « Tout effacer » shortcut.
struct WeshRootMountTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func aFirstLaunchOpensOnTheWelcome() {
        let fresh = UserDefaults(suiteName: "wesh.root.\(UUID().uuidString)")!
        #expect(WeshRootScreen(panicRecoveryBlocked: false, welcomed: WeshWelcome.isDone(in: fresh)) == .welcome)
        fresh.set(true, forKey: WeshWelcome.key)
        #expect(WeshRootScreen(panicRecoveryBlocked: false, welcomed: WeshWelcome.isDone(in: fresh)) == .tabs)
        // An unfinished erase outranks everything, the welcome included.
        #expect(WeshRootScreen(panicRecoveryBlocked: true, welcomed: false) == .eraseRecovery)
    }

    @Test func theRootMountsTheWelcomeAndEveryStoreScreen() throws {
        let rootView = try Self.source("bitchat/Views/Wesh/WeshRootView.swift")
        #expect(rootView.contains("@AppStorage(WeshWelcome.key) private var welcomed"))
        let welcome = try #require(rootView.range(of: "case .welcome:"))
        let tabs = try #require(rootView.range(of: "case .tabs:"))
        #expect(rootView[welcome.upperBound..<tabs.lowerBound].contains("PaveOnboardingFlow("))
        for screen in ["PaveSettingsScreen(", "PaveConnexionSheet(", "PaveExchangeScreen(", "WeshInternetMode.shared"] {
            #expect(rootView.contains(screen), "WeshRootView never mounts \(screen)")
        }
        #expect(try Self.source("bitchat/BitchatApp.swift").contains(".paveEraseShortcut"))
        // The Bluetooth prompt waits for the welcome's step.
        #expect(try Self.source("bitchat/ViewModels/ChatViewModel.swift")
            .contains("deferBluetoothPrompt: WeshMode.isActive && !WeshWelcome.isDone()"))
    }
}
