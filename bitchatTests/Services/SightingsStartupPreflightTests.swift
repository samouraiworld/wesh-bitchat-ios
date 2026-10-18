// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

struct SightingsStartupPreflightTests {
    @Test func confirmedCleanupOnOrdinaryLaunchPreservesNormalAdmission() {
        let decision = PanicStartupDecision(recoveryPending: false, legacySightingsConfirmed: true)
        #expect(!decision.suspendTransport)
        #expect(!decision.replayPanic)
        #expect(!decision.blockOrdinaryAdmission)
    }

    @Test func failedCleanupBlocksOrdinaryAdmissionWithoutAuthorizingAFullPanic() {
        let decision = PanicStartupDecision(recoveryPending: false, legacySightingsConfirmed: false)
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
    }

    @Test func anActualPendingMarkerStillRequiresTransportSuspensionAndFullRecovery() {
        let decision = PanicStartupDecision(recoveryPending: true, legacySightingsConfirmed: false)
        #expect(decision.suspendTransport)
        #expect(decision.replayPanic)
    }

    @Test func cleanupSuccessCannotBypassAnActualPendingPanicMarker() {
        let decision = PanicStartupDecision(recoveryPending: true, legacySightingsConfirmed: true)
        #expect(decision.suspendTransport)
        #expect(decision.replayPanic)
        #expect(!decision.blockOrdinaryAdmission)
    }

    @Test @MainActor
    func explicitOrdinaryRetryChecksCleanupAgainUntilItConfirmsWithoutRequestingPanic() {
        var cleanupCalls = 0
        var cleanupSucceeds = false
        let cleanup = {
            cleanupCalls += 1
            return cleanupSucceeds
        }
        let failed = PanicStartupDecision.retry(checkPending: { false }, wipeSightings: cleanup, wipeGeography: { true }, wipeSharedContent: { true }, wipeBoard: { true }, wipeBridge: { true })
        #expect(failed.blockOrdinaryAdmission)
        #expect(failed.suspendTransport)
        #expect(!failed.replayPanic)
        cleanupSucceeds = true

        let confirmed = PanicStartupDecision.retry(checkPending: { false }, wipeSightings: cleanup, wipeGeography: { true }, wipeSharedContent: { true }, wipeBoard: { true }, wipeBridge: { true })

        #expect(!confirmed.blockOrdinaryAdmission)
        #expect(!confirmed.suspendTransport)
        #expect(!confirmed.replayPanic)
        #expect(cleanupCalls == 2)
    }

    @Test @MainActor
    func newlyPendingMarkerCannotBeClearedByOrdinaryCleanupRetry() {
        let decision = PanicStartupDecision.retry(checkPending: { true }, wipeSightings: { true }, wipeGeography: { true }, wipeSharedContent: { true }, wipeBoard: { true }, wipeBridge: { true })
        #expect(decision.replayPanic)
        #expect(decision.suspendTransport)
    }

    @Test @MainActor
    func unreadablePendingMarkerNeverReopensOrdinaryAdmission() {
        let decision = PanicStartupDecision.retry(checkPending: { throw MarkerFailure.unavailable }, wipeSightings: { true }, wipeGeography: { true }, wipeSharedContent: { true }, wipeBoard: { true }, wipeBridge: { true })
        #expect(decision.replayPanic)
        #expect(decision.suspendTransport)
    }

    private enum MarkerFailure: Error { case unavailable }
}
