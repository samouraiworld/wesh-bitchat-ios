// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

@MainActor
struct PanicAppOwnerAdmissionTests {
    @Test
    func liveUnconfirmedOwnersBlockApplicationErasureAndKeepIntentPending() {
        let fixture = PanicAppOwnerMarkerFixture(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: PanicAppOwnerAdmission.liveUnconfirmed
        )
        let completed = fixture.perform()

        #expect(fixture.begins == 1)
        #expect(fixture.collections == 1)
        #expect(fixture.eraseEntries == 0)
        #expect(fixture.pending)
        #expect(!completed)
    }

    @Test
    func everySingleUnconfirmedOldOwnerBlocksBeforeAnyApplicationErase() {
        var entries: [Int] = []
        var pending: [Bool] = []
        var completed: [Bool] = []
        for boundary in PanicAppOwnerAdmissionFixture.Boundary.allCases {
            let report = PanicAppOwnerAdmissionFixture.singleUnconfirmed(boundary)
            let fixture = PanicAppOwnerMarkerFixture(
                intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
                collectOwners: { report }
            )
            completed.append(fixture.perform())
            entries.append(fixture.eraseEntries)
            pending.append(fixture.pending)
        }

        // Every boundary executes before these nonfatal matrix assertions.
        #expect(entries.count == 7)
        #expect(entries == Array(repeating: 0, count: 7))
        #expect(pending == Array(repeating: true, count: 7))
        #expect(completed == Array(repeating: false, count: 7))
    }

    @Test
    func liveUnconfirmedEraseActionReportsFailureWithoutActivation() {
        let fixture = PanicAppOwnerMarkerFixture(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: PanicAppOwnerAdmission.liveUnconfirmed
        )
        var reports: [Bool] = []
        var bootstrapCalls = 0
        var runtimeStarts = 0
        let action = makePanicEraseAction(
            erase: fixture.perform, report: { reports.append($0) },
            needsBootstrap: { true }, bootstrap: { bootstrapCalls += 1 },
            needsRuntimeStart: { true }, startRuntime: { runtimeStarts += 1 }
        )
        let completed = action()

        #expect(!completed)
        #expect(reports == [false])
        #expect(bootstrapCalls == 0)
        #expect(runtimeStarts == 0)
    }

    @Test
    func confirmedInertOwnersPassFullCollectedValueExactlyOnce() {
        let report = PanicAppOwnerAdmissionFixture.confirmedNoWork()
        let fixture = PanicAppOwnerMarkerFixture(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: { report }
        )
        let completed = fixture.perform()
        let receivedFlags = fixture.receivedIntents.map {
            [$0.fileMarkerEstablished, $0.externalMarkerEstablished]
        }

        #expect(completed)
        #expect(fixture.begins == 1)
        #expect(fixture.collections == 1)
        #expect(fixture.eraseEntries == 1)
        #expect(fixture.receivedReports == [report])
        #expect(receivedFlags == [[true, false]])
        #expect(fixture.completions == 1)
    }

    @Test
    func allIntentFlagValuesPassThroughUnchanged() {
        let expected = [[false, false], [true, false], [false, true], [true, true]]
        var received: [[Bool]] = []
        var results: [Bool] = []
        for flags in expected {
            let fixture = PanicAppOwnerMarkerFixture(
                intent: PanicRecoveryIntent(fileMarkerEstablished: flags[0], externalMarkerEstablished: flags[1]),
                collectOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork
            )
            results.append(fixture.perform())
            received.append(contentsOf: fixture.receivedIntents.map {
                [$0.fileMarkerEstablished, $0.externalMarkerEstablished]
            })
        }

        #expect(received == expected)
        #expect(results == [true, true, true, true])
    }

    @Test
    func falseFromApplicationContinuationIsReturnedUnchanged() {
        var collections = 0
        var entries = 0
        let completed = admitPanicApplicationErasure(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: {
                collections += 1
                return PanicAppOwnerAdmissionFixture.confirmedNoWork()
            },
            eraseApplicationData: { _, _ in entries += 1; return false }
        )

        #expect(!completed)
        #expect(collections == 1)
        #expect(entries == 1)
    }

    @Test
    func liveCollectorExplicitlyLeavesAllSevenMissingProducersUnconfirmed() {
        let report = PanicAppOwnerAdmission.liveUnconfirmed()
        let expected = PanicAppOwnerReport(
            localPersistenceAndEditors: .unconfirmed(.checkedProducerMissing),
            meshAndGossipCallbacks: .unconfirmed(.checkedProducerMissing),
            nostrOutboundAndAckTasks: .unconfirmed(.checkedProducerMissing),
            nostrInboundKeyUsers: .unconfirmed(.checkedProducerMissing),
            remainingApplicationKeyUsers: .unconfirmed(.checkedProducerMissing),
            startupProducers: .unconfirmed(.checkedProducerMissing),
            internalCryptoOwners: .unconfirmed(.checkedProducerMissing)
        )

        #expect(report == expected)
    }

    @Test
    func collectionPrecedesApplicationContinuationExactlyOnce() {
        let fixture = PanicAppOwnerMarkerFixture(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork
        )
        _ = fixture.perform()

        #expect(fixture.ledger == ["collect", "erase"])
        #expect(fixture.collections == 1)
    }

    @Test
    func existingFinalStoreAndSightingsRefusalsRemainBlocked() {
        var completed: [Bool] = []
        var pending: [Bool] = []
        var completions: [Int] = []
        for refused in 0..<16 {
            let fixture = PanicAppOwnerMarkerFixture(
                intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
                collectOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork
            )
            if refused < 15 { fixture.storeResults[refused] = false }
            else { fixture.sightingsConfirmed = false }
            completed.append(fixture.perform())
            pending.append(fixture.pending)
            completions.append(fixture.completions)
        }

        #expect(completed == Array(repeating: false, count: 16))
        #expect(pending == Array(repeating: true, count: 16))
        #expect(completions == Array(repeating: 0, count: 16))
    }

    @Test
    func existingMarkerCommitErrorRemainsHandledInsideContinuation() {
        let fixture = PanicAppOwnerMarkerFixture(
            intent: PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false),
            collectOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork
        )
        fixture.rejectCommit = true
        let completed = fixture.perform()

        #expect(!completed)
        #expect(fixture.pending)
        #expect(fixture.completionAttempts == 1)
        #expect(fixture.completions == 0)
        #expect(fixture.caughtErrors == 1)
    }
}
