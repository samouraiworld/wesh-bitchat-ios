import Foundation
#if os(macOS)
import CFNetwork
#endif

/// The local SOCKS port and the RFC 1929 login Arti requires, both new for each Tor start,
/// so another app on the phone can neither find the proxy at a known port nor use it.
struct SocksEndpoint: Equatable, Sendable, CustomStringConvertible {
    let host: String
    let port: Int
    let username: String
    let password: String

    /// Above the well-known ports and below the ephemeral range, as on Android.
    static let portRange = 10_000..<32_768

    /// The default generator is the system CSPRNG on Apple platforms.
    static func random() -> SocksEndpoint {
        SocksEndpoint(host: "127.0.0.1", port: Int.random(in: portRange), username: token(), password: token())
    }

    private static func token() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    var description: String { "SocksEndpoint(\(host):\(port), login redacted)" }
}

/// Provides the shared URLSession that routes traffic via Tor's SOCKS5 proxy.
///
/// There is no direct session: every request made through it goes to the
/// local Arti SOCKS port, so when Tor is down requests fail instead of
/// leaving through the clearnet.
public final class TorURLSession {
    public static let shared = TorURLSession()

    /// Where the next or current Arti listens; nothing listens there before a start.
    private(set) var endpoint: SocksEndpoint
    private var torSession: URLSession

    public var session: URLSession { torSession }

    init() {
        endpoint = .random()
        torSession = TorURLSession.makeTorSession(endpoint: endpoint)
    }

    /// A fresh port and login for a new Arti start; requests made after it use them.
    func renewEndpoint() -> SocksEndpoint {
        endpoint = .random()
        torSession = TorURLSession.makeTorSession(endpoint: endpoint)
        return endpoint
    }

    /// Back to `endpoint` after a refused start, so the session keeps matching the Arti that runs.
    func restoreEndpoint(_ endpoint: SocksEndpoint) {
        self.endpoint = endpoint
        torSession = TorURLSession.makeTorSession(endpoint: endpoint)
    }

    // Recreate the session so new clients bind to the fresh SOCKS port after a Tor restart.
    // Called from the iOS scene activation path only, which the macOS dead-code scan does not see.
    // periphery:ignore
    public func rebuild() {
        torSession = TorURLSession.makeTorSession(endpoint: endpoint)
    }

    /// Kept for the activation policy. Asking for direct mode changes
    /// nothing: the session stays proxied (fail-closed).
    public func setProxyMode(useTor: Bool) {}

    static func makeTorSession(endpoint: SocksEndpoint) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        #if os(macOS)
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: endpoint.host,
            kCFNetworkProxiesSOCKSPort as String: endpoint.port,
            kCFStreamPropertySOCKSUser as String: endpoint.username,
            kCFStreamPropertySOCKSPassword as String: endpoint.password
        ]
        #else
        // iOS: CFNetwork SOCKS proxy keys are unavailable at compile time; these are their values.
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": endpoint.host,
            "SOCKSPort": endpoint.port,
            "kCFStreamPropertySOCKSUser": endpoint.username,
            "kCFStreamPropertySOCKSPassword": endpoint.password
        ]
        #endif
        return URLSession(configuration: cfg)
    }
}
