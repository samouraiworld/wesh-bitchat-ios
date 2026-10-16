import Foundation
import Testing
@testable import bitchat

@Suite("Pavé hold to erase timing")
struct PaveHoldScheduleTests {
    @Test func takesThreeSeconds() {
        #expect(PaveHoldSchedule.duration == 3)
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

@Suite("Pavé hold tracker fails closed")
struct PaveHoldTrackerTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// Presses at 0 and ticks every 50 ms up to `seconds`, like the view does.
    private func held(until seconds: Double) -> PaveHoldTracker {
        var tracker = PaveHoldTracker()
        tracker.press(at: at(0))
        var time = 0.05
        while time <= seconds + 0.0001 {
            _ = tracker.tick(at: at(time))
            time += 0.05
        }
        return tracker
    }

    @Test func fullHoldErasesExactlyOnce() {
        var tracker = held(until: 3)
        #expect(tracker.progress == 1)
        let result1 = tracker.confirm(at: at(3))
        #expect(result1)
        let result2 = tracker.confirm(at: at(3.01))
        #expect(!result2)
        let result3 = tracker.release(at: at(3.02))
        #expect(!result3)
        #expect(!tracker.isHolding)
    }

    @Test func fullHoldStillErasesWhenThePressEndsJustBeforeCompletion() {
        var tracker = held(until: 3)
        let result4 = tracker.release(at: at(3))
        #expect(result4)
        let result5 = tracker.confirm(at: at(3.05))
        #expect(result5)
        let result6 = tracker.confirm(at: at(3.06))
        #expect(!result6)
    }

    @Test func releasingMidHoldNeverErases() {
        var tracker = held(until: 1.5)
        let result7 = tracker.release(at: at(1.5))
        #expect(!result7)
        // Even a stray completion afterwards is refused.
        let result8 = tracker.confirm(at: at(3))
        #expect(!result8)
        #expect(tracker.progress == 0)
    }

    @Test func backgroundingMidHoldNeverErases() {
        var tracker = held(until: 2.5)
        tracker.cancel()  // scenePhase left .active
        #expect(!tracker.isHolding)
        let result9 = tracker.confirm(at: at(3))
        #expect(!result9)
    }

    @Test func aSuspendedOrStalledHoldResetsInsteadOfCompleting() {
        // The release was never delivered and the app stopped ticking for two seconds.
        var tracker = held(until: 0.5)
        let pulses = tracker.tick(at: at(2.5))
        #expect(pulses.isEmpty)
        #expect(!tracker.isHolding)
        let result10 = tracker.confirm(at: at(3))
        #expect(!result10)
    }

    @Test func aCompletionWithoutRecentTicksIsRefused() {
        var tracker = held(until: 2.9)
        // Last tick at 2.9 s; a completion 0.3 s later means the hold went unobserved.
        let result11 = tracker.confirm(at: at(3.2))
        #expect(!result11)
    }

    @Test func anEarlyCompletionIsRefused() {
        var tracker = held(until: 1)
        let result12 = tracker.confirm(at: at(1))
        #expect(!result12)
    }

    @Test func aReleasedFullHoldExpiresIfTheSystemNeverCompletes() {
        var tracker = held(until: 3)
        let result13 = tracker.release(at: at(3))
        #expect(result13)
        let result14 = tracker.confirm(at: at(3.5))
        #expect(!result14)
    }

    @Test func pulsesRiseOverAFullHold() {
        var tracker = PaveHoldTracker()
        tracker.press(at: at(0))
        var pulses: [Double] = []
        var time = 0.05
        while time <= 3.0001 {
            pulses += tracker.tick(at: at(time))
            time += 0.05
        }
        #expect(pulses == PaveHoldSchedule.pulses(after: 0, upTo: 3))
    }

    @Test func aNewPressStartsFromZero() {
        var tracker = held(until: 1)
        _ = tracker.release(at: at(1))
        tracker.press(at: at(2))
        #expect(tracker.isHolding)
        #expect(tracker.progress == 0)
        let result15 = tracker.confirm(at: at(2.5))
        #expect(!result15)
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
        #expect(!stub.setInternetModeEnabled(true))  // no disclosure yet
        stub.acceptDisclosure()
        #expect(stub.setInternetModeEnabled(true))
        #expect(stub.internetStatus.isEnabled)
        #expect(stub.setInternetModeEnabled(false))
        #expect(stub.internetStatus == .off)
    }
}
