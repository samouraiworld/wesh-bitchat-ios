//! Stream isolation per destination host
//!
//! Each relay host gets its own isolation token for the life of a session, so streams to two
//! relays never share a circuit and no exit sees one client reach several relays. Generic over
//! the token, so the rule can be tested without Arti.

use std::collections::HashMap;
use std::sync::Mutex;

pub struct PerHost<T> {
    tokens: Mutex<HashMap<String, T>>,
}

impl<T: Copy> PerHost<T> {
    pub fn new() -> Self {
        Self { tokens: Mutex::new(HashMap::new()) }
    }

    /// The token for `host` (already lowercased by the SOCKS handshake), made on first use.
    pub fn token(&self, host: &str, make: impl FnOnce() -> T) -> T {
        let mut tokens = self.tokens.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *tokens.entry(host.to_owned()).or_insert_with(make)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_keeps_its_token_and_other_hosts_get_their_own() {
        let mut next = 0u64;
        let mut make = || {
            next += 1;
            next
        };
        let hosts = PerHost::new();
        let damus = hosts.token("relay.damus.io", &mut make);
        let primal = hosts.token("relay.primal.net", &mut make);
        assert_ne!(damus, primal);
        assert_eq!(hosts.token("relay.damus.io", &mut make), damus);
        assert_eq!(hosts.token("relay.primal.net", &mut make), primal);
        assert_eq!(next, 2);
    }
}
