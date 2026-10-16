import Foundation
import Security
import Testing
@testable import bitchat

@Suite("Keychain write preservation")
struct KeychainWritePreservationTests {
    private let original = Data([0x11, 0x22])
    private let replacement = Data([0x33, 0x44])
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "synthetic-test-service",
         kSecAttrAccount as String: "synthetic-test-item"]
    }
    private var attributes: [String: Any] {
        [kSecValueData as String: replacement,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    @Test("Existing data is updated without removing or adding an item")
    func existingItemIsUpdated() {
        var stored = original
        var addCount = 0
        let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { _, values in
            stored = (values as! [String: Any])[kSecValueData as String] as! Data
            return errSecSuccess
        }, add: { _ in addCount += 1; return errSecDuplicateItem })
        #expect(result == errSecSuccess)
        #expect(stored == replacement)
        #expect(addCount == 0)
    }

    @Test("Denied updates preserve the previous data and do not attempt addition")
    func rejectedUpdatePreservesExistingValue() {
        for failure in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, OSStatus(-34018), errSecParam] {
            let stored = original
            var addCount = 0
            let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { _, _ in
                failure
            }, add: { _ in addCount += 1; return errSecSuccess })
            #expect(result == failure)
            #expect(stored == original)
            #expect(addCount == 0)
        }
    }

    @Test("Only definite absence adds an item with primary key and new attributes")
    func absenceAddsWithSeparateSearchAndValueAttributes() {
        var stored: Data?
        let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { search, values in
            let search = search as! [String: Any]
            let values = values as! [String: Any]
            #expect(search[kSecValueData as String] == nil)
            #expect(search[kSecReturnData as String] == nil)
            #expect(values[kSecAttrAccount as String] == nil)
            #expect(values[kSecValueData as String] as? Data == replacement)
            return errSecItemNotFound
        }, add: { item in
            let item = item as! [String: Any]
            #expect(item[kSecAttrService as String] as? String == "synthetic-test-service")
            #expect(item[kSecAttrAccount as String] as? String == "synthetic-test-item")
            stored = item[kSecValueData as String] as? Data
            return errSecSuccess
        })
        #expect(result == errSecSuccess)
        #expect(stored == replacement)
    }

    @Test("An unsuccessful first-use addition reports its actual error")
    func failedAddIsNotSuccess() {
        for failure in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecParam] {
            var updates = 0
            let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { _, _ in
                updates += 1
                return errSecItemNotFound
            }, add: { _ in failure })
            #expect(result == failure)
            #expect(updates == 1)
        }
    }

    @Test("A concurrent creator is handled by a bounded update without deletion")
    func concurrentCreationUpdatesExistingItem() {
        var stored: Data?
        var updates = 0
        var additions = 0
        let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { _, _ in
            updates += 1
            guard stored != nil else { return errSecItemNotFound }
            stored = replacement
            return errSecSuccess
        }, add: { _ in
            additions += 1
            stored = original // Another writer created the item before this add.
            return errSecDuplicateItem
        })
        #expect(result == errSecSuccess)
        #expect(stored == replacement)
        #expect(updates == 2)
        #expect(additions == 1)
    }

    @Test("A denied racing update preserves the concurrent value without retry loops")
    func rejectedRacingUpdatePreservesExistingItem() {
        var stored: Data?
        var updates = 0
        var additions = 0
        let result = KeychainManager.updateOrAddItem(query: query, attributes: attributes, update: { _, _ in
            updates += 1
            return updates == 1 ? errSecItemNotFound : errSecInteractionNotAllowed
        }, add: { _ in
            additions += 1
            stored = original
            return errSecDuplicateItem
        })
        #expect(result == errSecInteractionNotAllowed)
        #expect(stored == original)
        #expect(updates == 2)
        #expect(additions == 1)
    }
}
