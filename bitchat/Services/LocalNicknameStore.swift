// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import BitFoundation
import Foundation

/// The local nickname lives in the Keychain (this device only), not in
/// UserDefaults, whose plist is copied into iCloud and computer backups.
struct LocalNicknameStore {
    static let keychainKey = "weshLocalNickname.v1"
    static let legacyDefaultsKey = "bitchat.nickname"

    enum Loaded: Equatable {
        case stored(String)
        case absent
        /// The Keychain cannot be read yet (device locked): never treat this
        /// as a first launch that may overwrite the stored nickname.
        case unavailable
    }

    let keychain: KeychainManagerProtocol
    let defaults: UserDefaults

    /// Moves a legacy UserDefaults value into the Keychain. The legacy key is
    /// deleted only after the Keychain write is confirmed by a read.
    func load() -> Loaded {
        let legacy = defaults.string(forKey: Self.legacyDefaultsKey)
        switch keychain.getIdentityKeyWithResult(forKey: Self.keychainKey) {
        case .success(let data):
            if legacy != nil { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
            return .stored(String(bytes: data, encoding: .utf8) ?? "")
        case .itemNotFound:
            guard let legacy else { return .absent }
            save(legacy)
            return .stored(legacy)
        default:
            return legacy.map(Loaded.stored) ?? .unavailable
        }
    }

    /// True once the Keychain holds `nickname` and no legacy copy remains.
    @discardableResult
    func save(_ nickname: String) -> Bool {
        let data = Data(nickname.utf8)
        guard case .success = keychain.saveIdentityKeyWithResult(data, forKey: Self.keychainKey),
              case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: Self.keychainKey),
              stored == data else { return false }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        return defaults.object(forKey: Self.legacyDefaultsKey) == nil
    }

    /// Panic: true once the previous nickname is confirmed gone from both
    /// places. Storing the replacement is best effort; absence also counts.
    func replaceForPanic(with nickname: String) -> Bool {
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        guard defaults.object(forKey: Self.legacyDefaultsKey) == nil else { return false }
        let data = Data(nickname.utf8)
        if case .success = keychain.saveIdentityKeyWithResult(data, forKey: Self.keychainKey) {} else {
            _ = keychain.deleteIdentityKey(forKey: Self.keychainKey)
        }
        switch keychain.getIdentityKeyWithResult(forKey: Self.keychainKey) {
        case .success(let stored): return stored == data
        case .itemNotFound: return true
        default: return false
        }
    }
}
