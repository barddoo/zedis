# syntax=docker/dockerfile:1

##############################################################################
# Stage: install Zig and build a static musl binary (works in all variants)
##############################################################################
FROM alpine:3.20 AS builder

ARG ZIG_VERSION=0.17.1
# ZSF minisign public key. Confirm it matches https://ziglang.org/download before relying on it.
ARG ZIG_MINISIGN_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

RUN apk add --no-cache curl xz openssl-dev openssl-libs-static minisign

COPY install-zig.sh /usr/local/bin/install-zig.sh
RUN install-zig.sh "${ZIG_VERSION}" "${ZIG_MINISIGN_PUBKEY}"

WORKDIR /build
COPY build.zig build.zig.zon ./
COPY src src/

RUN zig build -Drelease -Dopenssl-static=true -Dopenssl-prefix=/usr -Dtarget="$(uname -m)-linux-musl"

##############################################################################
# Stage: create data dir with correct ownership for distroless
##############################################################################
FROM busybox:musl AS dirs

RUN mkdir -p /home/nonroot/data && \
    chown -R 65532:65532 /home/nonroot && \
    touch /home/nonroot/data/.keep

##############################################################################
# alpine — smallest variant with shell access
##############################################################################
FROM alpine:3.20 AS alpine

RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -s /sbin/nologin zedis

COPY --from=builder /build/zig-out/bin/zedis /usr/local/bin/zedis
COPY docker/zedis.conf /etc/zedis/zedis.conf

RUN mkdir -p /var/lib/zedis/data && \
    chown -R zedis:zedis /var/lib/zedis /etc/zedis

USER zedis
WORKDIR /var/lib/zedis
EXPOSE 6379
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD sh -c 'printf "PING\r\n" | nc localhost 6379 -w1 | grep -q PONG'
ENTRYPOINT ["zedis", "/etc/zedis/zedis.conf"]

##############################################################################
# debian — default variant, glibc base, wider ecosystem compatibility
##############################################################################
FROM debian:trixie-slim AS debian

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -s /usr/sbin/nologin zedis

COPY --from=builder /build/zig-out/bin/zedis /usr/local/bin/zedis
COPY docker/zedis.conf /etc/zedis/zedis.conf

RUN mkdir -p /var/lib/zedis/data && \
    chown -R zedis:zedis /var/lib/zedis /etc/zedis

USER zedis
WORKDIR /var/lib/zedis
EXPOSE 6379
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD nc -z localhost 6379
ENTRYPOINT ["zedis", "/etc/zedis/zedis.conf"]

##############################################################################
# distroless — no shell, smallest attack surface
##############################################################################
FROM gcr.io/distroless/static-debian12 AS distroless

COPY --from=builder /build/zig-out/bin/zedis /usr/local/bin/zedis
COPY docker/zedis-distroless.conf /etc/zedis/zedis.conf
COPY --from=dirs /home/nonroot/data /home/nonroot/data

USER nonroot
WORKDIR /home/nonroot
EXPOSE 6379
ENTRYPOINT ["zedis", "/etc/zedis/zedis.conf"]
