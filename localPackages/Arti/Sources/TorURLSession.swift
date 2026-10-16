import Foundation
#if os(macOS)
import CFNetwork
#endif

/// Provides the shared URLSession that routes traffic via Tor's SOCKS5 proxy.
///
/// There is no direct session: every request made through it goes to the
/// local Arti SOCKS port, so when Tor is down requests fail instead of
/// leaving through the clearnet.
public final class TorURLSession {
    public static let shared = TorURLSession()

    // Keep in sync with TorManager defaults
    static let socksHost = "127.0.0.1"
    static let socksPort = 39050

    private var torSession: URLSession = TorURLSession.makeTorSession()

    public var session: URLSession { torSession }

    // Recreate the session so new clients bind to the fresh SOCKS port after a Tor restart.
    // Called from the iOS scene activation path only, which the macOS dead-code scan does not see.
    // periphery:ignore
    public func rebuild() {
        torSession = TorURLSession.makeTorSession()
    }

    /// Kept for the activation policy. Asking for direct mode changes
    /// nothing: the session stays proxied (fail-closed).
    public func setProxyMode(useTor: Bool) {}

    static func makeTorSession(host: String = socksHost, port: Int = socksPort) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        #if os(macOS)
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        #else
        // iOS: CFNetwork SOCKS proxy keys are unavailable at compile time.
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port
        ]
        #endif
        return URLSession(configuration: cfg)
    }
}
