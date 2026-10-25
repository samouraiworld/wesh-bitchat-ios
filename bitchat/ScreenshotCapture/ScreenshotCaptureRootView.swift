#if WESH_SCREENSHOT_CAPTURE && os(iOS)
import SwiftUI

/// Verified in the simulator capture executable and forbidden in Release products.
let weshScreenshotFixtureSentinel = "WESH_SCREENSHOT_FIXTURE_SENTINEL_V1"

enum WeshScreenshotScene: String, CaseIterable {
    case welcome = "01-welcome"
    case bluetooth = "02-bluetooth"
    case settings = "03-settings"
    case internetOff = "04-internet-off"
    case about = "05-about"

    static var selected: WeshScreenshotScene {
        ProcessInfo.processInfo.environment["WESH_SCREENSHOT_SCENE"]
            .flatMap(WeshScreenshotScene.init(rawValue:)) ?? .welcome
    }
}

/// Only fixtures and navigation state live here. All visible app content, fonts,
/// tabs and device chrome come from production views or the operating system.
@MainActor
struct ScreenshotCaptureRootView: View {
    private let scene = WeshScreenshotScene.selected
    private let theme = WeshTheme(appearance: .night)
    @StateObject private var internet = PaveInternetModeStub(internetStatus: .off)
    @State private var selectedTab = 1
    @State private var showingConnection = WeshScreenshotScene.selected == .internetOff
    @State private var showingAbout = WeshScreenshotScene.selected == .about

    private var nickname: String {
        locale.language.languageCode?.identifier == "fr" ? "Pinson 29" : "Finch 29"
    }
    private var locale: Locale {
        Locale(identifier: ProcessInfo.processInfo.environment["WESH_SCREENSHOT_LOCALE"] ?? "en")
    }

    var body: some View {
        Group {
            switch scene {
            case .welcome:
                PaveOnboardingFlow(step: .welcome, nickname: nickname,
                                   onRequestBluetooth: {}, onFinish: { _ in })
            case .bluetooth:
                PaveOnboardingFlow(step: .bluetooth, nickname: nickname,
                                   onRequestBluetooth: {}, onFinish: { _ in })
            case .settings, .internetOff, .about:
                WeshTabsPresentation(selection: $selectedTab) {
                    // Inactive tab only: no runtime-backed inbox is constructed.
                    Color.clear
                } settings: {
                    settingsRoot
                }
            }
        }
        .environment(\.appTheme, .liquidGlass)
        .environment(\.weshTheme, theme)
        .environment(\.paveTheme, PaveTheme(.nuit))
        .environment(\.colorScheme, theme.scheme)
        .environment(\.locale, locale)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .tint(theme.accent)
        .preferredColorScheme(theme.scheme)
        .background(theme.canvas.ignoresSafeArea())
        .allowsHitTesting(false)
        .accessibilityIdentifier("wesh-screenshot-\(scene.rawValue)")
        .accessibilityHint(weshScreenshotFixtureSentinel)
    }

    private var settingsRoot: some View {
        PaveSettingsScreen(summary: PaveSettingsSummary(nickname: nickname,
            previewsHidden: true, meetingNote: nil, blockedCount: 0, theme: .nuit),
            presentsOutcome: false, onErase: { false }, onSelect: { _ in })
        .navigationTitle(PaveCopy.text("pave.settings.title"))
        .weshHiddenNavigationBar()
        .navigationDestination(isPresented: $showingAbout) {
            PaveAboutScreen(version: WeshBuildInfo.displayVersion)
                .navigationTitle(PaveSettingsDestination.about.title).weshInlineTitle()
        }
        .sheet(isPresented: $showingConnection) {
            PaveConnexionSheet(bluetooth: .on, peersInRange: 3, internet: internet,
                               onClose: {}, internetAvailable: true)
        }
    }
}
#endif
