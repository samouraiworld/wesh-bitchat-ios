import Foundation
import Testing
@testable import bitchat

/// Actual retired-tree removal with owned fixture paths; no app graph or system-root lookup.
@MainActor
struct GroupMediaStartupPreflightTests {
    enum Failure: String, CaseIterable {
        case groupsRemoval, groupsSticky, groupsVerification
        case mediaRemoval, mediaSticky, mediaVerification

        var directory: String { rawValue.hasPrefix("groups") ? "groups" : "files" }
    }

    @Test
    func ordinaryStartupRemovesBothRetiredTreesBeforeAdmission() throws {
        let fixture = try GroupMediaFixture()
        defer { fixture.removeFixture() }
        var markerReads = 0

        let decision = fixture.decision(checkPending: { markerReads += 1; return false })

        #expect(markerReads == 1)
        #expect(!decision.suspendTransport)
        #expect(!decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        #expect(fixture.attempts == GroupMediaFixture.owners)
        fixture.expectErased()
        fixture.expectNoNewAuthority()
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: Failure.allCases)
    func actualTreeRemovalOrVerificationFailureBlocksWithoutAuthorizingPanic(failure: Failure) throws {
        let fixture = try GroupMediaFixture(failure: failure)
        defer { fixture.removeFixture() }

        let decision = fixture.decision()

        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        #expect(fixture.attempts == GroupMediaFixture.owners)
        fixture.expectNoNewAuthority()
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: GroupMediaFixture.owners)
    func everyIndependentOwnerIsAttemptedWhenAnyOneReportsFailure(failedOwner: String) throws {
        let fixture = try GroupMediaFixture()
        defer { fixture.removeFixture() }

        let decision = fixture.decision(failedOwner: failedOwner)

        #expect(fixture.attempts == GroupMediaFixture.owners)
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        fixture.expectErased()
        fixture.expectNoNewAuthority()
    }

    @Test(arguments: Failure.allCases)
    func explicitRetryRequiresBothRealErasersToConfirm(failure: Failure) throws {
        let fixture = try GroupMediaFixture(failure: failure)
        defer { fixture.removeFixture() }
        var markerReads = 0
        let checkPending = { markerReads += 1; return false }

        let failed = fixture.decision(retry: true, checkPending: checkPending)
        #expect(failed.suspendTransport)
        #expect(failed.blockOrdinaryAdmission)
        #expect(!failed.replayPanic)
        fixture.files.failure = nil

        let confirmed = fixture.decision(retry: true, checkPending: checkPending)
        #expect(!confirmed.suspendTransport)
        #expect(!confirmed.blockOrdinaryAdmission)
        #expect(!confirmed.replayPanic)
        #expect(markerReads == 2)
        #expect(fixture.attempts == GroupMediaFixture.owners + GroupMediaFixture.owners)
        fixture.expectErased()
        fixture.expectNoNewAuthority()
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: [false, true])
    func pendingOrUnreadableRecoveryStillRequiresFullRecoveryAndPreservesMarkerBytes(unreadable: Bool) throws {
        let fixture = try GroupMediaFixture(seedMarkers: true)
        defer { fixture.removeFixture() }
        var markerReads = 0
        let checkPending = {
            markerReads += 1
            if unreadable { throw SyntheticGroupMediaError.unavailable }
            return true
        }

        let initial = fixture.decision(checkPending: checkPending)
        #expect(initial.replayPanic)
        #expect(initial.suspendTransport)
        #expect(markerReads == 1)
        let retry = fixture.decision(retry: true, checkPending: checkPending)
        #expect(retry.replayPanic)
        #expect(retry.suspendTransport)
        #expect(markerReads == 2)
        #expect(fixture.markerWrites == 0)
        try fixture.expectMarkerBytesPreserved()
        try fixture.expectNeighborsPreserved()
    }

    @Test
    func absentTreesAreConfirmedWithoutCreatingOrEnumeratingPayloadDirectories() throws {
        let fixture = try GroupMediaFixture(seedPayload: false)
        defer { fixture.removeFixture() }

        #expect(fixture.eraseGroups())
        #expect(fixture.eraseMedia())

        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(fixture.files.operations == ["remove:groups", "attributes:groups", "remove:files", "attributes:files"])
        #expect(fixture.files.directoryCreations.isEmpty)
        #expect(fixture.files.payloadReads.isEmpty)
        #expect(fixture.files.enumerations.isEmpty)
        fixture.expectNoNewAuthority()
    }

    @Test
    func ordinaryMediaDefaultLookupNeverRequestsCreationOfAnAbsentRoot() throws {
        let fixture = try GroupMediaFixture(seedPayload: false)
        defer { fixture.removeFixture() }
        let store = PanicRecoveryFileStore(fileManager: fixture.files)

        #expect(PanicFileRemoval.removeLegacyMedia(fileStore: store))

        // The spy resolves only this owned nonexistent root, never the platform directory.
        #expect(!fixture.files.lookupCreates.contains(true))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(fixture.files.directoryCreations.isEmpty)
        #expect(fixture.files.payloadReads.isEmpty)
        #expect(fixture.files.enumerations.isEmpty)
        fixture.expectNoNewAuthority()
    }

    @Test
    func realErasersRemoveOpaquePayloadsUsingOnlyExactRemovalAndAbsenceProbes() throws {
        let fixture = try GroupMediaFixture()
        defer { fixture.removeFixture() }

        #expect(fixture.eraseGroups())
        #expect(fixture.eraseMedia())

        #expect(fixture.files.operations == ["remove:groups", "attributes:groups", "remove:files", "attributes:files"])
        #expect(fixture.files.payloadReads.isEmpty)
        #expect(fixture.files.enumerations.isEmpty)
        #expect(fixture.files.directoryCreations.isEmpty)
        fixture.expectErased()
        fixture.expectNoNewAuthority()
        try fixture.expectNeighborsPreserved()
    }

    @Test
    func unresolvedDefaultMediaRootReportsFailureWithoutTouchingAnyOtherPath() throws {
        let fixture = try GroupMediaFixture(seedPayload: false)
        defer { fixture.removeFixture() }
        fixture.files.refuseLookup = true

        #expect(!PanicFileRemoval.removeLegacyMedia(fileStore: PanicRecoveryFileStore(fileManager: fixture.files)))

        #expect(fixture.files.operations.isEmpty)
        #expect(fixture.files.directoryCreations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        fixture.expectNoNewAuthority()
    }
}

private enum SyntheticGroupMediaError: Error { case unavailable, forbidden }

@MainActor
private final class GroupMediaFixture {
    static let owners = ["sightings", "geography", "sharedContent", "board", "bridge", "groups", "media"]
    private static let payloads = [
        "groups/groups.json", "files/images/incoming/synthetic.jpg", "files/images/outgoing/synthetic.jpg",
        "files/voicenotes/incoming/synthetic.m4a", "files/voicenotes/outgoing/synthetic.m4a",
        "files/files/incoming/synthetic.bin", "files/.private-media-receipts/synthetic.json"
    ]
    private static let neighbors = [
        "courier/envelopes.json", "bitchat/arti/state/synthetic-state", "composer-drafts/wesh-v1.enc",
        "prekeys/bundles.json", "wesh-private/qr-contacts-v1.enc", "outbox/outbox.enc",
        "nostr/processed-events.json", "synthetic-unrelated.bin"
    ]
    private static let markers = [".panic-recovery-pending", ".panic-media-wipe-pending"]
    private static let sentinel = Data("Synthetic active state must survive".utf8)
    private static let markerBytes = Data("Synthetic existing recovery authority".utf8)
    let root: URL
    let files: GroupMediaFiles
    private(set) var attempts: [String] = []
    private(set) var markerWrites = 0

    init(failure: GroupMediaStartupPreflightTests.Failure? = nil,
         seedPayload: Bool = true, seedMarkers: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        files = GroupMediaFiles(root: root, failure: failure)
        do {
            if seedPayload {
                for name in Self.payloads { try seed(Data("Synthetic opaque invalid payload".utf8), at: name) }
                for name in Self.neighbors { try seed(Self.sentinel, at: name) }
            }
            if seedMarkers { for name in Self.markers { try seed(Self.markerBytes, at: name) } }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func eraseGroups() -> Bool {
        PanicFileRemoval.removeLegacyGroups(at: root, fileManager: files)
    }

    func eraseMedia() -> Bool {
        let store = PanicRecoveryFileStore(fileManager: files, baseDirectory: root, panicMarkerWriter: { _, _ in
            self.markerWrites += 1
            throw SyntheticGroupMediaError.forbidden
        })
        return PanicFileRemoval.removeLegacyMedia(fileStore: store)
    }

    func decision(retry: Bool = false, checkPending: () throws -> Bool = { false },
                  failedOwner: String? = nil) -> PanicStartupDecision {
        func result(_ owner: String, erase: () -> Bool = { true }) -> Bool {
            attempts.append(owner)
            let confirmed = erase()
            return confirmed && owner != failedOwner
        }
        let sightings = { result("sightings") }
        let geography = { result("geography") }
        let sharedContent = { result("sharedContent") }
        let board = { result("board") }
        let bridge = { result("bridge") }
        let groups = { result("groups", erase: self.eraseGroups) }
        let media = { result("media", erase: self.eraseMedia) }
        if retry {
            return PanicStartupDecision.retry(checkPending: checkPending,
                wipeSightings: sightings, wipeGeography: geography, wipeSharedContent: sharedContent,
                wipeBoard: board, wipeBridge: bridge, wipeGroups: groups, wipeMedia: media)
        }
        return PanicStartupDecision.preflight(checkPending: checkPending,
            wipeSightings: sightings, wipeGeography: geography, wipeSharedContent: sharedContent,
            wipeBoard: board, wipeBridge: bridge, wipeGroups: groups, wipeMedia: media)
    }

    func expectErased() {
        for directory in ["groups", "files"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(directory).path))
        }
        #expect(files.payloadReads.isEmpty)
        #expect(files.enumerations.isEmpty)
    }

    func expectNoNewAuthority() {
        #expect(markerWrites == 0)
        for name in Self.markers { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    }

    func expectNeighborsPreserved() throws {
        for name in Self.neighbors { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Self.sentinel) }
    }

    func expectMarkerBytesPreserved() throws {
        for name in Self.markers { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Self.markerBytes) }
    }

    func removeFixture() { try? FileManager.default.removeItem(at: root) }

    private func seed(_ bytes: Data, at name: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
}

/// Every platform-directory query resolves to an owned synthetic path, including the default-store test.
private final class GroupMediaFiles: FileManager, @unchecked Sendable {
    private let root: URL
    var failure: GroupMediaStartupPreflightTests.Failure?
    var refuseLookup = false
    private(set) var operations: [String] = []
    private(set) var lookupCreates: [Bool] = []
    private(set) var directoryCreations: [String] = []
    private(set) var payloadReads: [String] = []
    private(set) var enumerations: [String] = []

    init(root: URL, failure: GroupMediaStartupPreflightTests.Failure?) {
        self.root = root
        self.failure = failure
        super.init()
    }

    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        guard directory == .applicationSupportDirectory, domain == .userDomainMask, url == nil else {
            throw SyntheticGroupMediaError.forbidden
        }
        lookupCreates.append(shouldCreate)
        if refuseLookup { throw SyntheticGroupMediaError.unavailable }
        return root
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        guard directory == .applicationSupportDirectory, domainMask == .userDomainMask, !refuseLookup else { return [] }
        lookupCreates.append(false)
        return [root]
    }

    override func removeItem(at url: URL) throws {
        try requireOwnedTree(url)
        operations.append("remove:\(url.lastPathComponent)")
        if failure?.directory == url.lastPathComponent {
            if failure == .groupsRemoval || failure == .mediaRemoval { throw CocoaError(.fileWriteNoPermission) }
            if failure == .groupsSticky || failure == .mediaSticky { return }
        }
        try super.removeItem(at: url)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let url = URL(fileURLWithPath: path)
        try requireOwnedTree(url)
        operations.append("attributes:\(url.lastPathComponent)")
        if failure?.directory == url.lastPathComponent,
           failure == .groupsVerification || failure == .mediaVerification { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        directoryCreations.append(url.lastPathComponent)
        throw SyntheticGroupMediaError.forbidden
    }

    override func contents(atPath path: String) -> Data? {
        payloadReads.append("payload")
        return nil
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        enumerations.append("directory")
        throw SyntheticGroupMediaError.forbidden
    }

    private func requireOwnedTree(_ url: URL) throws {
        guard ["groups", "files"].contains(url.lastPathComponent),
              url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw SyntheticGroupMediaError.forbidden
        }
    }
}
