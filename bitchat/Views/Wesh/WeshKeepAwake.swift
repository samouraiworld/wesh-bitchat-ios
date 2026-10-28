import CoreBluetooth
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// « Keep the screen on »: holds off auto-lock while Wesh is on screen and the mesh is running,
/// for someone who follows a conversation without touching the phone.
///
/// Off by default. The screen gets its auto-lock back as soon as Wesh leaves the screen, the mesh
/// stops, or the setting is turned off; an erase turns it off.
enum WeshKeepAwake {
    static let enabledKey = "wesh.keepScreenOn.enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Panic-wipe hook: an erased phone comes back with the default, like a new install.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
    }

    /// The mesh runs once the welcome is done, outside an unfinished erase, with Bluetooth on.
    static func meshActive(screen: WeshRootScreen, bluetooth: CBManagerState) -> Bool {
        screen == .tabs && bluetooth == .poweredOn
    }

    static func keepsScreenOn(enabled: Bool, phase: ScenePhase, meshActive: Bool) -> Bool {
        enabled && phase == .active && meshActive
    }

    @MainActor static func apply(_ keepOn: Bool) {
        #if os(iOS)
        if UIApplication.shared.isIdleTimerDisabled != keepOn {
            UIApplication.shared.isIdleTimerDisabled = keepOn
        }
        #endif
    }
}
