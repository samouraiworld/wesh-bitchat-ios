// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

struct PanicStartupCleanupReportTests {
    private typealias Owner = PanicStartupCleanupOwner

    @Test @MainActor
    func eachFailedOwnerIsReportedByItsStableNonSensitiveIdentifier() {
        for failedOwner in Owner.allCases {
            let decision = makeDecision(failing: [failedOwner])

            #expect(decision.blockOrdinaryAdmission)
            #expect(decision.failedCleanupOwners == [failedOwner])
            #expect(decision.cleanupReport.failedOwnerIdentifiers == [failedOwner.rawValue])
            #expect(decision.cleanupReport.diagnosticCode.hasPrefix("startup_cleanup/failed/"))
        }

        #expect(Owner.allCases.map(\.rawValue) == [
            "retired_sightings", "retired_geography", "shared_content", "retired_board",
            "retired_bridge", "retired_groups", "retired_media", "retired_group_keys"
        ])
    }

    @Test @MainActor
    func everyOwnerIsAttemptedEvenWhenEarlierOwnersFail() {
        var attempted: [Owner] = []

        let decision = makeDecision(failing: Set(Owner.allCases)) { owner in
            attempted.append(owner)
        }

        #expect(attempted == Owner.allCases)
        #expect(decision.failedCleanupOwners == Owner.allCases)
        #expect(decision.blockOrdinaryAdmission)
    }

    @Test @MainActor
    func retryRemainsBlockedThenAdmitsOnlyAfterEveryOwnerConfirms() {
        var blockedOwners: Set<Owner> = [.sharedContent, .legacyGroupKeys]

        let blocked = makeDecision(failing: blockedOwners, usingRetry: true)
        #expect(blocked.failedCleanupOwners == [.sharedContent, .legacyGroupKeys])
        #expect(blocked.blockOrdinaryAdmission)
        #expect(blocked.suspendTransport)
        #expect(!blocked.replayPanic)

        blockedOwners.removeAll()
        let admitted = makeDecision(failing: blockedOwners, usingRetry: true)
        #expect(admitted.failedCleanupOwners.isEmpty)
        #expect(!admitted.blockOrdinaryAdmission)
        #expect(!admitted.suspendTransport)
        #expect(!admitted.replayPanic)
    }

    @Test @MainActor
    func unreadablePanicMarkerStaysFailClosedAfterSuccessfulCleanup() {
        let decision = PanicStartupDecision.retry(
            checkPending: { throw MarkerFailure.unavailable },
            wipeSightings: { true },
            wipeGeography: { true },
            wipeSharedContent: { true },
            wipeBoard: { true },
            wipeBridge: { true },
            wipeGroups: { true },
            wipeMedia: { true },
            wipeLegacyGroupKeys: { true }
        )

        #expect(decision.cleanupReport.allConfirmed)
        #expect(decision.failedCleanupOwners.isEmpty)
        #expect(decision.recoveryPending)
        #expect(decision.replayPanic)
        #expect(decision.suspendTransport)
    }

    @Test
    func missingOwnerConfirmationIsFailClosed() {
        let report = PanicStartupCleanupReport(confirmations: [:])

        #expect(!report.allConfirmed)
        #expect(report.failedOwners == Owner.allCases)
    }

    @Test
    func diagnosticCodeIsCompactDeterministicAndContainsNoStorageDetails() {
        let report = PanicStartupCleanupReport(confirmations: [
            .legacyGroupKeys: false,
            .sharedContent: false,
            .sightings: true,
            .geography: true,
            .board: true,
            .bridge: true,
            .groups: true,
            .media: true
        ])

        #expect(report.diagnosticCode == "startup_cleanup/failed/shared,group_keys")
        #expect(!report.diagnosticCode.contains("/Library/"))
        #expect(!report.diagnosticCode.contains("meshSightings"))
    }

    @MainActor
    private func makeDecision(
        failing owners: Set<Owner>,
        usingRetry: Bool = false,
        didAttempt: @escaping (Owner) -> Void = { _ in }
    ) -> PanicStartupDecision {
        let wipe: (Owner) -> Bool = { owner in
            didAttempt(owner)
            return !owners.contains(owner)
        }
        let arguments = (
            checkPending: { false },
            wipeSightings: { wipe(.sightings) },
            wipeGeography: { wipe(.geography) },
            wipeSharedContent: { wipe(.sharedContent) },
            wipeBoard: { wipe(.board) },
            wipeBridge: { wipe(.bridge) },
            wipeGroups: { wipe(.groups) },
            wipeMedia: { wipe(.media) },
            wipeLegacyGroupKeys: { wipe(.legacyGroupKeys) }
        )

        if usingRetry {
            return PanicStartupDecision.retry(
                checkPending: arguments.checkPending,
                wipeSightings: arguments.wipeSightings,
                wipeGeography: arguments.wipeGeography,
                wipeSharedContent: arguments.wipeSharedContent,
                wipeBoard: arguments.wipeBoard,
                wipeBridge: arguments.wipeBridge,
                wipeGroups: arguments.wipeGroups,
                wipeMedia: arguments.wipeMedia,
                wipeLegacyGroupKeys: arguments.wipeLegacyGroupKeys
            )
        }
        return PanicStartupDecision.preflight(
            checkPending: arguments.checkPending,
            wipeSightings: arguments.wipeSightings,
            wipeGeography: arguments.wipeGeography,
            wipeSharedContent: arguments.wipeSharedContent,
            wipeBoard: arguments.wipeBoard,
            wipeBridge: arguments.wipeBridge,
            wipeGroups: arguments.wipeGroups,
            wipeMedia: arguments.wipeMedia,
            wipeLegacyGroupKeys: arguments.wipeLegacyGroupKeys
        )
    }

    private enum MarkerFailure: Error { case unavailable }
}
