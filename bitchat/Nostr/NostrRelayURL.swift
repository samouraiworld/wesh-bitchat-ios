import Foundation

enum NostrRelayURL {
    static func normalized(_ rawValue: String, defaultScheme: String? = nil) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://"), let defaultScheme {
            value = "\(defaultScheme)://\(value)"
        }

        guard var components = URLComponents(string: value),
              let rawScheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return nil
        }

        switch rawScheme {
        case "wss", "https":
            components.scheme = "wss"
            if components.port == 443 {
                components.port = nil
            }
        case "ws", "http":
            components.scheme = "ws"
            if components.port == 80 {
                components.port = nil
            }
        default:
            return nil
        }

        components.host = rawHost
        if components.path == "/" {
            components.path = ""
        }
        components.fragment = nil

        return components.string
    }

    /// Whether the relay is addressed by a DNS name rather than an IP
    /// literal. Through Tor only names are sent, so the SOCKS request carries
    /// a domain (ATYP 0x03) for the exit to resolve: an address target would
    /// come from a resolution made elsewhere, and the bundled Arti relay
    /// forwards it as is. A top-level label always has a letter and is never
    /// a hex number, which also rules out forms such as `127.1` or `0x7f.1`.
    static func hasDomainNameHost(_ rawValue: String) -> Bool {
        guard let host = URLComponents(string: rawValue)?.host?.lowercased(),
              !host.contains(":"), !host.hasPrefix("[") else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard let tld = name.split(separator: ".", omittingEmptySubsequences: false).last,
              tld.contains(where: \.isLetter) else { return false }
        return !(tld.hasPrefix("0x") && tld.dropFirst(2).allSatisfy(\.isHexDigit))
    }
}
