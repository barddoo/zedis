// Small OpenSSL glue for the zio runtime.
//
// OpenSSL is driven through memory BIOs so the Zig side owns every socket
// read/write. That keeps the coroutine cooperative: no OpenSSL call blocks on
// a file descriptor, and zio can suspend while waiting for the peer.

#include "openssl_glue.h"

#include <openssl/err.h>
#include <openssl/ssl.h>

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

struct zedis_tls_ctx {
    SSL_CTX *ctx;
};

struct zedis_tls_conn {
    SSL *ssl;
    char err[256];
};

static void capture_error(char *buf, size_t len, const char *fallback) {
    unsigned long e = ERR_get_error();
    if (e != 0) {
        ERR_error_string_n(e, buf, len);
    } else {
        snprintf(buf, len, "%s", fallback);
    }
}

int zedis_tls_version_1_2(void) {
    return TLS1_2_VERSION;
}

int zedis_tls_version_1_3(void) {
    return TLS1_3_VERSION;
}

zedis_tls_ctx *zedis_tls_ctx_new(const char *cert_file,
                                 const char *key_file,
                                 const char *ca_file,
                                 int auth_clients,
                                 int min_version,
                                 int max_version,
                                 char *err,
                                 size_t err_len) {
    if (!OPENSSL_init_ssl(0, NULL)) {
        capture_error(err, err_len, "OPENSSL_init_ssl failed");
        return NULL;
    }

    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (ctx == NULL) {
        capture_error(err, err_len, "SSL_CTX_new failed");
        return NULL;
    }

    long options = SSL_OP_NO_COMPRESSION;
#ifdef SSL_OP_IGNORE_UNEXPECTED_EOF
    options |= SSL_OP_IGNORE_UNEXPECTED_EOF;
#endif
    SSL_CTX_set_options(ctx, options);

    if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
        capture_error(err, err_len, "failed to load certificate chain");
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
        capture_error(err, err_len, "failed to load private key");
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        capture_error(err, err_len, "certificate and private key do not match");
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (ca_file != NULL && ca_file[0] != '\0' &&
        SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
        capture_error(err, err_len, "failed to load CA certificates");
        SSL_CTX_free(ctx);
        return NULL;
    }

    int verify_mode = SSL_VERIFY_NONE;
    if (auth_clients == 1) {
        verify_mode = SSL_VERIFY_PEER;
    } else if (auth_clients == 2) {
        verify_mode = SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
    }
    SSL_CTX_set_verify(ctx, verify_mode, NULL);

    if (min_version != 0 && SSL_CTX_set_min_proto_version(ctx, min_version) != 1) {
        capture_error(err, err_len, "failed to set minimum TLS version");
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (max_version != 0 && SSL_CTX_set_max_proto_version(ctx, max_version) != 1) {
        capture_error(err, err_len, "failed to set maximum TLS version");
        SSL_CTX_free(ctx);
        return NULL;
    }

    zedis_tls_ctx *wrapper = calloc(1, sizeof(*wrapper));
    if (wrapper == NULL) {
        SSL_CTX_free(ctx);
        snprintf(err, err_len, "out of memory");
        return NULL;
    }
    wrapper->ctx = ctx;
    return wrapper;
}

void zedis_tls_ctx_free(zedis_tls_ctx *ctx) {
    if (ctx == NULL) {
        return;
    }
    SSL_CTX_free(ctx->ctx);
    free(ctx);
}

zedis_tls_conn *zedis_tls_conn_new(zedis_tls_ctx *ctx, char *err, size_t err_len) {
    zedis_tls_conn *conn = calloc(1, sizeof(*conn));
    if (conn == NULL) {
        snprintf(err, err_len, "out of memory");
        return NULL;
    }

    conn->ssl = SSL_new(ctx->ctx);
    if (conn->ssl == NULL) {
        capture_error(err, err_len, "SSL_new failed");
        free(conn);
        return NULL;
    }

    BIO *rbio = BIO_new(BIO_s_mem());
    BIO *wbio = BIO_new(BIO_s_mem());
    if (rbio == NULL || wbio == NULL) {
        if (rbio != NULL) {
            BIO_free(rbio);
        }
        if (wbio != NULL) {
            BIO_free(wbio);
        }
        capture_error(err, err_len, "BIO_new failed");
        SSL_free(conn->ssl);
        free(conn);
        return NULL;
    }

    // An empty memory BIO should report "retry", not EOF; EOF is decided by
    // the zio socket read so a partial record does not close the connection.
    BIO_set_mem_eof_return(rbio, -1);
    SSL_set_bio(conn->ssl, rbio, wbio);
    SSL_set_accept_state(conn->ssl);
    SSL_set_mode(conn->ssl, SSL_MODE_ENABLE_PARTIAL_WRITE |
                                SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    return conn;
}

void zedis_tls_conn_free(zedis_tls_conn *conn) {
    if (conn == NULL) {
        return;
    }
    SSL_free(conn->ssl);
    free(conn);
}

const char *zedis_tls_conn_error(zedis_tls_conn *conn) {
    return conn->err;
}

int zedis_tls_handshake(zedis_tls_conn *conn) {
    ERR_clear_error();
    int r = SSL_do_handshake(conn->ssl);
    if (r == 1) {
        return 1;
    }

    switch (SSL_get_error(conn->ssl, r)) {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            return 0;
        default:
            capture_error(conn->err, sizeof(conn->err), "TLS handshake failed");
            return -1;
    }
}

int zedis_tls_feed(zedis_tls_conn *conn, const void *data, size_t len) {
    if (len == 0) {
        return 0;
    }
    if (len > INT_MAX) {
        return -1;
    }
    int n = BIO_write(SSL_get_rbio(conn->ssl), data, (int)len);
    return n == (int)len ? 0 : -1;
}

int zedis_tls_pending(zedis_tls_conn *conn) {
    size_t pending = BIO_ctrl_pending(SSL_get_wbio(conn->ssl));
    return pending > (size_t)INT_MAX ? INT_MAX : (int)pending;
}

int zedis_tls_flush(zedis_tls_conn *conn, void *buf, size_t cap) {
    if (cap == 0) {
        return 0;
    }
    if (cap > INT_MAX) {
        cap = INT_MAX;
    }
    int n = BIO_read(SSL_get_wbio(conn->ssl), buf, (int)cap);
    return n > 0 ? n : 0;
}

int zedis_tls_read(zedis_tls_conn *conn, void *buf, size_t len) {
    if (len == 0) {
        return 0;
    }
    if (len > INT_MAX) {
        len = INT_MAX;
    }
    ERR_clear_error();
    int n = SSL_read(conn->ssl, buf, (int)len);
    if (n > 0) {
        return n;
    }

    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:
            return -2;
        case SSL_ERROR_WANT_WRITE:
            return -3;
        case SSL_ERROR_ZERO_RETURN:
            return 0;
        case SSL_ERROR_SYSCALL:
            // A peer that drops the connection without close_notify surfaces
            // here with an empty error queue; treat it as a normal close.
            if (ERR_peek_error() == 0) {
                return 0;
            }
            /* fall through */
        default:
            capture_error(conn->err, sizeof(conn->err), "TLS read failed");
            return -1;
    }
}

int zedis_tls_write(zedis_tls_conn *conn, const void *buf, size_t len) {
    if (len == 0) {
        return 0;
    }
    if (len > INT_MAX) {
        len = INT_MAX;
    }
    ERR_clear_error();
    int n = SSL_write(conn->ssl, buf, (int)len);
    if (n > 0) {
        return n;
    }

    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:
            return -2;
        case SSL_ERROR_WANT_WRITE:
            return -3;
        default:
            capture_error(conn->err, sizeof(conn->err), "TLS write failed");
            return -1;
    }
}

void zedis_tls_shutdown(zedis_tls_conn *conn) {
    ERR_clear_error();
    (void)SSL_shutdown(conn->ssl);
}
