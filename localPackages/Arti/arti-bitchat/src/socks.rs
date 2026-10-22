//! SOCKS5 protocol handler for Arti
//!
//! Greeting and CONNECT request of the minimal SOCKS5 server that forwards connections
//! through Tor. Only tokio and std, so the rules can be tested without Arti.

use std::io;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

// SOCKS5 constants
const SOCKS5_VERSION: u8 = 0x05;
const SOCKS5_AUTH_USER_PASS: u8 = 0x02;
const SOCKS5_AUTH_NO_ACCEPTABLE: u8 = 0xFF;
const USER_PASS_VERSION: u8 = 0x01;
const USER_PASS_SUCCESS: u8 = 0x00;
const USER_PASS_FAILURE: u8 = 0x01;
const SOCKS5_CMD_CONNECT: u8 = 0x01;
const SOCKS5_ATYP_IPV4: u8 = 0x01;
const SOCKS5_ATYP_DOMAIN: u8 = 0x03;
pub const SOCKS5_REP_SUCCESS: u8 = 0x00;
pub const SOCKS5_REP_FAILURE: u8 = 0x01;
pub const SOCKS5_REP_CONN_REFUSED: u8 = 0x05;
const SOCKS5_REP_ADDRESS_NOT_SUPPORTED: u8 = 0x08;

/// Longest a client may take for its greeting and request. Our own clients answer at once
/// over loopback; a short limit keeps stalled sockets from holding places.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);

/// Concurrent connections past their handshake. More are refused, so no local app can
/// exhaust our file descriptors.
pub const MAX_CONNECTIONS: usize = 64;

/// Concurrent connections still in their handshake. Kept apart and small, so sockets that
/// never send a request cannot take the places of working ones.
pub const MAX_HANDSHAKES: usize = 16;

/// The username and password (RFC 1929) set for one start. Only the app that started Arti
/// knows them, so another app on the phone can neither use the local Tor port nor tell it
/// apart from a closed one by completing a handshake.
pub struct Credentials {
    username: Vec<u8>,
    password: Vec<u8>,
}

impl Credentials {
    /// Each part holds 1 to 255 bytes, the RFC 1929 limits.
    pub fn new(username: &[u8], password: &[u8]) -> Option<Self> {
        let valid = |part: &[u8]| (1..=255).contains(&part.len());
        (valid(username) && valid(password))
            .then(|| Self { username: username.to_vec(), password: password.to_vec() })
    }

    fn accepts(&self, username: &[u8], password: &[u8]) -> bool {
        same(&self.username, username) & same(&self.password, password)
    }
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Credentials(redacted)")
    }
}

/// Compares without stopping at the first differing byte.
fn same(expected: &[u8], given: &[u8]) -> bool {
    expected.len() == given.len()
        && expected.iter().zip(given).fold(0u8, |diff, (a, b)| diff | (a ^ b)) == 0
}

/// `handshake`, given up after `limit`.
pub async fn timed_handshake<S>(
    stream: &mut S,
    credentials: &Credentials,
    limit: Duration,
) -> io::Result<(String, u16)>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    match tokio::time::timeout(limit, handshake(stream, credentials)).await {
        Ok(target) => target,
        Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "SOCKS handshake timed out")),
    }
}

/// Greeting, username/password login and CONNECT request; returns the requested host name
/// and port.
pub async fn handshake<S>(stream: &mut S, credentials: &Credentials) -> io::Result<(String, u16)>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    // --- Greeting ---
    // Client sends: VER | NMETHODS | METHODS
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;

    if greeting[0] != SOCKS5_VERSION {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Not SOCKS5"));
    }

    let nmethods = greeting[1] as usize;
    let mut methods = vec![0u8; nmethods];
    stream.read_exact(&mut methods).await?;

    // Only username/password: a client without the start's login is turned away.
    if !methods.contains(&SOCKS5_AUTH_USER_PASS) {
        stream.write_all(&[SOCKS5_VERSION, SOCKS5_AUTH_NO_ACCEPTABLE]).await?;
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "No acceptable auth methods",
        ));
    }
    stream.write_all(&[SOCKS5_VERSION, SOCKS5_AUTH_USER_PASS]).await?;

    // --- Login (RFC 1929) ---
    // Client sends: VER | ULEN | UNAME | PLEN | PASSWD
    let mut login_header = [0u8; 2];
    stream.read_exact(&mut login_header).await?;
    if login_header[0] != USER_PASS_VERSION {
        stream.write_all(&[USER_PASS_VERSION, USER_PASS_FAILURE]).await?;
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "SOCKS login refused"));
    }
    let mut username = vec![0u8; login_header[1] as usize];
    stream.read_exact(&mut username).await?;
    let mut password_len = [0u8; 1];
    stream.read_exact(&mut password_len).await?;
    let mut password = vec![0u8; password_len[0] as usize];
    stream.read_exact(&mut password).await?;
    if !credentials.accepts(&username, &password) {
        stream.write_all(&[USER_PASS_VERSION, USER_PASS_FAILURE]).await?;
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "SOCKS login refused"));
    }
    stream.write_all(&[USER_PASS_VERSION, USER_PASS_SUCCESS]).await?;

    // --- Request ---
    // Client sends: VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT
    let mut request_header = [0u8; 4];
    stream.read_exact(&mut request_header).await?;

    if request_header[0] != SOCKS5_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid SOCKS5 request version",
        ));
    }

    let cmd = request_header[1];
    let atyp = request_header[3];

    if cmd != SOCKS5_CMD_CONNECT {
        // We only support CONNECT
        send_reply(stream, SOCKS5_REP_FAILURE).await?;
        return Err(io::Error::new(io::ErrorKind::Unsupported, "Only CONNECT supported"));
    }

    // Only a host name is accepted. An IP target means the caller resolved the name itself,
    // outside Tor, so the request is refused before its address is even read.
    if atyp != SOCKS5_ATYP_DOMAIN {
        send_reply(stream, SOCKS5_REP_ADDRESS_NOT_SUPPORTED).await?;
        return Err(io::Error::new(io::ErrorKind::Unsupported, "Only host name targets supported"));
    }

    let mut len_buf = [0u8; 1];
    stream.read_exact(&mut len_buf).await?;
    let mut name = vec![0u8; len_buf[0] as usize];
    stream.read_exact(&mut name).await?;
    let port = read_port(stream).await?;

    match host_name(&name) {
        Ok(host) => Ok((host, port)),
        Err(rep) => {
            send_reply(stream, rep).await?;
            Err(io::Error::new(io::ErrorKind::InvalidData, "Invalid host name"))
        }
    }
}

/// A requested host name, lowercased and without a final dot, or the SOCKS reply code that
/// refuses it. IP forms, including those other resolvers accept (`127.1`, `2130706433`,
/// `0x7f.0.0.1`), get "address type not supported"; anything else that is not a DNS name
/// (labels of 1 to 63 letters, digits or inner hyphens, 253 characters at most; IDNs arrive
/// as punycode) gets a general failure. The last label needs a letter and is never a hex
/// number, as in `NostrRelayURL.hasDomainNameHost` on the Swift side.
fn host_name(bytes: &[u8]) -> Result<String, u8> {
    let raw = std::str::from_utf8(bytes).map_err(|_| SOCKS5_REP_FAILURE)?;
    if raw.starts_with('[') || raw.contains(':') {
        return Err(SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
    }
    let name = raw.strip_suffix('.').unwrap_or(raw);
    if name.parse::<std::net::IpAddr>().is_ok() {
        return Err(SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
    }
    if name.is_empty() || name.len() > 253 {
        return Err(SOCKS5_REP_FAILURE);
    }
    let is_label = |label: &str| {
        (1..=63).contains(&label.len())
            && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    };
    if !name.split('.').all(is_label) {
        return Err(SOCKS5_REP_FAILURE);
    }
    let last = name.rsplit('.').next().unwrap_or(name).to_ascii_lowercase();
    let hex = last.strip_prefix("0x").is_some_and(|d| d.bytes().all(|b| b.is_ascii_hexdigit()));
    if !last.bytes().any(|b| b.is_ascii_alphabetic()) || hex {
        return Err(SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
    }
    Ok(name.to_ascii_lowercase())
}

async fn read_port<S: AsyncRead + Unpin>(stream: &mut S) -> io::Result<u16> {
    let mut port_buf = [0u8; 2];
    stream.read_exact(&mut port_buf).await?;
    Ok(u16::from_be_bytes(port_buf))
}

// Reply: VER | REP | RSV | ATYP | BND.ADDR | BND.PORT, bound to 0.0.0.0:0 since we proxy.
pub async fn send_reply<S: AsyncWrite + Unpin>(stream: &mut S, rep: u8) -> io::Result<()> {
    let reply = [
        SOCKS5_VERSION,
        rep,
        0x00, // RSV
        SOCKS5_ATYP_IPV4,
        0, 0, 0, 0, // BND.ADDR
        0, 0, // BND.PORT
    ];
    stream.write_all(&reply).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{duplex, DuplexStream};

    fn credentials() -> Credentials {
        Credentials::new(b"wesh-user", b"wesh-pass").unwrap()
    }

    /// Greeting offering `methods`, then an RFC 1929 login when given.
    fn greeting(methods: &[u8], login: Option<(&[u8], &[u8])>) -> Vec<u8> {
        let mut bytes = vec![0x05, methods.len() as u8];
        bytes.extend_from_slice(methods);
        if let Some((user, pass)) = login {
            bytes.extend_from_slice(&[0x01, user.len() as u8]);
            bytes.extend_from_slice(user);
            bytes.push(pass.len() as u8);
            bytes.extend_from_slice(pass);
        }
        bytes
    }

    /// Runs the server handshake against a client that sends `opening` then `request`;
    /// returns the server result and every byte the server sent.
    async fn raw_exchange(opening: &[u8], request: &[u8]) -> (io::Result<(String, u16)>, Vec<u8>) {
        let (mut client, mut server) = duplex(1024);
        client.write_all(opening).await.unwrap();
        client.write_all(request).await.unwrap();
        let result = handshake(&mut server, &credentials()).await;
        drop(server);
        let mut reply = Vec::new();
        client.read_to_end(&mut reply).await.unwrap();
        (result, reply)
    }

    /// Runs the server handshake against a client that logs in, then sends `request`;
    /// returns the server result and every byte the server sent after the login replies.
    async fn exchange(request: &[u8]) -> (io::Result<(String, u16)>, Vec<u8>) {
        let opening = greeting(&[0x00, 0x02], Some((b"wesh-user", b"wesh-pass")));
        let (result, reply) = raw_exchange(&opening, request).await;
        assert_eq!(reply[..4], [0x05, 0x02, 0x01, 0x00]);
        (result, reply[4..].to_vec())
    }

    #[tokio::test]
    async fn a_client_offering_no_username_and_password_is_refused() {
        let (result, reply) = raw_exchange(&greeting(&[0x00], None), &[]).await;
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(reply, [0x05, 0xFF]);
    }

    #[tokio::test]
    async fn a_wrong_login_is_refused_before_any_request_is_read() {
        let logins: [(&[u8], &[u8]); 3] =
            [(b"wesh-user", b"wrong-pass"), (b"other-user", b"wesh-pass"), (b"wesh-use", b"wesh-pass")];
        for (user, pass) in logins {
            let request = connect(0x03, &domain(b"relay.damus.io"), 443);
            let (result, reply) = raw_exchange(&greeting(&[0x02], Some((user, pass))), &request).await;
            let error = result.unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
            assert!(!error.to_string().contains("wesh"), "{}", error);
            assert_eq!(reply, [0x05, 0x02, 0x01, 0x01]);
        }
    }

    #[tokio::test]
    async fn a_login_with_another_subnegotiation_version_is_refused() {
        let mut opening = greeting(&[0x02], Some((b"wesh-user", b"wesh-pass")));
        opening[3] = 0x05;
        let (result, reply) = raw_exchange(&opening, &[]).await;
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(reply, [0x05, 0x02, 0x01, 0x01]);
    }

    #[test]
    fn credentials_hold_1_to_255_bytes_each_and_never_print() {
        assert!(Credentials::new(b"", b"pass").is_none());
        assert!(Credentials::new(b"user", b"").is_none());
        assert!(Credentials::new(&[b'a'; 256], b"pass").is_none());
        let credentials = Credentials::new(&[b'a'; 255], b"secret-pass").unwrap();
        assert!(!format!("{:?}", credentials).contains("secret"));
    }

    fn connect(atyp: u8, address: &[u8], port: u16) -> Vec<u8> {
        let mut request = vec![0x05, 0x01, 0x00, atyp];
        request.extend_from_slice(address);
        request.extend_from_slice(&port.to_be_bytes());
        request
    }

    fn domain(name: &[u8]) -> Vec<u8> {
        let mut address = vec![name.len() as u8];
        address.extend_from_slice(name);
        address
    }

    fn assert_refused(result: &io::Result<(String, u16)>, reply: &[u8], code: u8) {
        assert!(result.is_err(), "expected a refusal, got {:?}", result);
        assert_eq!(reply, [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    }

    #[tokio::test]
    async fn a_domain_name_target_is_returned() {
        let (result, reply) = exchange(&connect(0x03, &domain(b"relay.damus.io"), 443)).await;
        assert_eq!(result.unwrap(), ("relay.damus.io".to_owned(), 443));
        assert!(reply.is_empty());
    }

    #[tokio::test]
    async fn an_ipv4_target_is_refused_as_an_unsupported_address_type() {
        let (result, reply) = exchange(&connect(0x01, &[198, 51, 100, 7], 443)).await;
        assert_refused(&result, &reply, SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
    }

    #[tokio::test]
    async fn an_ipv6_target_is_refused_as_an_unsupported_address_type() {
        let address = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
        let (result, reply) = exchange(&connect(0x04, &address, 443)).await;
        assert_refused(&result, &reply, SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
    }

    #[tokio::test]
    async fn an_ip_literal_sent_as_a_domain_name_is_refused() {
        for literal in [&b"198.51.100.7"[..], b"2001:db8::1", b"[2001:db8::1]"] {
            let (result, reply) = exchange(&connect(0x03, &domain(literal), 443)).await;
            assert_refused(&result, &reply, SOCKS5_REP_ADDRESS_NOT_SUPPORTED);
        }
    }

    #[test]
    fn ip_forms_other_resolvers_accept_are_refused_as_addresses() {
        for name in [
            "127.1",
            "0x7f.0.0.1",
            "2130706433",
            "0177.0.0.1",
            "127.0.0.1.",
            "0x7f",
            "relay.example.0x1f",
            "::1",
            "::ffff:127.0.0.1",
            "relay.example.org:443",
            "[relay.example.org]",
        ] {
            assert_eq!(host_name(name.as_bytes()), Err(SOCKS5_REP_ADDRESS_NOT_SUPPORTED), "{}", name);
        }
    }

    #[test]
    fn names_outside_the_dns_grammar_are_refused() {
        let long_label = format!("{}.example", "a".repeat(64));
        let long_name = format!("{}.io", vec!["a".repeat(62); 4].join("."));
        assert_eq!(long_name.len(), 254);
        for name in [
            "",
            ".",
            "-bad.example",
            "bad-.example",
            "a..b",
            ".relay.example.org",
            "relay.example.org..",
            "relay_1.example.org",
            "relay example.org",
            "caf\u{e9}.example",
            long_label.as_str(),
            long_name.as_str(),
        ] {
            assert_eq!(host_name(name.as_bytes()), Err(SOCKS5_REP_FAILURE), "{}", name);
        }
    }

    #[test]
    fn dns_names_are_accepted_lowercased_without_a_final_dot() {
        assert_eq!(host_name(b"relay.damus.io"), Ok("relay.damus.io".to_owned()));
        assert_eq!(host_name(b"Relay.Damus.IO."), Ok("relay.damus.io".to_owned()));
        assert_eq!(host_name(b"xn--caf-dma.example"), Ok("xn--caf-dma.example".to_owned()));
        assert_eq!(host_name(b"1.relay-2.example"), Ok("1.relay-2.example".to_owned()));
        let longest = format!("{}.io", vec!["a".repeat(62); 4].join(".")[1..].to_owned());
        assert_eq!(longest.len(), 253);
        assert_eq!(host_name(longest.as_bytes()), Ok(longest.clone()));
    }

    #[tokio::test]
    async fn empty_invalid_or_nul_host_names_are_refused() {
        for name in [&b""[..], b"exa\0mple.org", &[0xff, 0xfe]] {
            let (result, reply) = exchange(&connect(0x03, &domain(name), 443)).await;
            assert_refused(&result, &reply, SOCKS5_REP_FAILURE);
        }
    }

    #[tokio::test]
    async fn a_refusal_does_not_name_the_destination() {
        let (result, _) = exchange(&connect(0x03, &domain(b"198.51.100.7"), 443)).await;
        let message = result.unwrap_err().to_string();
        assert!(!message.contains("198.51.100.7"), "{}", message);
        assert!(!message.contains("443"), "{}", message);
    }

    #[tokio::test]
    async fn a_client_that_stalls_is_given_up() {
        let (_client, mut server): (DuplexStream, DuplexStream) = duplex(1024);
        let result = timed_handshake(&mut server, &credentials(), Duration::from_millis(50)).await;
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
    }

    async fn greeted_timed_handshake() -> (
        DuplexStream,
        tokio::task::JoinHandle<io::Result<(String, u16)>>,
    ) {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            timed_handshake(&mut server, &credentials(), HANDSHAKE_TIMEOUT).await
        });
        client.write_all(&greeting(&[0x02], Some((b"wesh-user", b"wesh-pass")))).await.unwrap();
        let mut replies = [0u8; 4];
        client.read_exact(&mut replies).await.unwrap();
        assert_eq!(replies, [0x05, 0x02, 0x01, 0x00]);
        (client, task)
    }

    #[tokio::test(start_paused = true)]
    async fn a_client_that_stalls_after_greeting_times_out() {
        let (_client, task) = greeted_timed_handshake().await;

        tokio::time::advance(HANDSHAKE_TIMEOUT - Duration::from_millis(1)).await;
        assert!(!task.is_finished());
        tokio::time::advance(Duration::from_millis(1)).await;

        assert_eq!(task.await.unwrap().unwrap_err().kind(), io::ErrorKind::TimedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn a_partial_connect_request_keeps_the_original_handshake_deadline() {
        let started = tokio::time::Instant::now();
        let (mut client, task) = greeted_timed_handshake().await;
        tokio::time::advance(Duration::from_secs(2)).await;

        // A valid header and domain prefix arrive late; the remaining name and port never do.
        client.write_all(&[0x05, 0x01, 0x00, 0x03, 17]).await.unwrap();
        client.write_all(b"relay.").await.unwrap();
        tokio::task::yield_now().await;
        assert!(!task.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;

        assert_eq!(task.await.unwrap().unwrap_err().kind(), io::ErrorKind::TimedOut);
        assert_eq!(started.elapsed(), HANDSHAKE_TIMEOUT);
    }

    #[tokio::test(start_paused = true)]
    async fn a_complete_connect_request_before_the_deadline_is_accepted() {
        let (mut client, task) = greeted_timed_handshake().await;
        tokio::time::advance(Duration::from_secs(2)).await;
        client.write_all(&connect(0x03, &domain(b"relay.example.org"), 443)).await.unwrap();

        assert_eq!(task.await.unwrap().unwrap(), ("relay.example.org".to_owned(), 443));
    }
}
