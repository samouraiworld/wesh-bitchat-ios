// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Foundation

/// Deletes the old ambient encounter tally without loading its payload.
struct RetiredSightingsStore {
    private static let keys = [
        "meshSightings.dayKey", "meshSightings.salt", "meshSightings.hashes", "meshSightings.lastSeenAt"
    ]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func wipe() -> Bool {
        for key in Self.keys {
            defaults.removeObject(forKey: key)
        }
        let flushed = defaults.synchronize()
        let absent = Self.keys.map { defaults.object(forKey: $0) == nil }
        return flushed && absent.allSatisfy({ $0 })
    }
}

/// Recovery replays only an already pending panic. Legacy metadata cleanup
/// cannot authorize destruction of the user's other data during an ordinary launch.
struct PanicStartupDecision {
    let recoveryPending: Bool
    let legacySightingsConfirmed: Bool

    var suspendTransport: Bool { recoveryPending || !legacySightingsConfirmed }
    var replayPanic: Bool { recoveryPending }
    var blockOrdinaryAdmission: Bool { !legacySightingsConfirmed }

    @MainActor
    static func preflight(
        checkPending: () throws -> Bool,
        wipeSightings: @MainActor () -> Bool,
        wipeGeography: @MainActor () -> Bool,
        wipeSharedContent: @MainActor () -> Bool,
        wipeBoard: @MainActor () -> Bool,
        wipeBridge: @MainActor () -> Bool,
        wipeGroups: @MainActor () -> Bool,
        wipeMedia: @MainActor () -> Bool
    ) -> Self {
        let pending = (try? checkPending()) ?? true
        let sightingsConfirmed = wipeSightings()
        let geographyConfirmed = wipeGeography()
        let sharedContentConfirmed = wipeSharedContent()
        let boardConfirmed = wipeBoard()
        let bridgeConfirmed = wipeBridge()
        let groupsConfirmed = wipeGroups()
        let mediaConfirmed = wipeMedia()
        return Self(
            recoveryPending: pending,
            legacySightingsConfirmed: sightingsConfirmed && geographyConfirmed
                && sharedContentConfirmed && boardConfirmed && bridgeConfirmed && groupsConfirmed && mediaConfirmed
        )
    }

    @MainActor
    static func retry(
        checkPending: () throws -> Bool,
        wipeSightings: @MainActor () -> Bool,
        wipeGeography: @MainActor () -> Bool,
        wipeSharedContent: @MainActor () -> Bool,
        wipeBoard: @MainActor () -> Bool,
        wipeBridge: @MainActor () -> Bool,
        wipeGroups: @MainActor () -> Bool,
        wipeMedia: @MainActor () -> Bool
    ) -> Self {
        preflight(checkPending: checkPending, wipeSightings: wipeSightings, wipeGeography: wipeGeography,
                  wipeSharedContent: wipeSharedContent, wipeBoard: wipeBoard, wipeBridge: wipeBridge,
                  wipeGroups: wipeGroups, wipeMedia: wipeMedia)
    }
}
