import Foundation
import Testing
@testable import bitchat

@Suite("Pavé hold to erase timing")
struct PaveHoldScheduleTests {
    @Test func takesThreeSeconds() {
        #expect(PaveHoldSchedule.duration == 3)
        #expect(!PaveHoldSchedule.isComplete(elapsed: 2.99))
        #expect(PaveHoldSchedule.isComplete(elapsed: 3))
    }

    @Test func progressIsClamped() {
        #expect(PaveHoldSchedule.progress(elapsed: -1) == 0)
        #expect(PaveHoldSchedule.progress(elapsed: 1.5) == 0.5)
        #expect(PaveHoldSchedule.progress(elapsed: 10) == 1)
    }

    @Test func pulsesRiseAndFireOncePerThreshold() {
        let all = PaveHoldSchedule.pulses(after: 0, upTo: 3)
        #expect(all.count == 5)
        #expect(all == all.sorted())
        #expect(all.first == 0.3)
        #expect(all.last == 1)
        // Ticking in small steps crosses each pulse exactly once.
        var crossed: [Double] = []
        var previous: TimeInterval = 0
        for step in 1...90 {
            let current = Double(step) / 30
            crossed += PaveHoldSchedule.pulses(after: previous, upTo: current)
            previous = current
        }
        #expect(crossed == all)
    }

    @Test func noPulseBeforeHalfASecond() {
        #expect(PaveHoldSchedule.pulses(after: 0, upTo: 0.49).isEmpty)
    }
}

@Suite("Pavé nickname generator")
struct PaveNicknameGeneratorTests {
    /// Deterministic generator so the tests never flake.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test func frenchNicknamesLookLikeRenard42() throws {
        var generator = SeededGenerator(state: 42)
        let nickname = PaveNicknameGenerator(languageCode: "fr").make(using: &generator)
        let parts = nickname.split(separator: " ")
        #expect(parts.count == 2)
        #expect(PaveNicknameGenerator.frenchAnimals.contains(String(parts[0])))
        let number = try #require(Int(parts[1]))
        #expect(PaveNicknameGenerator.numbers.contains(number))
    }

    @Test func otherLanguagesUseEnglishWords() {
        #expect(PaveNicknameGenerator(languageCode: "en").animals == PaveNicknameGenerator.englishAnimals)
        #expect(PaveNicknameGenerator(languageCode: "de").animals == PaveNicknameGenerator.englishAnimals)
        #expect(PaveNicknameGenerator(languageCode: nil).animals == PaveNicknameGenerator.englishAnimals)
    }

    @Test func shuffleAlwaysOffersADifferentNickname() {
        var generator = SeededGenerator(state: 7)
        let names = PaveNicknameGenerator(languageCode: "fr")
        var current = names.make(using: &generator)
        for _ in 0..<200 {
            let next = names.make(differentFrom: current, using: &generator)
            #expect(next != current)
            current = next
        }
    }

    @Test func nicknamesFitTheProfileLimit() {
        let longest = (PaveNicknameGenerator.frenchAnimals + PaveNicknameGenerator.englishAnimals)
            .map { "\($0) 99".utf8.count }.max() ?? 0
        #expect(longest <= 255)
    }
}

@Suite("Pavé exchange and Internet stub")
struct PaveExchangeTests {
    @Test func exchangeCompletesOnlyWithBothCheckmarks() {
        var progress = PaveExchangeProgress(theyScannedMe: false, iScannedThem: false)
        #expect(!progress.isComplete)
        progress.theyScannedMe = true
        #expect(!progress.isComplete)
        progress.iScannedThem = true
        #expect(progress.isComplete)
        #expect(!PaveExchangeProgress(theyScannedMe: false, iScannedThem: true).isComplete)
    }

    @Test func codeRenewsEveryFiveMinutes() {
        let issued = Date(timeIntervalSince1970: 1000)
        let clock = PaveQRRefreshClock(issuedAt: issued)
        #expect(PaveQRRefreshClock.lifetime == 300)
        #expect(clock.remainingMinutes(at: issued) == 5)
        #expect(clock.remainingMinutes(at: issued + 61) == 4)
        #expect(clock.remainingMinutes(at: issued + 299) == 1)
        #expect(!clock.isExpired(at: issued + 299))
        #expect(clock.isExpired(at: issued + 300))
    }

    @Test @MainActor func internetStubTogglesLocallyOnly() {
        let stub = PaveInternetModeStub()
        #expect(stub.internetStatus == .off)
        #expect(!stub.internetStatus.isEnabled)
        stub.setInternetModeEnabled(true)
        #expect(stub.internetStatus.isEnabled)
        stub.setInternetModeEnabled(false)
        #expect(stub.internetStatus == .off)
    }
}
