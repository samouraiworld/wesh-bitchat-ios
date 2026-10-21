//
// LocalNicknameStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Local nickname stays out of UserDefaults")
struct LocalNicknameStoreTests {
    private final class Fixture {
        let keychain = MockKeychain()
        let suite = "local-nickname-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        var store: LocalNicknameStore { LocalNicknameStore(keychain: keychain, defaults: defaults) }
        var legacy: String? { defaults.string(forKey: LocalNicknameStore.legacyDefaultsKey) }
        var stored: String? {
            keychain.getIdentityKey(forKey: LocalNicknameStore.keychainKey).flatMap { String(bytes: $0, encoding: .utf8) }
        }
        deinit { UserDefaults().removePersistentDomain(forName: suite) }
    }

    @Test func saveWritesTheKeychainOnlyAndConfirmsIt() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        #expect(fixture.stored == "Nora")
        #expect(fixture.legacy == nil)
        #expect(fixture.store.load() == .stored("Nora"))
    }

    @Test func legacyNicknameMovesToTheKeychainAndIsDeletedAfterAConfirmedWrite() {
        let fixture = Fixture()
        fixture.defaults.set("Nora", forKey: LocalNicknameStore.legacyDefaultsKey)
        #expect(fixture.store.load() == .stored("Nora"))
        #expect(fixture.stored == "Nora")
        #expect(fixture.legacy == nil)
    }

    @Test func legacyNicknameStaysWhenTheKeychainWriteIsNotConfirmed() {
        let fixture = Fixture()
        fixture.defaults.set("Nora", forKey: LocalNicknameStore.legacyDefaultsKey)
        fixture.keychain.identitySaveFault = { _, _, _ in .deviceLocked }
        #expect(fixture.store.load() == .stored("Nora"))
        #expect(fixture.legacy == "Nora")
        fixture.keychain.identitySaveFault = nil
        #expect(fixture.store.load() == .stored("Nora"))
        #expect(fixture.legacy == nil)
    }

    @Test func aLeftoverLegacyCopyIsDeletedOnceTheKeychainHoldsTheNickname() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        fixture.defaults.set("Old", forKey: LocalNicknameStore.legacyDefaultsKey)
        #expect(fixture.store.load() == .stored("Nora"))
        #expect(fixture.legacy == nil)
    }

    @Test func anUnreadableKeychainIsNeverReadAsAbsent() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        fixture.keychain.identityReadFault = { _, _ in .deviceLocked }
        #expect(fixture.store.load() == .unavailable)
        fixture.keychain.identityReadFault = nil
        #expect(fixture.stored == "Nora")
    }

    @Test func panicReplacementRemovesThePreviousNicknameFromBothPlaces() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        fixture.defaults.set("Nora", forKey: LocalNicknameStore.legacyDefaultsKey)
        #expect(fixture.store.replaceForPanic(with: "anon1234"))
        #expect(fixture.stored == "anon1234")
        #expect(fixture.legacy == nil)
    }

    @Test func panicReplacementSucceedsWhenTheNewNicknameCannotBeStoredButTheOldOneIsGone() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        fixture.keychain.identitySaveFault = { _, _, _ in .deviceLocked }
        #expect(fixture.store.replaceForPanic(with: "anon1234"))
        #expect(fixture.stored == nil)
    }

    @Test func panicReplacementFailsWhileThePreviousNicknameMayRemain() {
        let fixture = Fixture()
        #expect(fixture.store.save("Nora"))
        fixture.keychain.identitySaveFault = { _, _, _ in .deviceLocked }
        fixture.keychain.identityDeleteFault = { _, _ in false }
        #expect(!fixture.store.replaceForPanic(with: "anon1234"))
        fixture.keychain.identityDeleteFault = nil
        fixture.keychain.identitySaveFault = nil
        fixture.keychain.identityReadFault = { _, _ in .deviceLocked }
        #expect(!fixture.store.replaceForPanic(with: "anon5678"))
    }
}

@Suite("Panic wipes the local nickname", .serialized)
@MainActor
struct LocalNicknamePanicTests {
    private func viewModel(keychain: MockKeychain) -> (ChatViewModel, () -> Int) {
        var committed = 0
        let operations = PanicRecoveryOperations(isPending: { false }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: { committed += 1 })
        let wipes = PanicPersistentStoreWipes(
            courier: { true }, bridge: { true }, publicArchive: { true },
            prekeys: { true }, board: { true }, sharedContent: { true }
        )
        let vm = ChatViewModel(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: MockTransport(),
            panicRecoveryOperations: operations, weshPrivatePolicyEnabled: true,
            panicPersistentStoreWipes: wipes)
        return (vm, { committed })
    }

    @Test func panicLeavesNoPreviousNicknameInUserDefaultsOrTheKeychain() {
        let keychain = MockKeychain()
        let (vm, committed) = viewModel(keychain: keychain)
        UserDefaults.standard.set("Nora", forKey: LocalNicknameStore.legacyDefaultsKey)
        vm.nickname = "Nora"
        vm.saveNickname()
        #expect(vm.panicClearAllData())
        #expect(committed() == 1)
        #expect(UserDefaults.standard.object(forKey: LocalNicknameStore.legacyDefaultsKey) == nil)
        let stored = keychain.getIdentityKey(forKey: LocalNicknameStore.keychainKey)
        #expect(stored != Data("Nora".utf8))
        #expect(vm.nickname != "Nora")
    }

    @Test func aLockedKeychainAtLaunchNeverMakesTheStandInNamePermanent() {
        let keychain = MockKeychain()
        let (vm, _) = viewModel(keychain: keychain)
        _ = keychain.saveIdentityKey(Data("Nora".utf8), forKey: LocalNicknameStore.keychainKey)
        keychain.identityReadFault = { key, _ in key == LocalNicknameStore.keychainKey ? .deviceLocked : nil }
        vm.loadNickname()
        #expect(vm.isNicknameProvisional)
        #expect(vm.nickname.hasPrefix("anon"))
        // The header field saves on focus loss even when nothing was typed.
        vm.validateAndSaveNickname()
        #expect(keychain.getIdentityKey(forKey: LocalNicknameStore.keychainKey) == Data("Nora".utf8))

        keychain.identityReadFault = nil
        vm.reloadProvisionalNickname()
        #expect(vm.nickname == "Nora")
        #expect(!vm.isNicknameProvisional)
    }

    @Test func aNameTypedWhileTheKeychainWasLockedIsSavedAndKept() {
        let keychain = MockKeychain()
        let (vm, _) = viewModel(keychain: keychain)
        _ = keychain.saveIdentityKey(Data("Nora".utf8), forKey: LocalNicknameStore.keychainKey)
        keychain.identityReadFault = { key, _ in key == LocalNicknameStore.keychainKey ? .deviceLocked : nil }
        vm.loadNickname()
        vm.nickname = "Lea"
        vm.validateAndSaveNickname()
        #expect(!vm.isNicknameProvisional)
        #expect(keychain.getIdentityKey(forKey: LocalNicknameStore.keychainKey) == Data("Lea".utf8))

        keychain.identityReadFault = nil
        vm.reloadProvisionalNickname()
        #expect(vm.nickname == "Lea")
    }

    @Test func panicDoesNotCommitWhileTheNicknameWipeIsUnconfirmed() {
        let keychain = MockKeychain()
        let (vm, committed) = viewModel(keychain: keychain)
        keychain.identityReadFault = { key, _ in key == LocalNicknameStore.keychainKey ? .deviceLocked : nil }
        #expect(!vm.panicClearAllData())
        #expect(committed() == 0)
        #expect(!vm.panicRecoveryBlocked)
    }
}
