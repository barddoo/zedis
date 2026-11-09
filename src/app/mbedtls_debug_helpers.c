// Mbed TLS normally generates library/ssl_debug_helpers_generated.c at build
// time, but the barddoo/mbedtls package does not ship or generate it. Three of
// its helpers are referenced from other SSL objects, so provide them here.
// They only format debug output; returning "unknown" does not affect protocol
// behavior. The other helpers are defined by ssl_client.o / ssl_msg.o /
// ssl_tls.o, so defining them here as well would be a duplicate symbol.
#include <mbedtls/ssl.h>
#include <stdint.h>

const char *mbedtls_ssl_states_str(mbedtls_ssl_states in)
{
    (void) in;
    return "unknown";
}

const char *mbedtls_ssl_sig_alg_to_str(uint16_t in)
{
    (void) in;
    return "unknown";
}

const char *mbedtls_ssl_named_group_to_str(uint16_t in)
{
    (void) in;
    return "unknown";
}
