// Single translation unit for the Mbed TLS headers used by src/app/tls.zig.
// Zig 0.17 has no @cImport, so build.zig runs translate-c over this header.
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/net_sockets.h>
#include <psa/crypto.h>
