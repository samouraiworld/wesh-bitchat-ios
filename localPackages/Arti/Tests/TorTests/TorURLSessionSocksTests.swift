import Foundation
import XCTest
@testable import Tor

/// One-shot SOCKS5 server on 127.0.0.1 that records the CONNECT request and
/// refuses it, so nothing ever leaves the machine.
private final class FakeSocksServer: @unchecked Sendable {
    struct ConnectRequest: Equatable {
        let addressType: UInt8
        let host: String
        let port: UInt16
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var _request: ConnectRequest?
    private var _greeting: [UInt8] = []

    var request: ConnectRequest? { lock.withLock { _request } }
    var greeting: [UInt8] { lock.withLock { _greeting } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    func serveOnce(onRequest: @escaping @Sendable () -> Void) {
        let fd = listenFD
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard let head = readExactly(client, 2), head[0] == 0x05,
                  let methods = readExactly(client, Int(head[1])) else {
                lock.withLock { _greeting = readAvailable(client) }
                onRequest()
                return
            }
            lock.withLock { _greeting = head + methods }
            _ = writeAll(client, [0x05, 0x00])
            guard let header = readExactly(client, 4) else { onRequest(); return }
            let atyp = header[3]
            var host = ""
            switch atyp {
            case 0x01:
                host = (readExactly(client, 4) ?? []).map(String.init).joined(separator: ".")
            case 0x03:
                if let len = readExactly(client, 1), let name = readExactly(client, Int(len[0])) {
                    host = String(bytes: name, encoding: .utf8) ?? ""
                }
            case 0x04:
                host = (readExactly(client, 16) ?? []).map { String(format: "%02x", $0) }.joined()
            default:
                break
            }
            let portBytes = readExactly(client, 2) ?? [0, 0]
            lock.withLock {
                _request = ConnectRequest(addressType: atyp, host: host, port: UInt16(portBytes[0]) << 8 | UInt16(portBytes[1]))
            }
            // General failure: the client gives up, no traffic is relayed.
            _ = writeAll(client, [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            onRequest()
        }
    }

    func stop() { close(listenFD) }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            guard n > 0 else { return nil }
            offset += n
        }
        return buffer
    }

    private func readAvailable(_ fd: Int32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, 64, MSG_DONTWAIT) }
        return n > 0 ? Array(buffer.prefix(n)) : []
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { send(fd, $0.baseAddress!, bytes.count, 0) } == bytes.count
    }
}

final class TorURLSessionSocksTests: XCTestCase {
    /// The relay hostname must reach the SOCKS proxy as a domain name
    /// (ATYP 0x03) so Tor resolves it at the exit. An IPv4/IPv6 address type
    /// here would mean the name was resolved on the device, in clear DNS.
    func test_relayWebSocket_sendsTheHostnameToSocksAsDomainName() throws {
        for relay in ["relay.damus.io", "relay.primal.net", "offchain.pub"] {
            let server = try FakeSocksServer()
            defer { server.stop() }
            let handled = expectation(description: "SOCKS request for \(relay)")
            server.serveOnce { handled.fulfill() }

            let session = TorURLSession.makeTorSession(port: Int(server.port))
            let task = session.webSocketTask(with: URL(string: "wss://\(relay)")!)
            task.resume()
            wait(for: [handled], timeout: 10)
            task.cancel()
            session.invalidateAndCancel()

            XCTAssertEqual(server.greeting.first, 0x05, "\(relay): the proxy must be spoken to in SOCKS5")
            XCTAssertEqual(server.request, .init(addressType: 0x03, host: relay, port: 443))
        }
    }

    func test_httpsFetch_sendsTheHostnameToSocksAsDomainName() throws {
        let server = try FakeSocksServer()
        defer { server.stop() }
        let handled = expectation(description: "SOCKS request")
        server.serveOnce { handled.fulfill() }

        let session = TorURLSession.makeTorSession(port: Int(server.port))
        let task = session.dataTask(with: URL(string: "https://relay.damus.io/")!)
        task.resume()
        wait(for: [handled], timeout: 10)
        task.cancel()
        session.invalidateAndCancel()

        XCTAssertEqual(server.request, .init(addressType: 0x03, host: "relay.damus.io", port: 443))
    }

    func test_sharedSession_staysProxiedWhenDirectModeIsRequested() {
        let urlSession = TorURLSession()

        urlSession.setProxyMode(useTor: false)
        urlSession.rebuild()

        let proxy = urlSession.session.configuration.connectionProxyDictionary
        XCTAssertEqual(proxy?["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(proxy?["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy?["SOCKSPort"] as? Int, 39050)
    }
}
