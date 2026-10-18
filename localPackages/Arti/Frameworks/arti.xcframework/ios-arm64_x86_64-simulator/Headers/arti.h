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
 * * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
 *
 * # Returns
 * * 0 on success
 * * -1 if already running
 * * -2 if data_dir is invalid
 * * -3 if runtime initialization failed
 * * -4 if bootstrap failed
 */
int arti_start(const char *data_dir, uint16_t socks_port);

/**
 * Stop Arti gracefully.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * # Returns
 * * 1 if running
 * * 0 if not running
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
