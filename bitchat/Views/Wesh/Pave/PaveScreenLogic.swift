import Foundation

/// Timing of the hold-to-erase gesture: three seconds, with rising pulses on the way.
struct PaveHoldSchedule {
    static let duration: TimeInterval = 3
    /// Pulses every half second before completion; completion itself plays `.erase`.
    static let pulseTimes: [TimeInterval] = [0.5, 1, 1.5, 2, 2.5]

    static func progress(elapsed: TimeInterval) -> Double {
        min(max(elapsed / duration, 0), 1)
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

/// Fail-closed state of one hold-to-erase press.
///
/// The system long press decides whether the finger stayed down for three seconds. On top of
/// that, this tracker requires an uninterrupted hold measured on a monotonic clock: a release
/// that never arrives, an app suspended mid-hold or a stalled main thread resets it, so none
/// of them can complete an erase. Either order of « press ended » and « press completed » works.
struct PaveHoldTracker {
    typealias Instant = ContinuousClock.Instant

    static let tickInterval: Duration = .milliseconds(50)
    /// A tick later than twice the interval means the hold was not observed: reset.
    static let maximumGap: Duration = .milliseconds(100)
    /// Slack between the system's own three-second timer and this clock.
    static let tolerance: Duration = .milliseconds(150)
    private static let required: Duration = .seconds(PaveHoldSchedule.duration) - tolerance

    private enum Phase {
        case idle
        case holding(start: Instant, lastSeen: Instant)
        /// The press ended after a full hold; the system completion may still arrive until `deadline`.
        case released(deadline: Instant)
    }

    private var phase: Phase = .idle
    private var pulsedUpTo: TimeInterval = 0
    private(set) var progress: Double = 0

    var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    mutating func press(at now: Instant) {
        phase = .holding(start: now, lastSeen: now)
        pulsedUpTo = 0
        progress = 0
    }

    /// Advances the ring; returns the intensities of the pulses crossed since the last tick.
    mutating func tick(at now: Instant) -> [Double] {
        guard case let .holding(start, lastSeen) = phase else { return [] }
        guard now - lastSeen <= Self.maximumGap else {
            cancel()
            return []
        }
        phase = .holding(start: start, lastSeen: now)
        let elapsed = Self.seconds(now - start)
        let pulses = PaveHoldSchedule.pulses(after: pulsedUpTo, upTo: elapsed)
        pulsedUpTo = elapsed
        progress = PaveHoldSchedule.progress(elapsed: elapsed)
        return pulses
    }

    /// The press ended or was cancelled. Returns whether it can still be confirmed,
    /// which only a press that already lasted the full duration can, briefly.
    @discardableResult
    mutating func release(at now: Instant) -> Bool {
        guard case let .holding(start, lastSeen) = phase,
              now - lastSeen <= Self.maximumGap, now - start >= Self.required else {
            cancel()
            return false
        }
        phase = .released(deadline: now + Self.tolerance)
        return true
    }

    /// The system long press completed. True at most once per press.
    mutating func confirm(at now: Instant) -> Bool {
        let valid: Bool
        switch phase {
        case let .holding(start, lastSeen):
            valid = now - lastSeen <= Self.maximumGap && now - start >= Self.required
        case let .released(deadline):
            valid = now <= deadline
        case .idle:
            valid = false
        }
        cancel()
        return valid
    }

    /// Every other way out: disappearing, leaving the foreground, an assistive confirmation.
    mutating func cancel() {
        phase = .idle
        pulsedUpTo = 0
        progress = 0
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Short fingerprints Échanger shows: yours under your code, the contact's once both checks are done.
struct PaveExchangeFingerprints: Equatable {
    let mine: String?
    let contact: String?

    init(mine: String?, contact: String?, progress: PaveExchangeProgress) {
        self.mine = mine
        self.contact = progress.isComplete ? contact : nil
    }
}

/// The success card opens the private chat only on « Ouvrir la discussion », and only once.
struct PaveCompletionLatch {
    private(set) var fired = false

    mutating func fire(_ action: () -> Void) {
        guard !fired else { return }
        fired = true
        action()
    }
}

/// In a crowd, the Échanger scanner reads only the code aimed at: inside the viewfinder, and only
/// when that frame holds a single code.
enum PaveScanArea {
    /// Side of the square viewfinder, in points.
    static let side: CGFloat = 150

    /// The viewfinder, centered in a camera view of `size`, never larger than the view.
    static func viewfinder(in size: CGSize) -> CGRect {
        let edge = min(side, size.width, size.height)
        return CGRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
    }

    /// The text of the only QR code in a frame; nil when the frame reports none or several.
    static func singleCode(_ codes: [String?]) -> String? {
        codes.count == 1 ? codes[0] : nil
    }
}

/// The two checks of Échanger. They never carry the contact's name: it is peer-chosen, and a check
/// is a trust signal.
enum PaveExchangeCheck: CaseIterable {
    /// Your contact scanned your code.
    case yourCode
    /// You scanned your contact's code.
    case theirCode

    func label(done: Bool) -> String {
        switch self {
        case .yourCode: return PaveCopy.text(done ? "pave.exchange.theyScanned" : "pave.exchange.yourCode")
        case .theirCode: return PaveCopy.text(done ? "pave.exchange.iScanned" : "pave.exchange.theirCode")
        }
    }
}

/// Camera authorization as Échanger reads it.
enum PaveCameraAuthorization {
    case notDetermined, authorized, denied, restricted
}

/// What the camera area shows: the rationale with « Autoriser la caméra » (the only place the system
/// prompt is triggered), the scanner, or the way to Réglages.
enum PaveCameraCard: Equatable {
    case rationale, scanner, settings

    /// iOS asks once: a refusal is permanent, so only then does Réglages appear.
    init(_ authorization: PaveCameraAuthorization) {
        switch authorization {
        case .notDetermined: self = .rationale
        case .authorized: self = .scanner
        case .denied, .restricted: self = .settings
        }
    }
}

extension PaveFingerprint {
    /// `short(_:)` computed off the main thread, so a screen never hashes while drawing.
    static func computed(_ noiseKey: Data?) async -> String? {
        await Task.detached(priority: .userInitiated) { short(noiseKey) }.value
    }
}
