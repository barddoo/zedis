# syntax=docker/dockerfile:1

##############################################################################
# Stage: install Zig and build a static musl binary (works in all variants)
##############################################################################
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS builder

ARG ZIG_VERSION=0.17.1
# ZSF minisign public key. Confirm it matches https://ziglang.org/download before relying on it.
ARG ZIG_MINISIGN_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

RUN --mount=type=cache,target=/etc/apk/cache,sharing=locked \
  apk add build-base curl xz minisign

COPY install-zig.sh /usr/local/bin/install-zig.sh
RUN install-zig.sh "${ZIG_VERSION}" "${ZIG_MINISIGN_PUBKEY}"

WORKDIR /build
COPY build.zig build.zig.zon ./
COPY src src/
COPY vendor vendor/

RUN --mount=type=cache,target=/root/.cache/zig \
  zig build -Drelease -Dtarget="$(uname -m)-linux-musl"

##############################################################################
# Stage: assemble the distroless filesystem tree so it ships as a single COPY
##############################################################################
FROM busybox:musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6 AS rootfs

COPY --from=builder /build/zig-out/bin/zedis /rootfs/usr/local/bin/zedis
COPY docker/zedis-distroless.conf /rootfs/etc/zedis/zedis.conf

RUN mkdir -p /rootfs/home/nonroot/data && \
  chown -R 65532:65532 /rootfs/home/nonroot && \
  touch /rootfs/home/nonroot/data/.keep

##############################################################################
# alpine — smallest variant with shell access
##############################################################################
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS alpine

LABEL org.opencontainers.image.source="https://github.com/barddoo/zedis"

RUN --mount=type=cache,target=/etc/apk/cache,sharing=locked \
  apk add ca-certificates tzdata && \
  adduser -D -s /sbin/nologin zedis

COPY --link --from=builder /build/zig-out/bin/zedis /usr/local/bin/zedis
COPY docker/zedis.conf /etc/zedis/zedis.conf

RUN mkdir -p /var/lib/zedis/data && \
  chown -R zedis:zedis /var/lib/zedis /etc/zedis

USER zedis
WORKDIR /var/lib/zedis
EXPOSE 6379
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD sh -c 'printf "PING\r\n" | nc 127.0.0.1 6379 -w1 | grep -q PONG'
ENTRYPOINT ["zedis", "/etc/zedis/zedis.conf"]

##############################################################################
# debian — default variant, glibc base, wider ecosystem compatibility
##############################################################################
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS debian

LABEL org.opencontainers.image.source="https://github.com/barddoo/zedis"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  tzdata \
  netcat-openbsd \
  && useradd -r -s /usr/sbin/nologin zedis

COPY --link --from=builder /build/zig-out/bin/zedis /usr/local/bin/zedis
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
FROM gcr.io/distroless/static-debian13@sha256:1a64f46364620465ef9e9a8f5413757dfdf22695e050bbfd7303eeaf17a59383 AS distroless

LABEL org.opencontainers.image.source="https://github.com/barddoo/zedis"

COPY --link --from=rootfs /rootfs/ /

USER nonroot
WORKDIR /home/nonroot
EXPOSE 6379
ENTRYPOINT ["zedis", "/etc/zedis/zedis.conf"]
