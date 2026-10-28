import CoreBluetooth
import Foundation
import SwiftUI
import Testing
@testable import bitchat

/// « Keep the screen on »: off by default, and only while Wesh is on screen with the mesh running.
struct WeshKeepAwakeTests {
    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "wesh.keepAwake.\(UUID().uuidString)")!
    }

    @Test func theSettingIsOffUntilSomeoneTurnsItOnAndAnEraseTurnsItOff() {
        let defaults = Self.freshDefaults()
        #expect(!WeshKeepAwake.isEnabled(in: defaults))
        defaults.set(true, forKey: WeshKeepAwake.enabledKey)
        #expect(WeshKeepAwake.isEnabled(in: defaults))
        WeshKeepAwake.reset(in: defaults)
        #expect(!WeshKeepAwake.isEnabled(in: defaults))
    }

    @Test func theMeshCountsAsActiveOnlyInTheAppWithBluetoothOn() {
        #expect(WeshKeepAwake.meshActive(screen: .tabs, bluetooth: .poweredOn))
        #expect(!WeshKeepAwake.meshActive(screen: .tabs, bluetooth: .poweredOff))
        #expect(!WeshKeepAwake.meshActive(screen: .tabs, bluetooth: .unauthorized))
        // The welcome has not started the mesh yet; an unfinished erase keeps it stopped.
        #expect(!WeshKeepAwake.meshActive(screen: .welcome, bluetooth: .poweredOn))
        #expect(!WeshKeepAwake.meshActive(screen: .eraseRecovery, bluetooth: .poweredOn))
    }

    @Test func theScreenStaysOnOnlyWhileEveryConditionHolds() {
        #expect(WeshKeepAwake.keepsScreenOn(enabled: true, phase: .active, meshActive: true))
        #expect(!WeshKeepAwake.keepsScreenOn(enabled: false, phase: .active, meshActive: true))
        #expect(!WeshKeepAwake.keepsScreenOn(enabled: true, phase: .active, meshActive: false))
        // Leaving the app gives the screen back to the system's auto-lock.
        #expect(!WeshKeepAwake.keepsScreenOn(enabled: true, phase: .inactive, meshActive: true))
        #expect(!WeshKeepAwake.keepsScreenOn(enabled: true, phase: .background, meshActive: true))
    }
}
