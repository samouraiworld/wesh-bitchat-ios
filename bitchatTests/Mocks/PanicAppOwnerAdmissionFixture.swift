// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

@testable import bitchat

/// Explicit confirmations for fixtures with controlled inert owners only.
/// No application, platform service, persistence backend or key is constructed.
enum PanicAppOwnerAdmissionFixture {
    enum Boundary: CaseIterable, Equatable {
        case localPersistenceAndEditors
        case meshAndGossipCallbacks
        case nostrOutboundAndAckTasks
        case nostrInboundKeyUsers
        case remainingApplicationKeyUsers
        case startupProducers
        case internalCryptoOwners
    }

    static func confirmedNoWork() -> PanicAppOwnerReport {
        PanicAppOwnerReport(
            localPersistenceAndEditors: .confirmed,
            meshAndGossipCallbacks: .confirmed,
            nostrOutboundAndAckTasks: .confirmed,
            nostrInboundKeyUsers: .confirmed,
            remainingApplicationKeyUsers: .confirmed,
            startupProducers: .confirmed,
            internalCryptoOwners: .confirmed
        )
    }

    static func singleUnconfirmed(_ boundary: Boundary) -> PanicAppOwnerReport {
        func status(_ selected: Boundary) -> PanicOwnerStatus {
            boundary == selected ? .unconfirmed(.checkedProducerMissing) : .confirmed
        }
        return PanicAppOwnerReport(
            localPersistenceAndEditors: status(.localPersistenceAndEditors),
            meshAndGossipCallbacks: status(.meshAndGossipCallbacks),
            nostrOutboundAndAckTasks: status(.nostrOutboundAndAckTasks),
            nostrInboundKeyUsers: status(.nostrInboundKeyUsers),
            remainingApplicationKeyUsers: status(.remainingApplicationKeyUsers),
            startupProducers: status(.startupProducers),
            internalCryptoOwners: status(.internalCryptoOwners)
        )
    }
}

/// Exercises the real admission and final marker helpers using RAM operations.
/// Its catch is a synthetic continuation contract, not the view model's catch.
@MainActor
final class PanicAppOwnerMarkerFixture {
    enum Failure: Error { case commitRefused }

    let intent: PanicRecoveryIntent
    private let collectOwners: @MainActor () -> PanicAppOwnerReport
    private(set) var pending = false
    private(set) var begins = 0
    private(set) var collections = 0
    private(set) var eraseEntries = 0
    private(set) var mediaCalls = 0
    private(set) var completionAttempts = 0
    private(set) var completions = 0
    private(set) var caughtErrors = 0
    private(set) var receivedIntents: [PanicRecoveryIntent] = []
    private(set) var receivedReports: [PanicAppOwnerReport] = []
    private(set) var ledger: [String] = []
    var rejectCommit = false
    var sightingsConfirmed = true
    // Keep the fifteen actual final store results explicit in the fixture.
    var storeResults = [
        true, true, true, true, true,
        true, true, true, true, true,
        true, true, true, true, true
    ]

    init(intent: PanicRecoveryIntent, collectOwners: @escaping @MainActor () -> PanicAppOwnerReport) {
        self.intent = intent
        self.collectOwners = collectOwners
    }

    var operations: PanicRecoveryOperations {
        PanicRecoveryOperations(
            collectAppOwners: {
                self.collections += 1
                self.ledger.append("collect")
                return self.collectOwners()
            },
            isPending: { self.pending },
            begin: {
                self.begins += 1
                self.pending = true
                return self.intent
            },
            wipeMedia: { _ in self.mediaCalls += 1 },
            complete: {
                self.completionAttempts += 1
                if self.rejectCommit { throw Failure.commitRefused }
                self.completions += 1
                self.pending = false
            }
        )
    }

    func perform() -> Bool {
        let operations = operations
        let capturedIntent = operations.begin()
        return admitPanicApplicationErasure(
            intent: capturedIntent, collectOwners: operations.collectAppOwners,
            eraseApplicationData: eraseApplicationData
        )
    }

    func eraseApplicationData(intent: PanicRecoveryIntent, report: PanicAppOwnerReport) -> Bool {
        eraseEntries += 1
        ledger.append("erase")
        receivedIntents.append(intent)
        receivedReports.append(report)
        let operations = operations
        do {
            try operations.wipeMedia(intent)
            return try operations.completeIfConfirmed(
                existingStoreResults: storeResults, legacySightingsConfirmed: sightingsConfirmed
            )
        } catch {
            caughtErrors += 1
            return false
        }
    }
}
