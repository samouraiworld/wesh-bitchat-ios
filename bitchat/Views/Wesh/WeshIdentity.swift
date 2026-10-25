import BitFoundation
import Combine
import Foundation

@MainActor
enum WeshMode {
    static var isActive = false {
        didSet { WeshModeFlag.isActive = isActive }
    }
}

/// The first-launch welcome (nickname, terms, then Bluetooth). Until it ends, the system Bluetooth
/// prompt is held back, so it appears on the step that explains it.
enum WeshWelcome {
    static let key = "wesh.welcomed.v1"

    static func isDone(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// Whether Bluetooth may start: never in Wesh before the welcome (first launch, or after a
    /// wipe, including one resumed at launch), always outside Wesh.
    static func meshMayStart(weshActive: Bool, in defaults: UserDefaults = .standard) -> Bool {
        !weshActive || isDone(in: defaults)
    }

    @MainActor
    static func meshMayStart() -> Bool {
        meshMayStart(weshActive: WeshMode.isActive)
    }

    /// The welcome keeps a nickname someone chose in an earlier build; the « anon1234 » stand-in
    /// set before any choice gives way to a suggested one.
    static func keptNickname(_ current: String) -> String? {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"^anon\d{4}$"#, options: .regularExpression) == nil else { return nil }
        return trimmed
    }
}

extension PaveSettingsSummary {
    /// The Settings rows as Wesh stores them: notification previews (hidden by default) and the
    /// appearance from `defaults`, the meeting note's place or else its title.
    static func wesh(nickname: String, meetingNote: WeshMeetingNoteStore.Content, blockedCount: Int,
                     defaults: UserDefaults = .standard) -> PaveSettingsSummary {
        let appearance = defaults.string(forKey: "wesh.appearance.v1").flatMap(WeshAppearance.init(rawValue:)) ?? .night
        return PaveSettingsSummary(nickname: nickname,
                                   previewsHidden: NotificationPrivacySettings.hideMessagePreviews(in: defaults),
                                   meetingNote: meetingNote.place.isEmpty ? meetingNote.title : meetingNote.place,
                                   blockedCount: blockedCount,
                                   theme: appearance.paveTheme)
    }
}

/// What the root shows: an unfinished erase first, then the first-launch welcome, then the app.
enum WeshRootScreen: Equatable {
    case eraseRecovery, welcome, tabs

    init(
        panicRecoveryBlocked: Bool,
        panicNetworkFenced: Bool = false,
        welcomed: Bool
    ) {
        if panicRecoveryBlocked || panicNetworkFenced {
            self = .eraseRecovery
        } else {
            self = welcomed ? .tabs : .welcome
        }
    }
}

/// `WeshMode.isActive` for code off the main actor (BLE and Nostr queues).
enum WeshModeFlag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = false
    static var isActive: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Common Wesh text admission bound; draft storage may retain longer text.
enum WeshTextLimits {
    static let maximumUTF8Bytes = 2000
}

/// A peer-chosen name made safe to show: no control or format characters
/// (bidi overrides included), at most 50 characters, NFC; else the fallback.
enum WeshDisplayName {
    static func clean(_ raw: String, fallback: String = "Contact") -> String {
        InputValidator.validateNickname(raw) ?? fallback
    }

    /// The name a block or report confirmation, its VoiceOver label, the resulting timeline line
    /// and the stored block name show. `privateTitle` is already through the rule; a public
    /// sender goes through it here, once.
    static func blockTarget(sender: String, privateTitle: String, isPrivate: Bool) -> String {
        isPrivate ? privateTitle : PaveDisplayName.safe(sender)
    }

    /// A petname is chosen on this phone; a claimed nickname is the peer's and goes through the rule.
    static func blockedContact(petname: String?, claimedNickname: String?) -> String {
        if let petname, !petname.isEmpty { return clean(petname, fallback: PaveDisplayName.safe(claimedNickname)) }
        return PaveDisplayName.safe(claimedNickname)
    }
}

/// Notes chosen on this phone, never a transport nickname or a trust decision.
/// The local alias matches Android's 15-code-point product bound; QR names keep
/// their separate protocol rules. Scalar prefixes never split UTF-16 surrogates.
enum WeshContactNotes {
    static let maximumAliasScalars = 15
    static let maximumMemoScalars = 500

    static func prefix(_ value: String, limit: Int) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit)))
    }

    /// Preserve a trailing space/newline while typing, but do not let discarded
    /// controls or leading padding consume the field's useful scalar budget.
    static func editingText(_ value: String, limit: Int, multiline: Bool) -> String {
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter { admitted($0, multiline: multiline) }))
            .precomposedStringWithCanonicalMapping
        let leadingTrimmed = filtered.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(leadingTrimmed.prefix(limit)))
    }

    static func cleanAlias(_ value: String) -> String? {
        let cleaned = clean(value, limit: maximumAliasScalars, multiline: false)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func cleanMemo(_ value: String) -> String? {
        let cleaned = clean(value, limit: maximumMemoScalars, multiline: true)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The UI applies the same reserved-word/name rule to aliases as to QR
    /// names. Refuse a nonempty alias that would only render as "unnamed".
    static func canDisplay(alias: String?) -> Bool {
        guard let alias else { return true }
        return !PaveDisplayName.remote(alias, unnamed: "", reserved: "",
                                       skeletons: PaveReservedWords.skeletons).isEmpty
    }

    private static func clean(_ value: String, limit: Int, multiline: Bool) -> String {
        // As on Android, clean and normalize before applying the local bound.
        // A run of stripped controls must not erase useful text that follows it.
        let scalars = value.unicodeScalars.filter { admitted($0, multiline: multiline) }
        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return prefix(normalized, limit: limit)
    }

    private static func admitted(_ scalar: Unicode.Scalar, multiline: Bool) -> Bool {
        if multiline && scalar == "\n" { return true }
        // Keep emoji joiners; directional controls and other formatting
        // characters must not steer the contact identity around the note.
        return scalar.properties.generalCategory != .control
            && (scalar.properties.generalCategory != .format || scalar.value == 0x200D)
    }
}

/// QR enrollment is separate from upstream manual verification and transitive vouches.
/// Contacts are sealed on this device only. An unreadable record is preserved
/// and reported, never replaced by an empty list.
@MainActor
final class WeshQRTrust: ObservableObject {
    static let shared = TestEnvironment.isRunningTests
        ? WeshQRTrust()
        : WeshQRTrust(storage: .liveQRContacts(), legacyDefaults: .standard, requirePersistence: true)
    struct Contact: Codable, Identifiable, Hashable {
        let noiseKeyHex: String
        let nickname: String
        /// Signed by the contact's QR and validated at enrollment; nil = Bluetooth-only.
        var npub: String? = nil
        /// The QR also proved possession of the npub's key (`npubsig`).
        var npubProven: Bool? = nil
        /// Another contact holds or claimed the same npub: for user review.
        var npubConflict: Bool? = nil
        /// A previously proven peer showed a QR without a valid proof; the
        /// proven binding was kept.
        var npubProofWarning: Bool? = nil
        /// Local-only annotations, sealed with this exact Noise identity.
        var alias: String? = nil
        var memo: String? = nil
        var id: String { noiseKeyHex }
        var peerID: PeerID { PeerID(hexData: Data(hexString: noiseKeyHex) ?? Data()) }
        var displayName: String { alias ?? nickname }
    }
    enum StorageState: Equatable { case available, unavailable, recoveryRequired }
    private struct Snapshot: Codable, Equatable {
        var contacts: [Contact] = []
        var fingerprints: [String] = []
    }
    static let legacyContactsKey = "wesh.qrContacts.v1"
    static let legacyFingerprintsKey = "wesh.qrVerifiedFingerprints.v1"

    /// A revocation or wipe the store has not confirmed yet. Mirrored in the
    /// Keychain so a reload, even after relaunch, retries it instead of
    /// restoring what the user removed.
    private struct Intent: Codable, Equatable {
        var wipe = false
        var revokedFingerprints: Set<String> = []
        var isEmpty: Bool { !wipe && revokedFingerprints.isEmpty }
    }

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var fingerprints: Set<String> = []
    @Published private(set) var storageState: StorageState = .available
    /// A removal/wipe fences every editor binding and save callback created
    /// before it, even if the same identity is enrolled again afterwards.
    @Published private(set) var noteGeneration: UInt64 = 0
    private let storage: WeshSealedStore?
    private let legacyDefaults: UserDefaults?
    private let requirePersistence: Bool
    private var intent = Intent()

    /// Nil storage is a RAM-only instance (tests, previews).
    init(storage: WeshSealedStore? = nil, legacyDefaults: UserDefaults? = nil, requirePersistence: Bool = false) {
        self.storage = storage
        self.legacyDefaults = legacyDefaults
        self.requirePersistence = requirePersistence
        load()
    }

    /// Retries a load deferred by a locked device, a Keychain failure or an
    /// unconfirmed wipe.
    func reloadIfNeeded() {
        if storageState != .available { load() }
    }

    @discardableResult
    func record(sessionKey: Data, nickname: String = "Contact", npub: String? = nil,
                npubProven: Bool = false, npubConflict: Bool = false, npubProofWarning: Bool = false) -> Bool {
        guard sessionKey.count == 32 else { return false }
        reloadIfNeeded()
        let npub = npub?.isEmpty == false ? npub : nil
        let hex = sessionKey.hexEncodedString()
        var next = snapshot
        let existing = next.contacts.first { Data(hexString: $0.noiseKeyHex) == sessionKey }
        next.contacts.removeAll { Data(hexString: $0.noiseKeyHex) == sessionKey }
        next.contacts.append(Contact(noiseKeyHex: hex, nickname: WeshDisplayName.clean(nickname), npub: npub,
                                     npubProven: npub != nil && npubProven ? true : nil,
                                     npubConflict: npubConflict ? true : nil,
                                     npubProofWarning: npubProofWarning ? true : nil,
                                     alias: existing?.alias, memo: existing?.memo))
        let fingerprint = sessionKey.sha256Fingerprint()
        if !next.fingerprints.contains(fingerprint) { next.fingerprints.append(fingerprint) }
        return commit(next)
    }

    /// Updates only an enrolled canonical identity. Failed reads and writes
    /// never publish new notes, and an old editor cannot undo removal or wipe.
    @discardableResult
    func setNote(sessionKey: Data, alias: String, memo: String, generation: UInt64) -> Bool {
        guard sessionKey.count == 32, generation == noteGeneration, !intent.wipe else { return false }
        reloadIfNeeded()
        guard generation == noteGeneration, storageState == .available, !intent.wipe else { return false }
        var next = snapshot
        guard let index = next.contacts.firstIndex(where: { Data(hexString: $0.noiseKeyHex) == sessionKey }) else { return false }
        let localAlias = WeshContactNotes.cleanAlias(alias)
        guard WeshContactNotes.canDisplay(alias: localAlias) else { return false }
        next.contacts[index].alias = localAlias
        next.contacts[index].memo = WeshContactNotes.cleanMemo(memo)
        return commit(next)
    }

    /// A verified proof took these contacts' npub: unbind them and flag them
    /// for review (WeshQRNpub precedence). False when the sealed write failed.
    @discardableResult
    func flagNpubConflict(noiseKeysHex: Set<String>) -> Bool {
        guard !noiseKeysHex.isEmpty else { return true }
        reloadIfNeeded()
        var next = snapshot
        for index in next.contacts.indices where noiseKeysHex.contains(next.contacts[index].noiseKeyHex.lowercased()) {
            next.contacts[index].npub = nil
            next.contacts[index].npubProven = nil
            next.contacts[index].npubConflict = true
        }
        return commit(next)
    }

    /// Revokes only this identity's enrollment; history and drafts belong to
    /// their own stores and must not be cleared by a contact-list action.
    /// Fail closed: the key leaves the sending allowlist at once, even when
    /// the write is not confirmed (false); the revocation is then retried.
    @discardableResult
    func remove(sessionKey: Data) -> Bool {
        guard sessionKey.count == 32 else { return false }
        noteGeneration &+= 1
        let fingerprint = sessionKey.sha256Fingerprint()
        let known = contacts.contains(where: { Data(hexString: $0.noiseKeyHex) == sessionKey }) || fingerprints.contains(fingerprint)
            || intent.revokedFingerprints.contains(fingerprint)
        // While the list cannot be read, membership is unknown: record the
        // revocation anyway so a later load can never restore this key.
        guard known || (storage != nil && storageState != .available) else { return false }
        intent.revokedFingerprints.insert(fingerprint)
        apply(Self.removing(intent.revokedFingerprints, from: snapshot))
        guard let storage else {
            intent.revokedFingerprints.remove(fingerprint)
            return true
        }
        let intentPersisted = persistIntent()
        reloadIfNeeded()
        guard storageState == .available, save(snapshot, to: storage) else { return false }
        // The confirmed file now omits the key; the marker is no longer needed.
        intent.revokedFingerprints = []
        _ = persistIntent()
        return known || intentPersisted
    }

    /// Clears RAM first, then confirms the sealed file, its key, any legacy
    /// plaintext copy and the pending-wipe marker are gone. On failure the
    /// marker keeps every later load from applying the old list.
    @discardableResult
    func clear() -> Bool {
        noteGeneration &+= 1
        apply(Snapshot())
        guard storage != nil else {
            guard !requirePersistence else {
                intent.wipe = true
                storageState = .unavailable
                return false
            }
            intent = Intent()
            let erased = removeLegacy()
            storageState = erased ? .available : .unavailable
            return erased
        }
        intent = Intent(wipe: true)
        return retryWipe()
    }

    /// Marks the wipe pending (Keychain intent, else a sentinel file), then
    /// always destroys. True only when destruction is verified and a marker
    /// was in place throughout; anything else stays unavailable and retries.
    private func retryWipe() -> Bool {
        guard let storage else { return false }
        let keychainMarked = persistIntent()
        let sentinelMarked = storage.markWipePending()
        let erased = finishWipe()
        guard erased, keychainMarked || sentinelMarked else {
            if erased { intent.wipe = true }
            storageState = .unavailable
            return false
        }
        return true
    }

    private var snapshot: Snapshot {
        Snapshot(contacts: contacts, fingerprints: fingerprints.sorted())
    }

    private static func removing(_ revoked: Set<String>, from value: Snapshot) -> Snapshot {
        guard !revoked.isEmpty else { return value }
        var next = value
        next.contacts.removeAll { contact in
            Data(hexString: contact.noiseKeyHex).map { revoked.contains($0.sha256Fingerprint()) } ?? true
        }
        next.fingerprints.removeAll { revoked.contains($0) }
        return next
    }

    /// Changes RAM only after a confirmed write, so a failure never shows a
    /// contact that will not survive a restart.
    private func commit(_ next: Snapshot) -> Bool {
        guard storageState == .available, !intent.wipe else { return false }
        if let storage {
            guard save(next, to: storage) else { return false }
            // The confirmed file now omits every pending revocation, and a
            // fresh enrollment supersedes an older one for the same key.
            if !intent.revokedFingerprints.isEmpty {
                intent.revokedFingerprints = []
                _ = persistIntent()
            }
        }
        apply(next)
        return true
    }

    private func save(_ value: Snapshot, to storage: WeshSealedStore) -> Bool {
        do {
            try storage.save(JSONEncoder().encode(value))
            return true
        } catch WeshSealedStore.Failure.recoveryRequired {
            storageState = .recoveryRequired
            return false
        } catch { return false }
    }

    private func persistIntent() -> Bool {
        guard let storage else { return true }
        guard !intent.isEmpty else { return storage.writeIntent(nil) }
        guard let data = try? JSONEncoder().encode(intent) else { return false }
        return storage.writeIntent(data)
    }

    private func finishWipe() -> Bool {
        guard let storage else { return false }
        var erased = true
        do { try storage.wipe() } catch { erased = false }
        erased = removeLegacy() && erased
        if erased {
            // Leaving a marker would erase contacts enrolled after this wipe.
            let pending = intent
            intent = Intent()
            if !(persistIntent() && storage.clearWipeSentinel()) {
                intent = pending
                erased = false
            }
        }
        storageState = erased ? .available : .unavailable
        return erased
    }

    private func apply(_ value: Snapshot) {
        contacts = value.contacts.map { row in
            var cleaned = row
            cleaned.alias = WeshContactNotes.cleanAlias(row.alias ?? "")
            cleaned.memo = WeshContactNotes.cleanMemo(row.memo ?? "")
            return cleaned
        }
        fingerprints = Set(value.fingerprints)
    }

    private func load() {
        guard let storage else {
            storageState = requirePersistence ? .unavailable : .available
            return
        }
        do {
            if let data = try storage.readIntent() {
                guard let stored = try? JSONDecoder().decode(Intent.self, from: data) else {
                    throw WeshSealedStore.Failure.recoveryRequired
                }
                intent.wipe = intent.wipe || stored.wipe
                intent.revokedFingerprints.formUnion(stored.revokedFingerprints)
            }
            if try storage.isWipePending() { intent.wipe = true }
            if intent.wipe {
                // A list ordered deleted is never applied; retry the wipe.
                apply(Snapshot())
                _ = retryWipe()
                return
            }
            let value: Snapshot
            if let data = try storage.load() {
                guard let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                    throw WeshSealedStore.Failure.recoveryRequired
                }
                value = Self.removing(intent.revokedFingerprints, from: decoded)
                if value != decoded { try storage.save(JSONEncoder().encode(value)) }
                _ = removeLegacy()
            } else if let legacy = try legacySnapshot() {
                // One-time migration: delete plaintext only after a confirmed sealed write.
                value = Self.removing(intent.revokedFingerprints, from: legacy)
                try storage.save(JSONEncoder().encode(value))
                _ = removeLegacy()
            } else {
                value = Snapshot()
            }
            apply(value)
            if !intent.revokedFingerprints.isEmpty {
                intent.revokedFingerprints = []
                _ = persistIntent()
            }
            storageState = .available
        } catch WeshSealedStore.Failure.recoveryRequired {
            apply(Snapshot())
            storageState = .recoveryRequired
        } catch {
            // Locked device or unconfirmed write: retryable, nothing replaced.
            apply(Snapshot())
            storageState = .unavailable
        }
    }

    private func legacySnapshot() throws -> Snapshot? {
        guard let legacyDefaults else { return nil }
        let data = legacyDefaults.object(forKey: Self.legacyContactsKey)
        let prints = legacyDefaults.object(forKey: Self.legacyFingerprintsKey)
        guard data != nil || prints != nil else { return nil }
        var value = Snapshot()
        if let data {
            guard let data = data as? Data,
                  let decoded = try? JSONDecoder().decode([Contact].self, from: data) else {
                throw WeshSealedStore.Failure.recoveryRequired
            }
            value.contacts = decoded.map {
                Contact(noiseKeyHex: $0.noiseKeyHex, nickname: WeshDisplayName.clean($0.nickname), npub: $0.npub,
                        npubProven: $0.npubProven, npubConflict: $0.npubConflict, npubProofWarning: $0.npubProofWarning,
                        alias: WeshContactNotes.cleanAlias($0.alias ?? ""), memo: WeshContactNotes.cleanMemo($0.memo ?? ""))
            }
        }
        if let prints {
            guard let prints = prints as? [String] else { throw WeshSealedStore.Failure.recoveryRequired }
            value.fingerprints = prints
        }
        return value
    }

    private func removeLegacy() -> Bool {
        guard let legacyDefaults else { return true }
        legacyDefaults.removeObject(forKey: Self.legacyContactsKey)
        legacyDefaults.removeObject(forKey: Self.legacyFingerprintsKey)
        return legacyDefaults.object(forKey: Self.legacyContactsKey) == nil
            && legacyDefaults.object(forKey: Self.legacyFingerprintsKey) == nil
    }

    static func canSend(sessionKey: Data?, qrFingerprints: Set<String>, locallyVerified: Bool, requestedKey: Data? = nil) -> Bool {
        guard locallyVerified, let sessionKey, sessionKey.count == 32 else { return false }
        if let requestedKey, requestedKey != sessionKey { return false }
        return qrFingerprints.contains(sessionKey.sha256Fingerprint())
    }
}

extension ChatViewModel {
    @MainActor
    func canSendWeshPrivate(to peerID: PeerID) -> Bool {
        // Transport availability is shared; public disclosure is checked only
        // by the public send API, not by this private identity gate.
        guard canSendWeshPublic,
              let requestedKey = peerID.noiseKey, requestedKey.count == 32 else { return false }
        guard identityManager.isPersistenceAvailable,
              !identityManager.hasPendingPersistenceChanges else { return false }
        if identityManager.isBlocked(fingerprint: requestedKey.sha256Fingerprint()) { return false }
        let shortID = getShortIDForNoiseKey(peerID)
        guard !isPeerBlocked(shortID) else { return false }
        let sessionKey = noiseSessionPublicKeyData(for: shortID)
        guard let sessionKey, getFingerprint(for: shortID) == sessionKey.sha256Fingerprint() else { return false }
        return WeshQRTrust.canSend(sessionKey: sessionKey, qrFingerprints: WeshQRTrust.shared.fingerprints,
                                  locallyVerified: peerIdentityStore.isVerified(sessionKey.sha256Fingerprint()), requestedKey: requestedKey)
    }

    /// Spec §3 rule 2: an enrolled, unblocked QR contact whose QR bound a
    /// usable npub, while Internet mode is On. No Bluetooth session needed.
    @MainActor
    func canSendWeshInternet(to peerID: PeerID) -> Bool {
        isWeshInternetContact(peerID) && weshInternetIsOn()
    }

    /// Every trust check of the Internet route except Internet being on: what the contact
    /// badge shows, so it can never call reachable a contact the route would refuse.
    func isWeshInternetContact(_ peerID: PeerID) -> Bool {
        guard weshPrivatePolicyEnabled, !panicRecoveryBlocked,
              let key = peerID.noiseKey, key.count == 32,
              identityManager.isPersistenceAvailable,
              !identityManager.hasPendingPersistenceChanges else { return false }
        let fingerprint = key.sha256Fingerprint()
        // Same trust as the Bluetooth gate (WeshQRTrust.canSend): QR-enrolled and still verified here.
        guard !identityManager.isBlocked(fingerprint: fingerprint),
              !isPeerBlocked(getShortIDForNoiseKey(peerID)),
              peerIdentityStore.isVerified(fingerprint),
              WeshQRTrust.shared.fingerprints.contains(fingerprint),
              let contact = WeshQRTrust.shared.contacts.first(where: { Data(hexString: $0.noiseKeyHex) == key }),
              WeshInternetRoute.deliveryNpub(for: contact) != nil else { return false }
        return true
    }

    /// `[FAVORITED]:<my npub>` over the live Noise session with an enrolled
    /// contact, so an official BitChat peer learns where to reply over
    /// Internet. Only while Internet mode is enabled and my key exists (never
    /// created here); once per contact and npub in this process.
    @MainActor
    func announceWeshInternetKey(to peerID: PeerID) {
        guard weshPrivatePolicyEnabled, !panicRecoveryBlocked, weshInternetIsOn(),
              let sessionKey = noiseSessionPublicKeyData(for: getShortIDForNoiseKey(peerID)),
              canSendWeshPrivate(to: PeerID(hexData: sessionKey)),
              let npub = idBridge.messagingIdentity(weshActive: true, internetEnabled: true)?.npub else { return }
        let announced = sessionKey.hexEncodedString() + npub
        guard weshAnnouncedInternetKeys.insert(announced).inserted else { return }
        meshService.sendFavoriteNotification(to: getShortIDForNoiseKey(peerID), isFavorite: true)
    }

    /// A live Bluetooth session with the enrolled key, else Internet.
    @MainActor
    func canSendWeshMessage(to peerID: PeerID) -> Bool {
        canSendWeshPrivate(to: peerID) || canSendWeshInternet(to: peerID)
    }

    @MainActor @discardableResult
    func unblockWeshIdentity(_ fingerprint: String) -> Bool {
        unifiedPeerService.unblock(fingerprint: fingerprint)
    }

}

/// A historical routing alias cannot identify the author after reassignment.
enum WeshMessageActions {
    static func blockIdentity(messageSender: PeerID?, pinnedConversation: PeerID?) -> PeerID? {
        let candidate = pinnedConversation ?? messageSender
        guard let candidate, let key = candidate.noiseKey, key.count == 32 else { return nil }
        return candidate
    }
}

enum WeshBuildInfo {
    static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
