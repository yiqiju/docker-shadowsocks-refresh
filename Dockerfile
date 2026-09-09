# syntax=docker/dockerfile:1
#
# shadowsocks server
#
# Uses shadowsocks-rust, the maintained implementation. The previous Python
# `shadowsocks` package has not been released since 2015 (2.8.2) and is
# Python 2 era; there is no newer version to move to.
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t ss .

ARG ALPINE_VERSION=3.24
ARG SS_VERSION=1.25.0

# ---- fetch and verify the static musl binary ----
# Runs on the build host and cross-downloads, so no emulation is needed.
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS fetch

ARG SS_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache curl tar xz

WORKDIR /out
RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
      amd64)  RUST_TARGET=x86_64-unknown-linux-musl      ;; \
      arm64)  RUST_TARGET=aarch64-unknown-linux-musl     ;; \
      armv7)  RUST_TARGET=armv7-unknown-linux-musleabihf ;; \
      armv6)  RUST_TARGET=arm-unknown-linux-musleabi     ;; \
      386)    RUST_TARGET=i686-unknown-linux-musl        ;; \
      *) echo "unsupported platform: ${TARGETARCH}${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}"; \
    file="shadowsocks-v${SS_VERSION}.${RUST_TARGET}.tar.xz"; \
    curl -fsSL -O "${base}/${file}"; \
    curl -fsSL -O "${base}/${file}.sha256"; \
    sha256sum -c "${file}.sha256"; \
    tar xJf "${file}" ssserver; \
    chmod +x ssserver

# ---- runtime ----
FROM alpine:${ALPINE_VERSION}

ARG SS_VERSION
LABEL org.opencontainers.image.title="docker-shadowsocks" \
      org.opencontainers.image.description="Shadowsocks server (shadowsocks-rust)" \
      org.opencontainers.image.source="https://github.com/yiqiju/docker-shadowsocks-refresh" \
      org.opencontainers.image.version="${SS_VERSION}" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache ca-certificates \
 && adduser -D -H -u 10001 ss

COPY --from=fetch /out/ssserver /usr/local/bin/ssserver

USER ss
EXPOSE 8388/tcp 8388/udp

# Configure the container to run as an executable.
ENTRYPOINT ["ssserver"]
CMD ["--help"]
