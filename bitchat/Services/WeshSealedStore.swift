// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import BitFoundation
import CryptoKit
import Foundation

/// One small private record sealed with ChaCha20-Poly1305. The key lives in
/// the Keychain (ThisDeviceOnly); the file is excluded from backups. A read
/// never treats an unreadable file or key as a first-use empty record.
final class WeshSealedStore {
    enum Failure: Error, Equatable {
        /// Temporarily unreadable (device locked, Keychain busy). Retry later.
        case storageUnavailable
        /// Present but undecryptable or inconsistent. Keep it, never overwrite.
        case recoveryRequired
        case writeUnconfirmed
    }

    static let maxPlaintextBytes = 512_000

    let fileURL: URL
    private let keychain: KeychainManagerProtocol
    private let keyName: String
    private let context: Data
    private let files: ComposerDraftPersistence.FileAccess

    init(keychain: KeychainManagerProtocol, fileURL: URL, keyName: String, context: String,
         files: ComposerDraftPersistence.FileAccess = .live) {
        self.keychain = keychain
        self.fileURL = fileURL
        self.keyName = keyName
        self.context = Data(context.utf8)
        self.files = files
    }

    /// Nil means confirmed absent.
    func load() throws -> Data? {
        guard let blob = try readBlob() else { return nil }
        guard let key = try readKey() else { throw Failure.recoveryRequired }
        do {
            let box = try ChaChaPoly.SealedBox(combined: blob)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: context)
        } catch { throw Failure.recoveryRequired }
    }

    func save(_ plaintext: Data) throws {
        guard plaintext.count <= Self.maxPlaintextBytes else { throw Failure.writeUnconfirmed }
        let blob = try readBlob()
        let key: Data
        if let existing = try readKey() {
            key = existing
        } else {
            // A file without its key is a lost state, not first use.
            guard blob == nil else { throw Failure.recoveryRequired }
            let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            guard case .success = keychain.saveIdentityKeyWithResult(fresh, forKey: keyName),
                  case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: keyName),
                  stored == fresh else { throw Failure.writeUnconfirmed }
            key = fresh
        }
        if let blob {
            // Never replace a record this key cannot open.
            do {
                _ = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob), using: SymmetricKey(data: key),
                                        authenticating: context)
            } catch { throw Failure.recoveryRequired }
        }
        let sealed: Data
        do {
            sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), authenticating: context).combined
        } catch { throw Failure.writeUnconfirmed }
        do {
            try files.write(sealed, fileURL)
            guard try readBlob() == sealed else { throw Failure.writeUnconfirmed }
        } catch { throw Failure.writeUnconfirmed }
    }

    /// Removes the file, then its key. Absence of both is confirmed by reads.
    func wipe() throws {
        do { try files.remove(fileURL) }
        catch { if !Self.isMissing(error) { throw Failure.storageUnavailable } }
        guard try readBlob() == nil else { throw Failure.writeUnconfirmed }
        guard keychain.deleteIdentityKey(forKey: keyName),
              case .itemNotFound = keychain.getIdentityKeyWithResult(forKey: keyName) else {
            throw Failure.writeUnconfirmed
        }
    }

    // MARK: Pending intent

    /// A wipe or revocation that could not be confirmed is recorded in the
    /// Keychain beside the file, never inside it, so a later load retries the
    /// change instead of resurrecting what the user removed. `wipe()` leaves
    /// this item alone.
    private var intentKeyName: String { keyName + ".intent" }

    func readIntent() throws -> Data? {
        switch keychain.getIdentityKeyWithResult(forKey: intentKeyName) {
        case .success(let data): return data
        case .itemNotFound: return nil
        default: throw Failure.storageUnavailable
        }
    }

    /// Nil removes the intent. True only after a confirming read.
    @discardableResult
    func writeIntent(_ data: Data?) -> Bool {
        guard let data else {
            guard keychain.deleteIdentityKey(forKey: intentKeyName),
                  case .itemNotFound = keychain.getIdentityKeyWithResult(forKey: intentKeyName) else { return false }
            return true
        }
        guard case .success = keychain.saveIdentityKeyWithResult(data, forKey: intentKeyName),
              case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: intentKeyName) else { return false }
        return stored == data
    }

    private func readBlob() throws -> Data? {
        do {
            let data = try files.read(fileURL)
            guard data.count <= ComposerDraftPersistence.maxFileBytes else { throw Failure.recoveryRequired }
            return data
        } catch let failure as Failure { throw failure }
        catch {
            if Self.isMissing(error) { return nil }
            throw Failure.storageUnavailable
        }
    }

    private func readKey() throws -> Data? {
        switch keychain.getIdentityKeyWithResult(forKey: keyName) {
        case .success(let data):
            guard data.count == 32 else { throw Failure.recoveryRequired }
            return data
        case .itemNotFound: return nil
        default: throw Failure.storageUnavailable
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }
}

extension WeshSealedStore {
    private static func live(file: String, keyName: String, context: String) -> WeshSealedStore? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = directory.appendingPathComponent("wesh-private", isDirectory: true).appendingPathComponent(file)
        return WeshSealedStore(keychain: KeychainManager.makeDefault(), fileURL: url, keyName: keyName, context: context)
    }

    static func liveQRContacts() -> WeshSealedStore? {
        live(file: "qr-contacts-v1.enc", keyName: "weshQRContactsKey.v1", context: "wesh.qr-contacts.v1")
    }

    static func liveMeetingNote() -> WeshSealedStore? {
        live(file: "meeting-note-v1.enc", keyName: "weshMeetingNoteKey.v1", context: "wesh.meeting-note.v1")
    }
}
