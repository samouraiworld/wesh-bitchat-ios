import Foundation

/// The courtesy notice attempted when you take a screenshot of a private conversation.
///
/// On the wire it stays the BitChat action message `* <nickname> took a screenshot *`, in
/// English: BitChat and earlier Wesh builds recognise that exact text and show it as a system
/// line. It travels as an ordinary private message; each receiver shows it in its own language.
/// The notice is on by default, as in BitChat, and can be turned off in Discretion.
enum WeshScreenshotNotice {
    static let enabledKey = "wesh.screenshotNotice.enabled"
    private static let actionSuffix = " took a screenshot"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Panic-wipe hook: an erased phone comes back with the default, like a new install.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
    }

    static func wireText(nickname: String) -> String {
        "* \(nickname)\(actionSuffix) *"
    }

    /// The sender's nickname when an action body (the wire text without its asterisks) is a
    /// screenshot notice.
    static func nickname(inActionBody body: String) -> String? {
        guard body.hasSuffix(actionSuffix) else { return nil }
        let nickname = String(body.dropLast(actionSuffix.count))
        return nickname.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nickname
    }

    /// « Renard 42 a fait une capture d’écran », shown to the receiver.
    static func peerLine(nickname: String, bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        PaveCopy.text("pave.screenshot.peer", bundle: bundle, locale: locale, nickname)
    }

    /// Shown locally after attempting the notice; delivery to the contact is not confirmed.
    static func outgoingNoticeLine(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        PaveCopy.text("pave.screenshot.contactNotified", bundle: bundle, locale: locale)
    }
}
