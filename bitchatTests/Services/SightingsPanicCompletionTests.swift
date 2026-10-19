// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

struct SightingsPanicCompletionTests {
    @Test func unconfirmedSightingsCleanupKeepsTheGlobalMarkerUntilRetryConfirmsIt() throws {
        let fixture = SightingsMarkerFixture()
        let operations = fixture.operations
        _ = operations.begin()

        #expect(try !operations.completeIfConfirmed(existingStoreResults: [true, true], legacySightingsConfirmed: false))
        #expect(try operations.isPending())
        #expect(fixture.completions == 0)

        #expect(try operations.completeIfConfirmed(existingStoreResults: [true, true], legacySightingsConfirmed: true))
        #expect(try !operations.isPending())
        #expect(fixture.completions == 1)
    }

    @Test func confirmedSightingsCleanupDoesNotCompensateForAnyOtherFailedStore() throws {
        for results in [[false, true], [true, false]] {
            let fixture = SightingsMarkerFixture()
            let operations = fixture.operations
            _ = operations.begin()
            #expect(try !operations.completeIfConfirmed(existingStoreResults: results, legacySightingsConfirmed: true))
            #expect(try operations.isPending())
            #expect(fixture.completions == 0)
        }
    }

    @Test func confirmedStoresCompleteTheRealInjectedMarkerOperation() throws {
        let fixture = SightingsMarkerFixture()
        let operations = fixture.operations
        _ = operations.begin()
        #expect(try operations.completeIfConfirmed(existingStoreResults: [true, true], legacySightingsConfirmed: true))
        #expect(try !operations.isPending())
        #expect(fixture.completions == 1)
    }

    @Test func markerCommitFailurePropagatesAndLeavesRecoveryPending() throws {
        let fixture = SightingsMarkerFixture()
        let operations = fixture.operations
        _ = operations.begin()
        fixture.rejectCommit = true
        #expect(throws: SightingsMarkerFixture.Failure.unavailable) {
            try operations.completeIfConfirmed(existingStoreResults: [true], legacySightingsConfirmed: true)
        }
        #expect(try operations.isPending())
        #expect(fixture.completions == 0)
    }
}

private final class SightingsMarkerFixture {
    enum Failure: Error, Equatable { case unavailable }
    var pending = false
    var completions = 0
    var rejectCommit = false

    var operations: PanicRecoveryOperations {
        PanicRecoveryOperations(collectAppOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork, isPending: { self.pending }, begin: {
            self.pending = true
            return PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: {
            if self.rejectCommit { throw Failure.unavailable }
            self.completions += 1
            self.pending = false
        })
    }
}
