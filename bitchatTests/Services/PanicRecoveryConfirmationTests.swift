// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

@MainActor
struct PanicRecoveryConfirmationTests {
    @Test(arguments: [false, true])
    func coldCleanupFailureThenPendingOrUnreadableMarkerNeedsActivationAfterConfirmedPanic(markerUnreadable: Bool) {
        let initial = PanicStartupDecision(recoveryPending: false, legacySightingsConfirmed: false)
        #expect(initial.suspendTransport)
        #expect(initial.blockOrdinaryAdmission)
        #expect(!initial.replayPanic)
        let retry = PanicStartupDecision.retry(checkPending: {
            if markerUnreadable { throw MarkerFailure.unavailable }
            return true
        }, wipeSightings: { true }, wipeGeography: { true }, wipeSharedContent: { true }, wipeBoard: { true }, wipeBridge: { true })
        #expect(retry.replayPanic)
        #expect(retry.suspendTransport)

        let fixture = ActivationFixture()
        let confirmedAction = fixture.confirmation()
        #expect(fixture.bootstrapCalls == 0)
        #expect(fixture.runtimeStarts == 0)

        confirmedAction()

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [true])
        #expect(fixture.bootstrapCalls == 1)
        #expect(fixture.runtimeStarts == 1)
        #expect(fixture.bootstrapConfigured)
        #expect(fixture.runtimeStarted)

        // A later explicit confirmation must not install bindings or start
        // the runtime a second time, even though erase itself runs again.
        confirmedAction()
        #expect(fixture.eraseCalls == 2)
        #expect(fixture.reports == [true, true])
        #expect(fixture.bootstrapCalls == 1)
        #expect(fixture.runtimeStarts == 1)
    }

    @Test
    func failedConfirmedEraseNeverBootstrapsOrStartsTheRuntime() {
        let fixture = ActivationFixture()
        fixture.eraseSucceeds = false

        fixture.confirmation()()

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [false])
        #expect(fixture.bootstrapCalls == 0)
        #expect(fixture.runtimeStarts == 0)
        #expect(!fixture.bootstrapConfigured)
        #expect(!fixture.runtimeStarted)
    }

    @Test
    func alreadyConfiguredRuntimeReceivesNoDuplicateBootstrapOrStart() {
        let fixture = ActivationFixture(bootstrapConfigured: true, runtimeStarted: true)

        fixture.confirmation()()

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [true])
        #expect(fixture.bootstrapCalls == 0)
        #expect(fixture.runtimeStarts == 0)
    }

    private enum MarkerFailure: Error { case unavailable }
}

@MainActor
private final class ActivationFixture {
    var bootstrapConfigured: Bool
    var runtimeStarted: Bool
    var eraseSucceeds = true
    private(set) var eraseCalls = 0
    private(set) var reports: [Bool] = []
    private(set) var bootstrapCalls = 0
    private(set) var runtimeStarts = 0

    init(bootstrapConfigured: Bool = false, runtimeStarted: Bool = false) {
        self.bootstrapConfigured = bootstrapConfigured
        self.runtimeStarted = runtimeStarted
    }

    func confirmation() -> () -> Void {
        let action = makePanicEraseAction(erase: {
            self.eraseCalls += 1
            return self.eraseSucceeds
        }, report: { self.reports.append($0) },
        needsBootstrap: { !self.bootstrapConfigured }, bootstrap: {
            self.bootstrapCalls += 1
            self.bootstrapConfigured = true
        }, needsRuntimeStart: { !self.runtimeStarted }, startRuntime: {
            self.runtimeStarts += 1
            self.runtimeStarted = true
        })
        return { _ = action() }
    }
}
