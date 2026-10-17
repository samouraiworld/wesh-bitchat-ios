import BitFoundation
import Foundation

/// Reads Pavé copy from the `Pave` string catalog (French and English).
/// Keys are plain literals; `PaveCatalogTests` checks every one resolves in both languages.
enum PaveCopy {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        var format = bundle.localizedString(forKey: key, value: nil, table: "Pave")
        #if SWIFT_PACKAGE
        // A SwiftPM build copies Pave.xcstrings uncompiled: read the source language from it.
        if format == key, let value = uncompiledSource[key] { format = value }
        #endif
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: arguments)
    }

    #if SWIFT_PACKAGE
    private static let uncompiledSource: [String: String] = {
        guard let url = bundle.url(forResource: "Pave", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["strings"] as? [String: [String: Any]] else { return [:] }
        let language = root["sourceLanguage"] as? String ?? "en"
        var values: [String: String] = [:]
        for (key, entry) in entries {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            if let value = (localizations?[language]?["stringUnit"] as? [String: Any])?["value"] as? String {
                values[key] = value
            }
        }
        return values
    }()
    #endif
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
