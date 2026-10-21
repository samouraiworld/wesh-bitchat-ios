// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

@MainActor
struct PanicEraseActionTests {
    @Test
    func coldBlockedHostShortcutReturnsSuccessAndActivatesExactlyOnceAfterConfirmedErase() {
        let initial = PanicStartupDecision(recoveryPending: false, legacySightingsConfirmed: false)
        #expect(initial.suspendTransport)
        #expect(initial.blockOrdinaryAdmission)
        let fixture = BoolEraseFixture()
        let holdAction = fixture.action()

        #expect(holdAction())

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [true])
        #expect(fixture.bootstrapCalls == 1)
        #expect(fixture.runtimeStarts == 1)
        #expect(fixture.bootstrapConfigured)
        #expect(fixture.runtimeStarted)

        #expect(holdAction())
        #expect(fixture.eraseCalls == 2)
        #expect(fixture.reports == [true, true])
        #expect(fixture.bootstrapCalls == 1)
        #expect(fixture.runtimeStarts == 1)
    }

    @Test
    func unconfirmedShortcutEraseReturnsFalseAndStillActivatesAFreshStart() {
        let fixture = BoolEraseFixture()
        fixture.eraseSucceeds = false

        #expect(!fixture.action()())

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [false])
        #expect(fixture.bootstrapCalls == 1)
        #expect(fixture.runtimeStarts == 1)
    }

    @Test
    func configuredShortcutPreservesSuccessWithoutDuplicateActivation() {
        let fixture = BoolEraseFixture(bootstrapConfigured: true, runtimeStarted: true)

        #expect(fixture.action()())

        #expect(fixture.eraseCalls == 1)
        #expect(fixture.reports == [true])
        #expect(fixture.bootstrapCalls == 0)
        #expect(fixture.runtimeStarts == 0)
    }
}

@MainActor
private final class BoolEraseFixture {
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

    func action() -> () -> Bool {
        makePanicEraseAction(erase: {
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
    }
}
