import Foundation

/// Timing of the hold-to-erase gesture: three seconds, with rising pulses on the way.
struct PaveHoldSchedule {
    static let duration: TimeInterval = 3
    /// Pulses every half second before completion; completion itself plays `.erase`.
    static let pulseTimes: [TimeInterval] = [0.5, 1, 1.5, 2, 2.5]

    static func progress(elapsed: TimeInterval) -> Double {
        min(max(elapsed / duration, 0), 1)
    }

    static func isComplete(elapsed: TimeInterval) -> Bool {
        elapsed >= duration
    }

    /// Intensities of the pulses crossed between two ticks, rising from 0.3 to 1.
    static func pulses(after previous: TimeInterval, upTo current: TimeInterval) -> [Double] {
        pulseTimes.enumerated().compactMap { index, time in
            guard time > previous, time <= current else { return nil }
            return 0.3 + 0.7 * Double(index) / Double(pulseTimes.count - 1)
        }
    }
}

/// Random, editable nicknames such as « Renard 42 ».
struct PaveNicknameGenerator {
    static let frenchAnimals = [
        "Renard", "Hibou", "Loutre", "Mésange", "Castor", "Lynx", "Héron", "Blaireau",
        "Écureuil", "Faucon", "Hérisson", "Moineau", "Chouette", "Martre", "Bouquetin",
        "Lièvre", "Corbeau", "Pinson", "Belette", "Goéland"
    ]
    static let englishAnimals = [
        "Fox", "Owl", "Otter", "Finch", "Beaver", "Lynx", "Heron", "Badger",
        "Squirrel", "Falcon", "Hedgehog", "Sparrow", "Raven", "Marten", "Ibex",
        "Hare", "Crow", "Robin", "Weasel", "Gull"
    ]
    static let numbers = 2...99

    let animals: [String]

    init(languageCode: String? = Locale.current.language.languageCode?.identifier) {
        animals = languageCode == "fr" ? Self.frenchAnimals : Self.englishAnimals
    }

    func make<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let animal = animals.randomElement(using: &generator) ?? "Renard"
        return "\(animal) \(Int.random(in: Self.numbers, using: &generator))"
    }

    /// A fresh suggestion that differs from the one on screen.
    func make<Generator: RandomNumberGenerator>(differentFrom current: String, using generator: inout Generator) -> String {
        var candidate = make(using: &generator)
        while candidate == current { candidate = make(using: &generator) }
        return candidate
    }
}

/// The two checkmarks of the Échanger screen.
struct PaveExchangeProgress: Equatable {
    /// Your contact scanned your code. Trust flags take no default: callers state both.
    var theyScannedMe: Bool
    /// You scanned your contact's code.
    var iScannedThem: Bool

    var isComplete: Bool { theyScannedMe && iScannedThem }
}

/// Your exchange code expires after five minutes and renews itself.
struct PaveQRRefreshClock: Equatable {
    static let lifetime: TimeInterval = 300

    let issuedAt: Date

    func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(issuedAt) >= Self.lifetime
    }

    /// Whole minutes left, rounded up, never below one while the code is shown.
    func remainingMinutes(at now: Date) -> Int {
        let remaining = Self.lifetime - now.timeIntervalSince(issuedAt)
        return max(1, Int((remaining / 60).rounded(.up)))
    }
}
