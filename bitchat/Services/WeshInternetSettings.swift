import Foundation

/// Persisted Wesh Internet mode opt-in. Off by default; panic clears it.
enum WeshInternetSettings {
    static let enabledKey = "wesh.internetMode.enabled.v1"
    static let disclosureAcceptedKey = "wesh.internetDisclosureAccepted.v1"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}
