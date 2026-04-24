# syntax=docker/dockerfile:1

##############################################################################
# Stage: install Zig and build a static musl binary (works in all variants)
##############################################################################
FROM alpine:3.20 AS builder

ARG ZIG_VERSION=0.16.0

RUN apk add --no-cache curl xz

RUN case "$(uname -m)" in \
        x86_64)  ZIG_ARCH=x86_64  ;; \
        aarch64) ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" | \
        tar -xJ -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION} /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build
COPY build.zig build.zig.zon ./
COPY src src/

RUN zig build -Doptimize=ReleaseSafe -Dtarget="$(uname -m)-linux-musl"

##############################################################################
# Stage: create data dir with correct ownership for distroless
##############################################################################
FROM busybox:musl AS dirs

RUN mkdir -p /home/nonroot/data && \
    chown -R 65532:65532 /home/nonroot && \
    touch /home/nonroot/data/.keep

##############################################################################
# alpine — default variant, smallest with shell access
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
# debian — glibc base, wider ecosystem compatibility
##############################################################################
FROM debian:bookworm-slim AS debian

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
