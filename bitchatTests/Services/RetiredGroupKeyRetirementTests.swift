import Foundation
import Security
import Testing
@testable import bitchat

/// Required metadata/status ports exercise the production path using RAM only.
@MainActor
struct RetiredGroupKeyRetirementTests {
    enum MalformedInventory: CaseIterable {
        case missing, payload, singleRecord, mixedArray, missingAccount, missingService, invalidAccessGroup
    }

    @Test
    func exactHistoricalAccountsAreDeletedWithTheirReturnedScopeAndVerifiedIndependently() {
        let fixture = GroupKeyMetadataFixture()
        let neighbors = fixture.items.filter { !$0.isRetired }

        #expect(fixture.retire())

        #expect(fixture.items == neighbors)
        #expect(fixture.queries.count == 2)
        #expect(fixture.deletions.count == 2)
        #expect(fixture.deletedScopes == Set(fixture.initialRetiredScopes))
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test(arguments: [false, true])
    func emptyAndItemNotFoundInventoriesConfirmAbsenceWithoutMutation(itemNotFound: Bool) {
        let fixture = GroupKeyMetadataFixture(includeRetired: false)
        let before = fixture.items
        if itemNotFound { fixture.replies[1] = (errSecItemNotFound, nil) }

        #expect(fixture.retire())

        #expect(fixture.items == before)
        #expect(fixture.queries.count == 1)
        #expect(fixture.deletions.isEmpty)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
                      OSStatus(-34018), errSecParam])
    func unavailableInventoryCannotConfirmRetirementOrAuthorizeDeletion(status: OSStatus) {
        let fixture = GroupKeyMetadataFixture()
        let before = fixture.items
        fixture.replies[1] = (status, nil)

        #expect(!fixture.retire())

        #expect(fixture.items == before)
        #expect(fixture.deletions.isEmpty)
        #expect(fixture.queries.count == 1)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test(arguments: MalformedInventory.allCases)
    func malformedSuccessfulInventoryCannotAuthorizeGuessedDeletion(kind: MalformedInventory) {
        let fixture = GroupKeyMetadataFixture()
        let before = fixture.items
        let record = fixture.items[0].attributes
        let value: Any?
        switch kind {
        case .missing: value = nil
        case .payload: value = Data("synthetic unrelated bytes".utf8)
        case .singleRecord: value = record
        case .mixedArray: value = ["not an attribute dictionary"]
        case .missingAccount: value = [[kSecAttrService as String: GroupKeyMetadataFixture.service]]
        case .missingService: value = [[kSecAttrAccount as String: GroupKeyMetadataFixture.firstAccount]]
        case .invalidAccessGroup:
            var invalid = record
            invalid[kSecAttrAccessGroup as String] = 42
            value = [invalid]
        }
        fixture.replies[1] = (errSecSuccess, value)

        #expect(!fixture.retire())

        #expect(fixture.items == before)
        #expect(fixture.deletions.isEmpty)
        #expect(fixture.queries.count == 1)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test
    func oneDeleteRefusalStillAttemptsEveryIdentifiedAccountAndFinalReadback() {
        let fixture = GroupKeyMetadataFixture()
        fixture.deleteStatuses[GroupKeyMetadataFixture.firstAccount] = errSecInteractionNotAllowed

        #expect(!fixture.retire())

        #expect(fixture.deletions.count == 2)
        #expect(fixture.queries.count == 2)
        #expect(fixture.items.filter(\.isRetired).map(\.account) == [GroupKeyMetadataFixture.firstAccount])
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test
    func aSuccessfulDeleteCannotHideAnAccountThatRemainsInIndependentReadback() {
        let fixture = GroupKeyMetadataFixture()
        fixture.stickyAccounts.insert(GroupKeyMetadataFixture.firstAccount)

        #expect(!fixture.retire())

        #expect(fixture.deletions.count == 2)
        #expect(fixture.queries.count == 2)
        #expect(fixture.items.contains { $0.account == GroupKeyMetadataFixture.firstAccount })
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func failedFinalInventoryCannotReportConfirmedAbsence(status: OSStatus) {
        let fixture = GroupKeyMetadataFixture()
        fixture.replies[2] = (status, nil)

        #expect(!fixture.retire())

        #expect(fixture.items.allSatisfy { !$0.isRetired })
        #expect(fixture.deletions.count == 2)
        #expect(fixture.queries.count == 2)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test
    func malformedFinalInventoryCannotTurnDeletionSubmissionIntoConfirmation() {
        let fixture = GroupKeyMetadataFixture()
        fixture.replies[2] = (errSecSuccess, nil)

        #expect(!fixture.retire())

        #expect(fixture.deletions.count == 2)
        #expect(fixture.queries.count == 2)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test
    func alreadyRemovedItemIsAcceptedOnlyAfterIndependentAbsence() {
        let fixture = GroupKeyMetadataFixture()
        fixture.deleteStatuses[GroupKeyMetadataFixture.firstAccount] = errSecItemNotFound

        #expect(fixture.retire())

        #expect(fixture.items.allSatisfy { !$0.isRetired })
        #expect(fixture.deletions.count == 2)
        #expect(fixture.queries.count == 2)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test
    func nearMissActiveAndForeignServiceRecordsKeepTheirOpaqueBytes() {
        let fixture = GroupKeyMetadataFixture(includeRetired: false)
        let before = fixture.items
        // Even a foreign-service row in a returned inventory cannot broaden deletion.
        fixture.replies[1] = (errSecSuccess, before.map(\.attributes))

        #expect(fixture.retire())

        #expect(fixture.items == before)
        #expect(fixture.deletions.isEmpty)
        #expect(fixture.queryViolations.isEmpty)
    }

    @Test(arguments: GroupKeyStartupFixture.owners)
    func allEightOwnersAreAttemptedAndAnyRefusalBlocksWithoutAuthorizingPanic(failedOwner: String) {
        let fixture = GroupKeyStartupFixture()
        fixture.failedOwner = failedOwner

        let decision = fixture.decision()

        #expect(fixture.attempts == GroupKeyStartupFixture.owners)
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        #expect(fixture.markerReads == 1)
    }

    @Test
    func explicitRetryKeepsKeyRefusalBlockedUntilTheEighthOwnerConfirms() {
        let fixture = GroupKeyStartupFixture()
        fixture.failedOwner = "groupKeys"

        let failed = fixture.decision(retry: true)
        #expect(failed.suspendTransport)
        #expect(failed.blockOrdinaryAdmission)
        #expect(!failed.replayPanic)
        fixture.failedOwner = nil

        let confirmed = fixture.decision(retry: true)
        #expect(!confirmed.suspendTransport)
        #expect(!confirmed.blockOrdinaryAdmission)
        #expect(!confirmed.replayPanic)
        #expect(fixture.attempts == GroupKeyStartupFixture.owners + GroupKeyStartupFixture.owners)
        #expect(fixture.markerReads == 2)
    }

    @Test(arguments: [false, true])
    func pendingOrUnknownMarkerRetainsItsExistingFullRecoveryAuthority(unreadable: Bool) {
        let fixture = GroupKeyStartupFixture()
        fixture.pending = true
        fixture.markerUnreadable = unreadable

        let initial = fixture.decision()
        let retry = fixture.decision(retry: true)

        #expect(initial.replayPanic && initial.suspendTransport)
        #expect(retry.replayPanic && retry.suspendTransport)
        #expect(fixture.markerReads == 2)
    }
}

@MainActor
private final class GroupKeyMetadataFixture {
    static let service = "synthetic.wesh.current"
    static let firstAccount = "identity_groupKey-" + String(repeating: "1a", count: 16)
    private static let secondAccount = "identity_groupKey-" + String(repeating: "2b", count: 16)

    struct Item: Equatable {
        let service: String
        let account: String
        let accessGroup: String
        let opaqueBytes: Data
        let isRetired: Bool

        var attributes: [String: Any] {
            [kSecAttrService as String: service, kSecAttrAccount as String: account,
             kSecAttrAccessGroup as String: accessGroup]
        }
        var scope: String { service + "|" + account + "|" + accessGroup }
    }

    var items: [Item] = []
    private(set) var initialRetiredScopes: [String] = []
    var replies: [Int: (OSStatus, Any?)] = [:]
    var deleteStatuses: [String: OSStatus] = [:]
    var stickyAccounts = Set<String>()
    private(set) var queries: [[String: Any]] = []
    private(set) var deletions: [[String: Any]] = []
    private(set) var queryViolations: [String] = []

    init(includeRetired: Bool = true) {
        let prefix = "identity_groupKey-"
        let preserved = ["identity_noiseStaticKey", "identity_ed25519SigningKey", "prekeysV1",
                         "wesh.qr.contacts", "wesh.meeting-note", "wesh.draft", "outbox",
                         "groupKey-" + String(repeating: "ab", count: 16),
                         prefix + String(repeating: "a", count: 31),
                         prefix + String(repeating: "a", count: 33),
                         prefix + String(repeating: "A", count: 32),
                         prefix + String(repeating: "g", count: 32),
                         prefix + String(repeating: "a", count: 32) + "-old"]
        items = preserved.enumerated().map { index, account in
            Item(service: Self.service, account: account, accessGroup: "synthetic.default",
                 opaqueBytes: Data("synthetic preserved \(index)".utf8), isRetired: false)
        }
        items.append(Item(service: "synthetic.other-app", account: Self.firstAccount,
                          accessGroup: "synthetic.foreign", opaqueBytes: Data("foreign sentinel".utf8), isRetired: false))
        if includeRetired {
            items.insert(Item(service: Self.service, account: Self.secondAccount, accessGroup: "synthetic.second",
                              opaqueBytes: Data("retired second".utf8), isRetired: true), at: 0)
            items.insert(Item(service: Self.service, account: Self.firstAccount, accessGroup: "synthetic.first",
                              opaqueBytes: Data("retired first".utf8), isRetired: true), at: 0)
        }
        initialRetiredScopes = items.filter(\.isRetired).map(\.scope)
    }

    var deletedScopes: Set<String> {
        Set(deletions.map {
            ($0[kSecAttrService as String] as? String ?? "") + "|"
                + ($0[kSecAttrAccount as String] as? String ?? "") + "|"
                + ($0[kSecAttrAccessGroup as String] as? String ?? "")
        })
    }

    func retire() -> Bool {
        KeychainManager.retireLegacyGroupKeys(primaryService: Self.service,
                                             copyAttributes: copyAttributes, deleteItem: deleteItem)
    }

    private func copyAttributes(_ query: [String: Any]) -> (OSStatus, Any?) {
        queries.append(query)
        let allowed = Set([kSecClass, kSecAttrService, kSecMatchLimit,
                           kSecReturnAttributes, kSecAttrSynchronizable].map { $0 as String })
        guard Set(query.keys).isSubset(of: allowed),
              query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              query[kSecAttrService as String] as? String == Self.service,
              query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String,
              query[kSecReturnAttributes as String] as? Bool == true,
              query[kSecAttrSynchronizable as String] as? Bool == false else {
            queryViolations.append("Inventory must request only current-service nonsynchronizable attributes")
            return (errSecParam, nil)
        }
        if let reply = replies[queries.count] { return reply }
        return (errSecSuccess, items.filter { $0.service == Self.service }.map(\.attributes))
    }

    private func deleteItem(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        let allowed = Set([kSecClass, kSecAttrService, kSecAttrAccount,
                           kSecAttrAccessGroup, kSecAttrSynchronizable].map { $0 as String })
        guard Set(query.keys).isSubset(of: allowed),
              query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              query[kSecAttrService as String] as? String == Self.service,
              query[kSecAttrSynchronizable as String] as? Bool == false,
              let account = query[kSecAttrAccount as String] as? String,
              let accessGroup = query[kSecAttrAccessGroup as String] as? String,
              let index = items.firstIndex(where: {
                  $0.service == Self.service && $0.account == account && $0.accessGroup == accessGroup && $0.isRetired
              }) else {
            queryViolations.append("Deletion must identify one returned historical account and access group")
            return errSecParam
        }
        let status = deleteStatuses[account] ?? errSecSuccess
        if (status == errSecSuccess || status == errSecItemNotFound) && !stickyAccounts.contains(account) {
            items.remove(at: index)
        }
        return status
    }
}

@MainActor
private final class GroupKeyStartupFixture {
    static let owners = ["sightings", "geography", "sharedContent", "board", "bridge", "groups", "media", "groupKeys"]
    var failedOwner: String?
    var pending = false
    var markerUnreadable = false
    private(set) var markerReads = 0
    private(set) var attempts: [String] = []
    private enum MarkerFailure: Error { case unavailable }

    func decision(retry: Bool = false) -> PanicStartupDecision {
        let marker = {
            self.markerReads += 1
            if self.markerUnreadable { throw MarkerFailure.unavailable }
            return self.pending
        }
        let sightings = { self.cleanup("sightings") }
        let geography = { self.cleanup("geography") }
        let sharedContent = { self.cleanup("sharedContent") }
        let board = { self.cleanup("board") }
        let bridge = { self.cleanup("bridge") }
        let groups = { self.cleanup("groups") }
        let media = { self.cleanup("media") }
        let keys = { self.cleanup("groupKeys") }
        if retry {
            return PanicStartupDecision.retry(checkPending: marker, wipeSightings: sightings, wipeGeography: geography,
                wipeSharedContent: sharedContent, wipeBoard: board, wipeBridge: bridge,
                wipeGroups: groups, wipeMedia: media, wipeLegacyGroupKeys: keys)
        }
        return PanicStartupDecision.preflight(checkPending: marker, wipeSightings: sightings, wipeGeography: geography,
            wipeSharedContent: sharedContent, wipeBoard: board, wipeBridge: bridge,
            wipeGroups: groups, wipeMedia: media, wipeLegacyGroupKeys: keys)
    }

    private func cleanup(_ owner: String) -> Bool {
        attempts.append(owner)
        return failedOwner != owner
    }
}
