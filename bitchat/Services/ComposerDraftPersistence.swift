// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import BitFoundation
import CryptoKit
import Foundation

/// Local storage failures contain no text, peer key, file path or OS diagnostic.
enum ComposerDraftFailure: Error, Equatable {
    case storageUnavailable, recoveryRequired, ownerMismatch, tooLarge, capacityReached, writeUnconfirmed
}

struct ComposerDraftRecord: Equatable {
    let key: ComposerDraftStore.Key
    let text: String
    let updatedAt: Date
}

/// This backend is used only on its repository's serial utility queue.
/// It never treats an unreadable file/key as a first-use empty cache.
final class ComposerDraftPersistence {
    static let keychainKey = "composerDraftEncryptionKey.v1"
    static let maxTextBytes = 32_000
    static let maxFileBytes = 2_100_000
    private static let magic = Array("WESHDRFT".utf8)
    private static let authenticatedContext = Data("wesh.composer-drafts.v1".utf8)

    struct FileAccess {
        let read: (URL) throws -> Data
        let write: (Data, URL) throws -> Void
        let remove: (URL) throws -> Void

        static var live: FileAccess {
            FileAccess(read: { url in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                // Bound allocation before decrypting or parsing any data.
                var result = Data()
                while result.count < maxFileBytes + 1 {
                    let remaining = maxFileBytes + 1 - result.count
                    guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                    result.append(chunk)
                }
                return result
            }, write: { data, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: BLEIncomingFileStore.mediaProtectionAttributes
                )
                var options: Data.WritingOptions = [.atomic]
                #if os(iOS)
                options.insert(.completeFileProtectionUntilFirstUserAuthentication)
                #endif
                try data.write(to: url, options: options)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableURL = url
                try mutableURL.setResourceValues(values)
            }, remove: { try FileManager.default.removeItem(at: $0) })
        }
    }

    let fileURL: URL
    private let keychain: KeychainManagerProtocol
    private let files: FileAccess
    private var loaded = false
    private var loadedOwner: Data?
    private var keyData: Data?
    private var baseline: Data?
    private var unconfirmedCandidate: Data?

    init(keychain: KeychainManagerProtocol, fileURL: URL, files: FileAccess = .live) {
        self.keychain = keychain
        self.fileURL = fileURL
        self.files = files
    }

    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("composer-drafts", isDirectory: true)
            .appendingPathComponent("wesh-v1.enc")
    }

    func load(owner: Data) throws -> [ComposerDraftRecord] {
        loaded = false
        guard owner.count == 32 else { throw ComposerDraftFailure.ownerMismatch }
        let blob = try readBlob()
        let key = try readKey()
        let records: [ComposerDraftRecord]
        if let blob {
            guard let key else { throw ComposerDraftFailure.recoveryRequired }
            do {
                let box = try ChaChaPoly.SealedBox(combined: blob)
                let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: key),
                                                  authenticating: Self.authenticatedContext)
                records = try Self.decode(plaintext, owner: owner)
            } catch let failure as ComposerDraftFailure { throw failure }
            catch { throw ComposerDraftFailure.recoveryRequired }
        } else {
            records = []
        }
        keyData = key
        baseline = blob
        unconfirmedCandidate = nil
        loadedOwner = owner
        loaded = true
        return records
    }

    func persist(_ records: [ComposerDraftRecord], owner: Data) throws {
        guard loaded, loadedOwner == owner else { throw ComposerDraftFailure.recoveryRequired }
        let plaintext = try Self.encode(records, owner: owner)
        let currentBlob = try readBlob()
        // Preserve a file changed by another writer. An explicit repository
        // reload can safely merge it with pending edits before retrying.
        guard currentBlob == baseline || (unconfirmedCandidate != nil && currentBlob == unconfirmedCandidate) else {
            throw ComposerDraftFailure.recoveryRequired
        }
        let currentKey = try readKey()
        if let keyData {
            guard currentKey == keyData else { throw ComposerDraftFailure.recoveryRequired }
        } else if let currentKey {
            // A previously unconfirmed key write may already be durable. It is
            // safe to reuse only while the cache is still explicitly absent.
            guard currentBlob == nil else { throw ComposerDraftFailure.recoveryRequired }
            keyData = currentKey
        } else {
            guard currentBlob == nil else { throw ComposerDraftFailure.recoveryRequired }
            let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            guard case .success = keychain.saveIdentityKeyWithResult(fresh, forKey: Self.keychainKey),
                  case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: Self.keychainKey),
                  stored == fresh else { throw ComposerDraftFailure.writeUnconfirmed }
            keyData = fresh
        }
        guard let keyData else { throw ComposerDraftFailure.writeUnconfirmed }
        let sealed: Data
        do {
            sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: keyData),
                                        authenticating: Self.authenticatedContext).combined
        } catch { throw ComposerDraftFailure.writeUnconfirmed }
        guard sealed.count <= Self.maxFileBytes else { throw ComposerDraftFailure.tooLarge }
        unconfirmedCandidate = sealed
        do {
            try files.write(sealed, fileURL)
            guard try readBlob() == sealed else { throw ComposerDraftFailure.writeUnconfirmed }
        } catch { throw ComposerDraftFailure.writeUnconfirmed }
        baseline = sealed
        unconfirmedCandidate = nil
    }

    /// Called only after the repository fenced and drained prior IO. Absence
    /// is confirmed by the same error-classifying read, never fileExists().
    func wipeFile() throws {
        invalidate()
        do { try files.remove(fileURL) }
        catch { if !Self.isMissing(error) { throw ComposerDraftFailure.storageUnavailable } }
        guard try readBlob() == nil else { throw ComposerDraftFailure.writeUnconfirmed }
    }

    func invalidate() {
        loaded = false
        loadedOwner = nil
        keyData = nil
        baseline = nil
        unconfirmedCandidate = nil
    }

    private func readBlob() throws -> Data? {
        do {
            let data = try files.read(fileURL)
            guard data.count <= Self.maxFileBytes else { throw ComposerDraftFailure.tooLarge }
            return data
        } catch let failure as ComposerDraftFailure { throw failure }
        catch {
            if Self.isMissing(error) { return nil }
            throw ComposerDraftFailure.storageUnavailable
        }
    }

    private func readKey() throws -> Data? {
        switch keychain.getIdentityKeyWithResult(forKey: Self.keychainKey) {
        case .success(let data):
            guard data.count == 32 else { throw ComposerDraftFailure.recoveryRequired }
            return data
        case .itemNotFound: return nil
        default: throw ComposerDraftFailure.storageUnavailable
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }

    // Strict local binary schema: magic8/version1/owner32/count2, then
    // kind1/[privateNoiseKey32]/timestampMilliseconds8/UTF8Length4/UTF8Bytes.
    // No location strings, fallback peer IDs, duplicate keys or trailing data.
    static func encode(_ records: [ComposerDraftRecord], owner: Data) throws -> Data {
        guard owner.count == 32, records.count <= UInt64(ComposerDraftStore.maxDraftCount) else {
            throw ComposerDraftFailure.tooLarge
        }
        var bytes = magic + [1] + Array(owner)
        append(UInt64(records.count), count: 2, to: &bytes)
        var seen = Set<ComposerDraftStore.Key>()
        for record in records.sorted(by: { $0.key.storageString < $1.key.storageString }) {
            guard seen.insert(record.key).inserted,
                  !record.text.isEmpty, record.text.count <= ComposerDraftStore.maxDraftLength,
                  record.text.utf8.count <= maxTextBytes else { throw ComposerDraftFailure.tooLarge }
            switch record.key {
            case .mesh: bytes.append(0)
            case .privateNoiseKey(let key):
                guard key.count == 32 else { throw ComposerDraftFailure.recoveryRequired }
                bytes.append(1); bytes.append(contentsOf: key)
            default: throw ComposerDraftFailure.recoveryRequired
            }
            let time = record.updatedAt.timeIntervalSince1970
            guard time.isFinite, time >= 0, time <= 253_402_300_799 else {
                throw ComposerDraftFailure.recoveryRequired
            }
            append(UInt64(time * 1000), count: 8, to: &bytes)
            let text = Array(record.text.utf8)
            append(UInt64(text.count), count: 4, to: &bytes)
            bytes.append(contentsOf: text)
        }
        guard bytes.count + 28 <= maxFileBytes else { throw ComposerDraftFailure.tooLarge }
        return Data(bytes)
    }

    static func decode(_ data: Data, owner: Data) throws -> [ComposerDraftRecord] {
        guard data.count <= maxFileBytes, data.count >= 43, owner.count == 32 else {
            throw ComposerDraftFailure.recoveryRequired
        }
        let bytes = Array(data)
        var cursor = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, cursor <= bytes.count, count <= bytes.count - cursor else {
                throw ComposerDraftFailure.recoveryRequired
            }
            defer { cursor += count }
            return bytes[cursor..<(cursor + count)]
        }
        func number(_ count: Int) throws -> UInt64 {
            try take(count).reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard Array(try take(8)) == magic, try number(1) == 1 else {
            throw ComposerDraftFailure.recoveryRequired
        }
        guard Data(try take(32)) == owner else { throw ComposerDraftFailure.ownerMismatch }
        let count = try number(2)
        guard count <= UInt64(ComposerDraftStore.maxDraftCount) else { throw ComposerDraftFailure.tooLarge }
        var records: [ComposerDraftRecord] = []
        var seen = Set<ComposerDraftStore.Key>()
        for _ in 0..<count {
            let key: ComposerDraftStore.Key
            switch try number(1) {
            case 0: key = .mesh
            case 1: key = .privateNoiseKey(Data(try take(32)))
            default: throw ComposerDraftFailure.recoveryRequired
            }
            guard seen.insert(key).inserted else { throw ComposerDraftFailure.recoveryRequired }
            let time = try number(8)
            guard time <= 253_402_300_799_000 else { throw ComposerDraftFailure.recoveryRequired }
            let length = try number(4)
            guard length > 0, length <= UInt64(maxTextBytes) else { throw ComposerDraftFailure.tooLarge }
            guard let text = String(bytes: try take(Int(length)), encoding: .utf8),
                  text.count <= ComposerDraftStore.maxDraftLength else { throw ComposerDraftFailure.recoveryRequired }
            records.append(ComposerDraftRecord(key: key, text: text,
                           updatedAt: Date(timeIntervalSince1970: Double(time) / 1000)))
        }
        guard cursor == bytes.count else { throw ComposerDraftFailure.recoveryRequired }
        return records
    }

    private static func append(_ value: UInt64, count: Int, to bytes: inout [UInt8]) {
        for shift in (0..<count).reversed() { bytes.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
}
