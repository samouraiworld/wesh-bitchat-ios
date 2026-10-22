import Foundation

/// Persisted Wesh Internet mode opt-in. Off by default; panic clears it.
enum WeshInternetSettings {
    static let enabledKey = "wesh.internetMode.enabled.v1"
    static let disclosureAcceptedKey = "wesh.internetDisclosureAccepted.v1"

    /// Info.plist `WeshInternetAvailable`, from the `WESH_INTERNET_AVAILABLE` build setting.
    /// A build that ships without Internet sets NO: the switch is hidden and the mode stays off,
    /// whatever was stored. Absent (tests, packages), Internet is available.
    static let isAvailable: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "WeshInternetAvailable") as? String)?.uppercased() != "NO"

    static func isEnabled(in defaults: UserDefaults = .standard, available: Bool = WeshInternetSettings.isAvailable) -> Bool {
        available && defaults.bool(forKey: enabledKey)
    }
}
