#ifndef ARTI_H
#define ARTI_H

#include <stdint.h>
#include <stdbool.h>

#define SOCKS5_REP_SUCCESS 0

#define SOCKS5_REP_FAILURE 1

#define SOCKS5_REP_CONN_REFUSED 5

/**
 * Concurrent connections past their handshake. More are refused, so no local app can
 * exhaust our file descriptors.
 */
#define MAX_CONNECTIONS 64

/**
 * Concurrent connections still in their handshake. Kept apart and small, so sockets that
 * never send a request cannot take the places of working ones.
 */
#define MAX_HANDSHAKES 16

/**
 * Start Arti with a SOCKS5 proxy.
 *
 * # Arguments
 * * `data_dir` - Path to data directory for Tor state (C string)
 * * `socks_port` - Port for SOCKS5 proxy on 127.0.0.1, chosen anew by the caller for each start
 * * `socks_username`, `socks_password` - RFC 1929 login the proxy requires for this start
 *   (C strings, 1 to 255 bytes each); clients without it are refused
 *
 * # Returns
 * * 0 on success
 * * -1 if a session is active, stopping, or native quiescence is already unconfirmed
 * * -2 if data_dir is invalid
 * * -3 if runtime initialization failed
 * * -4 if bootstrap failed
 * * -5 if native teardown became unconfirmed while admitting this start; restart the process before starting again
 * * -6 if the SOCKS username or password is invalid
 */
int arti_start(const char *data_dir,
               uint16_t socks_port,
               const char *socks_username,
               const char *socks_password);

/**
 * Stop Arti gracefully.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 * * -5 if native quiescence could not be confirmed; the failure remains latched until process restart
 */
int arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * # Returns
 * * 1 if active or native quiescence is unconfirmed (including a latched teardown failure)
 * * 0 only when native work is confirmed stopped
 */
int arti_is_running(void);

/**
 * Get the current bootstrap progress (0-100).
 */
int arti_bootstrap_progress(void);

/**
 * Get the current bootstrap summary string.
 *
 * # Arguments
 * * `buf` - Buffer to write the summary into
 * * `len` - Length of the buffer
 *
 * # Returns
 * * Number of bytes written (not including null terminator)
 * * -1 if buffer is null or too small
 */
int arti_bootstrap_summary(char *buf, int len);

/**
 * Signal Arti to go dormant (reduce resource usage).
 * This is a hint; Arti may not fully support dormant mode yet.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_go_dormant(void);

/**
 * Signal Arti to wake from dormant mode.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_wake(void);

#endif  /* ARTI_H */
