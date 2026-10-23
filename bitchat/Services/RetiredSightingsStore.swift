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
enum PanicStartupCleanupOwner: String, CaseIterable, Sendable {
    case sightings = "retired_sightings"
    case geography = "retired_geography"
    case sharedContent = "shared_content"
    case board = "retired_board"
    case bridge = "retired_bridge"
    case groups = "retired_groups"
    case media = "retired_media"
    case legacyGroupKeys = "retired_group_keys"

    fileprivate var diagnosticComponent: String {
        switch self {
        case .sightings: "sig"
        case .geography: "geo"
        case .sharedContent: "shared"
        case .board: "board"
        case .bridge: "bridge"
        case .groups: "groups"
        case .media: "media"
        case .legacyGroupKeys: "group_keys"
        }
    }
}

/// A value-only cleanup result suitable for diagnostics. Owner identifiers are
/// deliberately stable and contain neither payload data nor storage locations.
struct PanicStartupCleanupReport: Equatable, Sendable {
    private let confirmations: [PanicStartupCleanupOwner: Bool]

    init(confirmations: [PanicStartupCleanupOwner: Bool]) {
        self.confirmations = confirmations
    }

    var failedOwners: [PanicStartupCleanupOwner] {
        PanicStartupCleanupOwner.allCases.filter { confirmations[$0] != true }
    }

    var failedOwnerIdentifiers: [String] {
        failedOwners.map(\.rawValue)
    }

    var allConfirmed: Bool { failedOwners.isEmpty }

    var diagnosticCode: String {
        let components = failedOwners.map(\.diagnosticComponent)
        return components.isEmpty
            ? "startup_cleanup/ok"
            : "startup_cleanup/failed/\(components.joined(separator: ","))"
    }

    fileprivate static func compatibilityResult(confirmed: Bool) -> Self {
        var confirmations = Dictionary(
            uniqueKeysWithValues: PanicStartupCleanupOwner.allCases.map { ($0, true) }
        )
        if !confirmed {
            confirmations[.sightings] = false
        }
        return Self(confirmations: confirmations)
    }
}

struct PanicStartupDecision {
    let recoveryPending: Bool
    let cleanupReport: PanicStartupCleanupReport

    /// Kept for source compatibility with existing admission and panic-completion code.
    var legacySightingsConfirmed: Bool { cleanupReport.allConfirmed }
    var failedCleanupOwners: [PanicStartupCleanupOwner] { cleanupReport.failedOwners }

    init(recoveryPending: Bool, legacySightingsConfirmed: Bool) {
        self.init(
            recoveryPending: recoveryPending,
            cleanupReport: .compatibilityResult(confirmed: legacySightingsConfirmed)
        )
    }

    init(recoveryPending: Bool, cleanupReport: PanicStartupCleanupReport) {
        self.recoveryPending = recoveryPending
        self.cleanupReport = cleanupReport
    }

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
        wipeMedia: @MainActor () -> Bool,
        wipeLegacyGroupKeys: @MainActor () -> Bool
    ) -> Self {
        let pending = (try? checkPending()) ?? true
        let sightingsConfirmed = wipeSightings()
        let geographyConfirmed = wipeGeography()
        let sharedContentConfirmed = wipeSharedContent()
        let boardConfirmed = wipeBoard()
        let bridgeConfirmed = wipeBridge()
        let groupsConfirmed = wipeGroups()
        let mediaConfirmed = wipeMedia()
        let groupKeysConfirmed = wipeLegacyGroupKeys()
        let report = PanicStartupCleanupReport(confirmations: [
            .sightings: sightingsConfirmed,
            .geography: geographyConfirmed,
            .sharedContent: sharedContentConfirmed,
            .board: boardConfirmed,
            .bridge: bridgeConfirmed,
            .groups: groupsConfirmed,
            .media: mediaConfirmed,
            .legacyGroupKeys: groupKeysConfirmed
        ])
        return Self(recoveryPending: pending, cleanupReport: report)
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
        wipeMedia: @MainActor () -> Bool,
        wipeLegacyGroupKeys: @MainActor () -> Bool
    ) -> Self {
        preflight(checkPending: checkPending, wipeSightings: wipeSightings, wipeGeography: wipeGeography,
                  wipeSharedContent: wipeSharedContent, wipeBoard: wipeBoard, wipeBridge: wipeBridge,
                  wipeGroups: wipeGroups, wipeMedia: wipeMedia, wipeLegacyGroupKeys: wipeLegacyGroupKeys)
    }
}
