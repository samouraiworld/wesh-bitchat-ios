import Foundation

/// Wesh has no media. The line shown for a private file from a QR contact,
/// and any media reference an older build stored as message text
/// ("[image] …", "[voice] …", "[file] …"), read as the same placeholder.
enum WeshIncomingMediaPolicy {
    static var placeholder: String { PaveCopy.text("pave.media.unsupported") }

    static func displayText(_ content: String) -> String {
        legacyMediaPrefixes.contains(where: { content.hasPrefix($0) }) ? placeholder : content
    }

    private static let legacyMediaPrefixes = ["[voice] ", "[image] ", "[file] "]
}
