import BitFoundation
import Foundation

/// Reads Pavé copy from the `Pave` string catalog (French and English).
/// Keys are plain literals; `PaveCatalogTests` checks every one resolves in both languages.
enum PaveCopy {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: "Pave")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: arguments)
    }
}

/// Every name that comes from another phone goes through `safe(_:)` before it is drawn.
/// A peer chooses its nickname freely, so it must not be able to spoof a status, reorder
/// text with bidi controls, stack combining marks over other lines, or push a badge away.
enum PaveDisplayName {
    static let maximumGraphemes = 32
    /// Combining marks kept after one base character; NFKC already composes ordinary accents.
    static let maximumCombiningMarks = 2
    /// Assigned code points that draw nothing: Hangul fillers, the blank Braille cell, Khmer
    /// inherent vowels, Mongolian variation selectors and the vowel separator, variation selectors.
    static let blankScalars: [ClosedRange<UInt32>] = [
        0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180E, 0x2800...0x2800,
        0x3164...0x3164, 0xFE00...0xFE0F, 0xFFA0...0xFFA0
    ]

    static func safe(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var combiningRun = 0
        var lastWasSpace = true
        // A name must show at least one letter, digit, symbol or punctuation mark.
        var hasVisible = false
        for scalar in raw.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if blankScalars.contains(where: { $0.contains(scalar.value) }) { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator,
                 .privateUse, .surrogate, .unassigned:
                // Cc, Cf (bidi overrides and isolates, zero-width characters), separators, Co, Cs, Cn.
                continue
            case .nonspacingMark, .spacingMark, .enclosingMark:
                combiningRun += 1
                guard combiningRun <= maximumCombiningMarks, !lastWasSpace else { continue }
                scalars.append(scalar)
            case .spaceSeparator:
                combiningRun = 0
                guard !lastWasSpace else { continue }
                scalars.append(" ")
                lastWasSpace = true
            default:
                // What is left is L*, N*, S* or P*: visible.
                combiningRun = 0
                lastWasSpace = false
                hasVisible = true
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        guard hasVisible, !cleaned.isEmpty else { return PaveCopy.text("pave.name.unnamed") }
        // A peer may not take a name the interface itself writes, such as « Vous ».
        if isReserved(cleaned) { return PaveCopy.text("pave.name.reserved") }
        guard cleaned.count > maximumGraphemes else { return cleaned }
        return String(cleaned.prefix(maximumGraphemes - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Strings the interface writes in place of, or next to, a name, in both languages.
    static var reservedNames: [String] {
        ["Vous", "You", "Sans surnom", "No nickname", "Sans surnom (réservé)", "No nickname (reserved)",
         PaveCopy.text("pave.bubble.you"), PaveCopy.text("pave.name.unnamed"), PaveCopy.text("pave.name.reserved")]
    }

    static func isReserved(_ name: String) -> Bool {
        func fold(_ text: String) -> String { text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        let folded = fold(name)
        return reservedNames.contains {
            folded.compare(fold($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
    }
}

/// The four delivery states shown under a bubble. Read receipts are never shown.
enum PaveDeliveryState: CaseIterable {
    case waiting, sent, received, failed

    init(_ status: DeliveryStatus, isPrivate: Bool) {
        switch status {
        case .notSentYet, .sending:
            self = .waiting
        case .sent, .carried, .partiallyDelivered:
            self = .sent
        case .delivered, .read:
            // A public message has no recipient acknowledgement to show.
            self = isPrivate ? .received : .sent
        case .failed:
            self = .failed
        }
    }

    var label: String {
        switch self {
        case .waiting: return PaveCopy.text("pave.delivery.waiting")
        case .sent: return PaveCopy.text("pave.delivery.sent")
        case .received: return PaveCopy.text("pave.delivery.received")
        case .failed: return PaveCopy.text("pave.delivery.failed")
        }
    }
}

/// How a message travelled. Only shown when it adds information.
enum PaveTransport {
    case bluetooth, internet

    var label: String {
        self == .internet ? PaveCopy.text("pave.transport.internet") : PaveCopy.text("pave.transport.bluetooth")
    }
}

/// The 2,000-byte admission limit; the counter appears only past 1,800 bytes.
struct PaveMessageBudget: Equatable {
    static let maximumBytes = WeshTextLimits.maximumUTF8Bytes
    static let counterThreshold = 1800

    let usedBytes: Int

    init(_ text: String) {
        usedBytes = text.utf8.count
    }

    var showsCounter: Bool { usedBytes > Self.counterThreshold }
    var isOverLimit: Bool { usedBytes > Self.maximumBytes }

    static func canSend(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !PaveMessageBudget(text).isOverLimit
    }
}

/// The single source of truth shown by the status pill.
enum PaveConnectionStatus: Equatable {
    case inRange(Int)
    case nobodyInRange
    case bluetoothOff
    case internet(inRange: Int)

    init(bluetoothOn: Bool, peersInRange: Int, internetActive: Bool) {
        if internetActive {
            self = .internet(inRange: bluetoothOn ? max(peersInRange, 0) : 0)
        } else if !bluetoothOn {
            self = .bluetoothOff
        } else if peersInRange > 0 {
            self = .inRange(peersInRange)
        } else {
            self = .nobodyInRange
        }
    }

    var label: String {
        switch self {
        case .inRange(let count): return PaveCopy.text("pave.status.inRange", count)
        case .nobodyInRange: return PaveCopy.text("pave.status.nobody")
        case .bluetoothOff: return PaveCopy.text("pave.status.bluetoothOff")
        case .internet(let count): return PaveCopy.text("pave.status.internet", count)
        }
    }
}
