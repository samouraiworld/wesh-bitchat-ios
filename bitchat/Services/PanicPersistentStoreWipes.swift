import BitLogger
import BitFoundation
import Foundation

/// A nil URL is success only for an explicitly memory-only store. Checking
/// attributes preserves permission/protection failures that fileExists hides.
enum PanicFileRemoval {
    static func remove(_ url: URL?, required: Bool, fileManager: FileManager = .default) -> Bool {
        guard let url else { return !required }
        do { try fileManager.removeItem(at: url) }
        catch { if !isMissing(error) { return false } }
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return false
        } catch { return isMissing(error) }
    }

    static func removeLegacyGroups(at applicationSupportURL: URL, fileManager: FileManager = .default) -> Bool {
        remove(applicationSupportURL.appendingPathComponent("groups", isDirectory: true),
               required: true, fileManager: fileManager)
    }

    static func removeLegacyMedia(fileStore: PanicRecoveryFileStore) -> Bool {
        do {
            try fileStore.removeLegacyMedia()
            return true
        } catch { return false }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }
}

/// Test injection replaces every default-path operation; no live app-group or
/// Application Support path needs to be opened by a panic integration test.
@MainActor
struct PanicPersistentStoreWipes {
    var courier: @MainActor () -> Bool = { CourierStore.shared.wipe() }
    var bridge: @MainActor () -> Bool = { RetiredBridgeDropStore.shared.wipe() }
    var publicArchive: @MainActor () -> Bool = { GossipMessageArchive.wipeDefault() }
    var prekeys: @MainActor () -> Bool = { PrekeyBundleStore.shared.wipe() }
    var board: @MainActor () -> Bool = { RetiredBoardStore.shared.wipe() }
    var geography: @MainActor () -> Bool = {
        if TestEnvironment.isRunningTests { return true }
        return RetiredGeographyStore.shared.wipe()
    }
    var sightings: @MainActor () -> Bool = {
        if TestEnvironment.isRunningTests { return true }
        return RetiredSightingsStore(defaults: .standard).wipe()
    }
    /// Group rosters stored by builds that still accepted BitChat groups.
    var legacyGroups: @MainActor () -> Bool = {
        if TestEnvironment.isRunningTests { return true }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return false }
        return PanicFileRemoval.removeLegacyGroups(at: base)
    }
    /// Ordinary retirement deletes only the legacy tree, never a panic marker or drafts.
    var legacyMedia: @MainActor () -> Bool = {
        if TestEnvironment.isRunningTests { return true }
        return PanicFileRemoval.removeLegacyMedia(fileStore: PanicRecoveryFileStore())
    }
    /// Handoffs left by earlier share extensions; never parsed or imported.
    var sharedContent: @MainActor () -> Bool = {
        if TestEnvironment.isRunningTests { return true }
        guard let defaults = UserDefaults(suiteName: BitchatApp.groupID) else { return false }
        return SharedContentStore(defaults: defaults).discardAll()
    }
    /// Sealed QR contact list, its key and any legacy plaintext copy.
    var qrContacts: @MainActor () -> Bool = { WeshQRTrust.shared.clear() }
    /// Delivered and pending alerts can still name senders or quote messages.
    var notifications: @MainActor () -> Void = { NotificationService.shared.removeAllNotifications() }
    /// A message copied from Wesh must not outlive the local data.
    var pasteboard: @MainActor () -> Void = { WeshClipboard.shared.clearOwnedCopy() }
}

struct PanicRecoveryIntent {
    let fileMarkerEstablished: Bool
    let externalMarkerEstablished: Bool

    var hasDurableMarker: Bool {
        fileMarkerEstablished || externalMarkerEstablished
    }
}

/// Small, dependency-injectable transaction surface used by ChatViewModel.
/// Production persists the same intent in two independent locations before
/// any application state is erased. Tests can inject an ephemeral operation
/// set without touching the developer's Application Support directory.
struct PanicRecoveryOperations {
    let isPending: () throws -> Bool
    let begin: () -> PanicRecoveryIntent
    /// Deletes the media an older build may have stored, and the drafts.
    let wipeMedia: (PanicRecoveryIntent) throws -> Void
    let complete: () throws -> Void

    func completeIfConfirmed(existingStoreResults: [Bool], legacySightingsConfirmed: Bool) throws -> Bool {
        guard existingStoreResults.allSatisfy({ $0 }), legacySightingsConfirmed else { return false }
        try complete()
        return true
    }

    static func ephemeral(
        wipeMedia: @escaping () throws -> Void = {}
    ) -> PanicRecoveryOperations {
        PanicRecoveryOperations(
            isPending: { false },
            begin: {
                PanicRecoveryIntent(
                    fileMarkerEstablished: false,
                    externalMarkerEstablished: false
                )
            },
            wipeMedia: { _ in try wipeMedia() },
            complete: {}
        )
    }

    static func live(
        fileStore: PanicRecoveryFileStore = PanicRecoveryFileStore(),
        defaults: UserDefaults = .standard,
        wipeDrafts: @escaping () throws -> Void = ComposerDraftStore.wipePersistentDraftsForPanic
    ) -> PanicRecoveryOperations {
        let defaultsKey = "bitchat.panicResetPending"
        return PanicRecoveryOperations(
            isPending: {
                if defaults.bool(forKey: defaultsKey) {
                    return true
                }
                return try fileStore.isPanicRecoveryPending()
            },
            begin: {
                defaults.set(true, forKey: defaultsKey)
                let externalMarkerEstablished =
                    defaults.synchronize()
                    && defaults.bool(forKey: defaultsKey)

                let fileMarkerEstablished: Bool
                do {
                    try fileStore.markPanicRecoveryPending()
                    fileMarkerEstablished = true
                } catch {
                    fileMarkerEstablished = false
                    SecureLogger.error(
                        "Failed to persist file panic-recovery marker: \(error)",
                        category: .security
                    )
                }

                return PanicRecoveryIntent(
                    fileMarkerEstablished: fileMarkerEstablished,
                    externalMarkerEstablished: externalMarkerEstablished
                )
            },
            wipeMedia: { intent in
                // Both independent payload trees must be attempted. Either
                // failure retains the global startup recovery markers.
                var mediaFailure: Error?
                var draftFailure: Error?
                do { try fileStore.wipeLegacyMedia(hasDurablePendingMarker: intent.hasDurableMarker) }
                catch { mediaFailure = error }
                do { try wipeDrafts() }
                catch { draftFailure = error }
                if mediaFailure != nil || draftFailure != nil {
                    throw PanicLocalFileCleanupError.failed(media: mediaFailure, drafts: draftFailure)
                }
            },
            complete: {
                // Keep the independent defaults latch until the file marker
                // has definitely cleared. Any failure therefore remains
                // visible to the next launch.
                try fileStore.completePanicRecovery()
                defaults.removeObject(forKey: defaultsKey)
                guard defaults.synchronize(),
                      !defaults.bool(forKey: defaultsKey) else {
                    throw PanicRecoveryFileStore.PanicRecoveryError
                        .externalMarkerCommitFailed
                }
            }
        )
    }
}

private enum PanicLocalFileCleanupError: Error {
    case failed(media: Error?, drafts: Error?)
}

/// The panic file marker, and the media tree older builds wrote.
///
/// Wesh has no media, but a build from before its removal may have stored
/// received and sent images, voice notes, files and private-media receipts
/// under `Application Support/files`. Panic deletes that tree whole; nothing
/// recreates it.
struct PanicRecoveryFileStore {
    enum PanicRecoveryError: Error {
        case externalMarkerCommitFailed
        case markerWriteFailed(Error)
        case legacyMediaNotRemoved
        case markerWriteAndMediaWipeFailed(
            markerError: Error,
            mediaError: Error
        )
    }

    /// Kept outside `files/` so deleting the media tree cannot erase the
    /// fail-closed startup decision before the full panic has committed.
    private static let panicRecoveryPendingMarkerFileName =
        ".panic-recovery-pending"
    /// Compatibility with a short-lived development build that used the
    /// media-specific name for the same full-transaction latch.
    private static let legacyPanicRecoveryPendingMarkerFileName =
        ".panic-media-wipe-pending"
    private static let legacyMediaDirectoryName = "files"

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let panicMarkerWriter: (Data, URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        panicMarkerWriter: @escaping (Data, URL) throws -> Void = {
            try LocalFileProtection.write($0, to: $1, options: .atomic)
        }
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.panicMarkerWriter = panicMarkerWriter
    }

    /// Deletes the legacy media tree before returning, and fails closed:
    /// an error is thrown unless the tree is confirmed gone.
    ///
    /// Marker persistence and deletion are deliberately separate error
    /// domains: even when both durable marker channels fail, deletion is
    /// still attempted before this method reports the marker failure.
    func wipeLegacyMedia(hasDurablePendingMarker: Bool = false) throws {
        let markerError: Error?
        do {
            try markPanicRecoveryPending()
            markerError = nil
        } catch {
            markerError = error
            SecureLogger.error(
                "Could not persist file panic-recovery marker; attempting media deletion anyway: \(error)",
                category: .security
            )
        }

        do {
            try removeLegacyMedia()
        } catch {
            if let markerError {
                throw PanicRecoveryError.markerWriteAndMediaWipeFailed(
                    markerError: markerError,
                    mediaError: error
                )
            }
            throw error
        }

        if let markerError, !hasDurablePendingMarker {
            throw PanicRecoveryError.markerWriteFailed(markerError)
        }
    }

    /// Deletes the legacy media tree. Throws unless it is confirmed gone.
    func removeLegacyMedia() throws {
        let directory = try removalRootDirectory()
            .appendingPathComponent(Self.legacyMediaDirectoryName, isDirectory: true)
        guard PanicFileRemoval.remove(directory, required: true, fileManager: fileManager) else {
            throw PanicRecoveryError.legacyMediaNotRemoved
        }
    }

    func markPanicRecoveryPending() throws {
        let markerURL = try rootDirectory().appendingPathComponent(
            Self.panicRecoveryPendingMarkerFileName,
            isDirectory: false
        )
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try panicMarkerWriter(Data([1]), markerURL)
    }

    func isPanicRecoveryPending() throws -> Bool {
        try panicRecoveryMarkerURLs().contains {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    func completePanicRecovery() throws {
        for markerURL in try panicRecoveryMarkerURLs()
        where fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    /// Resolves the configured removal path without creating the root or a panic marker.
    private func removalRootDirectory() throws -> URL {
        if let baseDirectory { return baseDirectory }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PanicRecoveryError.legacyMediaNotRemoved
        }
        return directory
    }

    private func rootDirectory() throws -> URL {
        try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func panicRecoveryMarkerURLs() throws -> [URL] {
        let root = try rootDirectory()
        return [
            root.appendingPathComponent(
                Self.panicRecoveryPendingMarkerFileName,
                isDirectory: false
            ),
            root.appendingPathComponent(
                Self.legacyPanicRecoveryPendingMarkerFileName,
                isDirectory: false
            )
        ]
    }
}
