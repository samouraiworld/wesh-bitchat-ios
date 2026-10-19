// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

enum PanicOwnerGap: Equatable {
    case checkedProducerMissing
}

enum PanicOwnerStatus: Equatable {
    case confirmed
    case unconfirmed(PanicOwnerGap)
}

/// Evidence about old work only. Deletion results and permission to create a
/// successor identity belong to later phases, after this admission boundary.
struct PanicAppOwnerReport: Equatable {
    let localPersistenceAndEditors: PanicOwnerStatus
    let meshAndGossipCallbacks: PanicOwnerStatus
    let nostrOutboundAndAckTasks: PanicOwnerStatus
    let nostrInboundKeyUsers: PanicOwnerStatus
    let remainingApplicationKeyUsers: PanicOwnerStatus
    let startupProducers: PanicOwnerStatus
    let internalCryptoOwners: PanicOwnerStatus
}

enum PanicAppOwnerAdmission {
    /// No checked aggregate producer exists yet. Cancel requests, delivery
    /// generations and Unit returns cannot certify that old key users exited.
    static func liveUnconfirmed() -> PanicAppOwnerReport {
        PanicAppOwnerReport(
            localPersistenceAndEditors: .unconfirmed(.checkedProducerMissing),
            meshAndGossipCallbacks: .unconfirmed(.checkedProducerMissing),
            nostrOutboundAndAckTasks: .unconfirmed(.checkedProducerMissing),
            nostrInboundKeyUsers: .unconfirmed(.checkedProducerMissing),
            remainingApplicationKeyUsers: .unconfirmed(.checkedProducerMissing),
            startupProducers: .unconfirmed(.checkedProducerMissing),
            internalCryptoOwners: .unconfirmed(.checkedProducerMissing)
        )
    }
}

/// Collects one captured value before the application key/store continuation.
/// Earlier network cleanup and protective RAM fences remain outside this scope.
@MainActor
func admitPanicApplicationErasure(
    intent: PanicRecoveryIntent,
    collectOwners: @MainActor () -> PanicAppOwnerReport,
    eraseApplicationData: @MainActor (PanicRecoveryIntent, PanicAppOwnerReport) -> Bool
) -> Bool {
    let report = collectOwners()
    guard report.localPersistenceAndEditors == .confirmed,
          report.meshAndGossipCallbacks == .confirmed,
          report.nostrOutboundAndAckTasks == .confirmed,
          report.nostrInboundKeyUsers == .confirmed,
          report.remainingApplicationKeyUsers == .confirmed,
          report.startupProducers == .confirmed,
          report.internalCryptoOwners == .confirmed else { return false }
    return eraseApplicationData(intent, report)
}
