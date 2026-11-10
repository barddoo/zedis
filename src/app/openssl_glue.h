#ifndef ZEDIS_OPENSSL_GLUE_H
#define ZEDIS_OPENSSL_GLUE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zedis_tls_ctx zedis_tls_ctx;
typedef struct zedis_tls_conn zedis_tls_conn;

// auth_clients: 0 = none, 1 = optional, 2 = required.
// min/max_version: 0 = OpenSSL default, otherwise TLS1_2_VERSION / TLS1_3_VERSION.
zedis_tls_ctx *zedis_tls_ctx_new(const char *cert_file,
                                 const char *key_file,
                                 const char *ca_file,
                                 int auth_clients,
                                 int min_version,
                                 int max_version,
                                 char *err,
                                 size_t err_len);
void zedis_tls_ctx_free(zedis_tls_ctx *ctx);

zedis_tls_conn *zedis_tls_conn_new(zedis_tls_ctx *ctx, char *err, size_t err_len);
void zedis_tls_conn_free(zedis_tls_conn *conn);
const char *zedis_tls_conn_error(zedis_tls_conn *conn);

int zedis_tls_version_1_2(void);
int zedis_tls_version_1_3(void);

// Returns 1 = complete, 0 = retry (want read/write), -1 = error.
int zedis_tls_handshake(zedis_tls_conn *conn);

// Returns 0 = success, -1 = error.
int zedis_tls_feed(zedis_tls_conn *conn, const void *data, size_t len);

// Returns the number of bytes waiting to be written to the socket.
int zedis_tls_pending(zedis_tls_conn *conn);

// Copies up to cap bytes of pending ciphertext. Returns bytes copied, or -1.
int zedis_tls_flush(zedis_tls_conn *conn, void *buf, size_t cap);

// Returns >0 = plaintext bytes, 0 = clean EOF, -1 = error,
// -2 = want read, -3 = want write.
int zedis_tls_read(zedis_tls_conn *conn, void *buf, size_t len);

// Returns >0 = plaintext bytes accepted, -1 = error,
// -2 = want read, -3 = want write.
int zedis_tls_write(zedis_tls_conn *conn, const void *buf, size_t len);

void zedis_tls_shutdown(zedis_tls_conn *conn);

#ifdef __cplusplus
}
#endif

#endif
