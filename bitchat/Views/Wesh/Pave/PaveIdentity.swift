import BitFoundation
import Foundation
import SwiftUI

/// The single list of app labels a remote nickname may not imitate: every label drawn next to a
/// nickname (« Vous », « Sans surnom », badges, delivery states, transport, public room, Échanger,
/// Demandes, fingerprint). Checked in French and English whatever the phone language, so a peer
/// cannot pick the other language's word. PaveReservedWordsTests fails when a label of these
/// families is missing.
enum PaveReservedWords {
    static let keys = [
        "pave.bubble.you",
        "pave.name.unnamed",
        "pave.name.reserved",
        "pave.inbox.verified",
        "pave.inbox.unverified",
        "pave.delivery.waiting",
        "pave.delivery.sent",
        "pave.delivery.received",
        "pave.delivery.failed",
        "pave.bubble.failedRetry",
        "pave.bubble.retryA11y",
        "pave.delivery.retry",
        "pave.inbox.noMessage",
        "pave.transport.bluetooth",
        "pave.transport.internet",
        "pave.inbox.publicTitle",
        "pave.inbox.publicFootnote",
        "pave.action.exchange",
        "pave.exchange.title",
        "pave.inbox.requests",
        "pave.fingerprint.label",
        "pave.fingerprint.unavailable"
    ]

    /// Both always ship with the app, so French words stay reserved on a phone set to English.
    static let languages = ["fr", "en"]

    /// Every reserved label in the phone language, French and English.
    static let all: Set<String> = words(in: PaveCopy.bundle)

    /// Skeletons of `all`, built once for every name drawn.
    static let skeletons = PaveReservedSkeletons(all)

    /// Read from each language's compiled table; where the catalog ships uncompiled (a SwiftPM
    /// build copies `Pave.xcstrings` as is), from the catalog itself.
    static func words(in bundle: Bundle) -> Set<String> {
        let catalog = uncompiledCatalog(in: bundle)
        var words = Self.words(from: languages) { language, key in
            let table = bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            if let value = table?.localizedString(forKey: key, value: nil, table: "Pave"), value != key { return value }
            return catalog[language]?[key]
        }
        words.formUnion(keys.map { PaveCopy.text($0) }.filter { !keys.contains($0) })
        return words
    }

    /// language -> key -> value, from a `Pave.xcstrings` resource when one is bundled.
    private static func uncompiledCatalog(in bundle: Bundle) -> [String: [String: String]] {
        guard let url = bundle.url(forResource: "Pave", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["strings"] as? [String: [String: Any]] else { return [:] }
        var catalog: [String: [String: String]] = [:]
        for (key, entry) in entries {
            for (language, localization) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
                    catalog[language, default: [:]][key] = value
                }
            }
        }
        return catalog
    }

    /// Every reserved label read from each of `sources`: one per language.
    static func words<Source>(from sources: [Source], _ lookup: (Source, String) -> String?) -> Set<String> {
        Set(sources.flatMap { source in keys.compactMap { lookup(source, $0) } })
    }
}

/// Short key fingerprint shown after a remote name in identity rows, so the nickname is never the
/// only identity cue.
enum PaveFingerprint {
    private static let noiseKeyBytes = 32
    // 4 groups of 4 hex characters = 64 bits. A cue to tell two identical names apart, not a
    // verification (the QR exchange is); do not shorten it.
    private static let groups = 4
    private static let groupSize = 4

    /// "7F3A 91C2 0B5E 44D8": first 16 hex characters of the SHA-256 of a Noise static key, uppercase.
    static func short(_ noiseKey: Data?) -> String? {
        guard let noiseKey, noiseKey.count == noiseKeyBytes else { return nil }
        let hex = Array(noiseKey.sha256Fingerprint().uppercased().prefix(groups * groupSize))
        return stride(from: 0, to: hex.count, by: groupSize)
            .map { String(hex[$0..<$0 + groupSize]) }
            .joined(separator: " ")
    }

    /// One character at a time for VoiceOver: "7 F 3 A, 9 1 C 2, …".
    static func spoken(_ short: String) -> String {
        short.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }

    /// What VoiceOver says for the fingerprint line of an identity row.
    static func accessibilityText(_ short: String?) -> String {
        guard let short else { return PaveCopy.text("pave.fingerprint.unavailable") }
        return PaveCopy.text("pave.fingerprint.label") + ", " + spoken(short)
    }
}

/// The short fingerprint under a remote name, in monospace, or « Empreinte indisponible ».
/// Callers pass `PaveFingerprint.short(_:)` of the peer's Noise static key.
struct PaveFingerprintText: View {
    let fingerprint: String?
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Group {
            if let fingerprint {
                Text(verbatim: fingerprint)
                    .paveText(.fingerprint)
                    .foregroundStyle(theme[.inkMuted])
            } else {
                Text(PaveCopy.text("pave.fingerprint.unavailable"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.warning])
            }
        }
        // Two lines at accessibility sizes, so all 16 characters stay visible.
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .accessibilityLabel(PaveFingerprint.accessibilityText(fingerprint))
    }
}
