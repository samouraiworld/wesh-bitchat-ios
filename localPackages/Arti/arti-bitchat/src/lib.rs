//! arti-bitchat: Minimal FFI wrapper around arti-client for BitChat
//!
//! Provides a C-compatible interface for embedding Arti (Rust Tor) in iOS/macOS apps.
//! Exposes a SOCKS5 proxy on localhost that Swift code can route traffic through.

use std::ffi::{c_char, c_int, CStr};
use std::io;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use arti_client::TorClient;
use once_cell::sync::OnceCell;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, OwnedSemaphorePermit, Semaphore};
use tor_rtcompat::PreferredRuntime;

mod connections;
mod controller;
mod lifecycle;
mod socks;

static ARTI_STATE: OnceCell<Arc<controller::Controller<TorClient<PreferredRuntime>>>> = OnceCell::new();

/// Initialize lifecycle control. Each start owns a fresh runtime.
fn init_state() -> Result<(), &'static str> {
    ARTI_STATE.get_or_try_init(|| -> Result<Arc<controller::Controller<TorClient<PreferredRuntime>>>, &'static str> {
        Ok(Arc::new(controller::Controller::new(
            std::time::Duration::from_secs(2),
            tokio::runtime::Runtime::new,
        )))
    })?;
    Ok(())
}

/// Start Arti with a SOCKS5 proxy.
///
/// # Arguments
/// * `data_dir` - Path to data directory for Tor state (C string)
/// * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
///
/// # Returns
/// * 0 on success
/// * -1 if a session is active, stopping, or native quiescence is already unconfirmed
/// * -2 if data_dir is invalid
/// * -3 if runtime initialization failed
/// * -4 if bootstrap failed
/// * -5 if native teardown became unconfirmed while admitting this start; restart the process before starting again
#[no_mangle]
pub extern "C" fn arti_start(data_dir: *const c_char, socks_port: u16) -> c_int {
    if ARTI_STATE.get().is_some_and(|state| state.is_running()) {
        return -1;
    }

    // Parse data directory
    let data_path = match unsafe { CStr::from_ptr(data_dir) }.to_str() {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -2,
    };

    // Initialize runtime if needed
    if let Err(_) = init_state() {
        return -3;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -3,
    };

    let socks_addr: SocketAddr = format!("127.0.0.1:{}", socks_port)
        .parse()
        .expect("valid addr");

    state.start(move |session, shutdown_rx| async move {
        match run_arti(data_path, socks_addr, shutdown_rx, session.clone()).await {
            Ok(_) => tracing::info!("Arti shutdown cleanly"),
            Err(e) => {
                tracing::error!("Arti error: {}", e);
                session.set_summary(&format!("Error: {}", e));
            }
        }
    })
}

/// Stop Arti gracefully.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
/// * -5 if native quiescence could not be confirmed; the failure remains latched until process restart
#[no_mangle]
pub extern "C" fn arti_stop() -> c_int {
    ARTI_STATE.get().map_or(-1, |state| state.stop())
}

/// Check if Arti is currently running.
///
/// # Returns
/// * 1 if active or native quiescence is unconfirmed (including a latched teardown failure)
/// * 0 only when native work is confirmed stopped
#[no_mangle]
pub extern "C" fn arti_is_running() -> c_int {
    i32::from(ARTI_STATE.get().is_some_and(|state| state.is_running()))
}

/// Get the current bootstrap progress (0-100).
#[no_mangle]
pub extern "C" fn arti_bootstrap_progress() -> c_int {
    ARTI_STATE.get().map_or(0, |state| state.progress())
}

/// Get the current bootstrap summary string.
///
/// # Arguments
/// * `buf` - Buffer to write the summary into
/// * `len` - Length of the buffer
///
/// # Returns
/// * Number of bytes written (not including null terminator)
/// * -1 if buffer is null or too small
#[no_mangle]
pub extern "C" fn arti_bootstrap_summary(buf: *mut c_char, len: c_int) -> c_int {
    if buf.is_null() || len <= 0 {
        return -1;
    }

    let summary = match ARTI_STATE.get().map(|state| state.summary()) {
        Some(Ok(summary)) => summary,
        Some(Err(())) => return -1,
        None => String::new(),
    };

    let bytes = summary.as_bytes();
    let copy_len = std::cmp::min(bytes.len(), (len - 1) as usize);

    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
        *buf.add(copy_len) = 0; // null terminator
    }

    copy_len as c_int
}

/// Signal Arti to go dormant (reduce resource usage).
/// This is a hint; Arti may not fully support dormant mode yet.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_go_dormant() -> c_int {
    if arti_is_running() == 0 {
        return -1;
    }
    // Arti doesn't have explicit dormant mode yet, but we can note the intent
    update_summary("Dormant");
    0
}

/// Signal Arti to wake from dormant mode.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_wake() -> c_int {
    if arti_is_running() == 0 {
        return -1;
    }
    update_summary("Active");
    0
}

fn update_summary(s: &str) {
    if let Some(state) = ARTI_STATE.get() {
        state.set_summary(s);
    }
}

/// Handle a single SOCKS5 connection. `handshake` is held until the request is read; a place
/// in `slots` is taken only after that. Errors never name the destination.
async fn handle_socks_connection(
    mut stream: TcpStream,
    client: Arc<TorClient<PreferredRuntime>>,
    handshake: OwnedSemaphorePermit,
    slots: Arc<Semaphore>,
) -> io::Result<()> {
    let (dest_host, dest_port) = socks::timed_handshake(&mut stream, socks::HANDSHAKE_TIMEOUT).await?;
    drop(handshake);

    let Ok(_slot) = slots.try_acquire_owned() else {
        socks::send_reply(&mut stream, socks::SOCKS5_REP_FAILURE).await?;
        return Err(io::Error::new(io::ErrorKind::Other, "SOCKS connection limit reached"));
    };

    // The Arti error may name the destination, so it is neither logged nor returned.
    let tor_stream = match client.connect((dest_host.as_str(), dest_port)).await {
        Ok(s) => s,
        Err(_) => {
            socks::send_reply(&mut stream, socks::SOCKS5_REP_CONN_REFUSED).await?;
            return Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "Tor connect failed",
            ));
        }
    };

    socks::send_reply(&mut stream, socks::SOCKS5_REP_SUCCESS).await?;

    // Bidirectional copy
    let (mut client_read, mut client_write) = stream.into_split();
    let (mut tor_read, mut tor_write) = tor_stream.split();

    let client_to_tor = async {
        tokio::io::copy(&mut client_read, &mut tor_write).await
    };
    let tor_to_client = async {
        tokio::io::copy(&mut tor_read, &mut client_write).await
    };

    tokio::select! {
        result = client_to_tor => {
            if let Err(e) = result {
                tracing::debug!("Client to Tor copy error: {:?}", e.kind());
            }
        }
        result = tor_to_client => {
            if let Err(e) = result {
                tracing::debug!("Tor to client copy error: {:?}", e.kind());
            }
        }
    }

    Ok(())
}

/// Main async entry point for Arti
async fn run_arti(
    data_dir: PathBuf,
    socks_addr: SocketAddr,
    shutdown_rx: oneshot::Receiver<()>,
    session: controller::SessionContext<TorClient<PreferredRuntime>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Ensure data directory exists
    std::fs::create_dir_all(&data_dir)?;

    session.set_summary("Configuring...");

    // Build Arti configuration with custom directories
    let cache_dir = data_dir.join("cache");
    let state_dir = data_dir.join("state");

    // Use from_directories which sets up storage correctly
    use arti_client::config::TorClientConfigBuilder;
    let config = TorClientConfigBuilder::from_directories(state_dir, cache_dir)
        .build()?;

    session.set_summary("Bootstrapping...");

    lifecycle::bootstrap_then_serve(
        async {
            Ok::<_, Box<dyn std::error::Error + Send + Sync>>(
                TorClient::create_bootstrapped(config).await?,
            )
        },
        shutdown_rx,
        move |client, mut shutdown_rx| async move {
            let client = Arc::new(client);

            // Binding and stop admission share the lifecycle lock. Using a
            // nonblocking std listener makes the bind itself synchronous in
            // this gate; no bind future can resume after stop closes it.
            let listener = match session.admit(|| -> io::Result<TcpListener> {
                let listener = std::net::TcpListener::bind(socks_addr)?;
                listener.set_nonblocking(true)?;
                TcpListener::from_std(listener)
            }) {
                Some(result) => result?,
                None => return Ok(()),
            };
            if !session.publish(client.clone()) {
                return Ok(());
            }

            // Mark bootstrap complete
            session.set_progress(100);
            session.set_summary("Ready");

            tracing::info!("SOCKS5 proxy listening on {}", socks_addr);

            // Accept connections until shutdown. Logs name a connection by a counter only, never
            // its destination.
            let handshakes = Arc::new(Semaphore::new(socks::MAX_HANDSHAKES));
            let slots = Arc::new(Semaphore::new(socks::MAX_CONNECTIONS));
            let mut connections = connections::ConnectionTasks::default();
            let mut next_id: u64 = 0;
            loop {
                tokio::select! {
                    biased;
                    _ = &mut shutdown_rx => {
                        tracing::info!("Shutdown signal received");
                        break;
                    }
                    accept_result = std::future::poll_fn(|cx| {
                        match session.admit(|| listener.poll_accept(cx)) {
                            Some(result) => result.map(Some),
                            None => std::task::Poll::Ready(None),
                        }
                    }) => {
                        let Some(accept_result) = accept_result else { break };
                        match accept_result {
                            Ok((stream, _peer_addr)) => {
                                next_id += 1;
                                let id = next_id;
                                let Ok(handshake) = handshakes.clone().try_acquire_owned() else {
                                    drop(stream);
                                    tracing::debug!("SOCKS connection {} refused, too many handshakes", id);
                                    continue;
                                };
                                if session.admit(|| {
                                    let client = client.clone();
                                    let slots = slots.clone();
                                    connections.spawn(async move {
                                        if let Err(e) = handle_socks_connection(stream, client, handshake, slots).await {
                                            tracing::debug!("SOCKS connection {}: {}", id, e);
                                        }
                                    });
                                }).is_none() {
                                    break;
                                }
                            }
                            Err(e) => {
                                tracing::warn!("Accept error: {}", e);
                            }
                        }
                    }
                }
            }

            connections.shutdown().await;
            session.set_summary("Shutting down...");
            Ok(())
        },
    )
    .await
}
