docker-shadowsocks
==================

This Dockerfile builds a small Alpine-based image running
[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust), the
maintained Shadowsocks implementation. Multi-arch: `linux/amd64`, `linux/arm64`,
`linux/arm/v7`, `linux/arm/v6`, `linux/386`.

Quick Start
-----------

This image uses ENTRYPOINT to run the container as an executable.

    docker run -d \
      -p 8388:8388/tcp -p 8388:8388/udp \
      ss -s 0.0.0.0:8388 -k "$SSPASSWORD" -m aes-256-gcm

You can configure the service to run on a port of your choice. Just make sure
the port number given to Docker is the same as the one given to shadowsocks.
Also, it is highly recommended that you store the shadowsocks password in an
environment variable as shown above. This way the password will not show in
plain text when you run `docker ps`.

Publish UDP as well as TCP if you need UDP relay.

Building
--------

    docker build -t ss .

Multi-arch, e.g. to target a Raspberry Pi from an x86 host:

    docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t ss .

Pin a different upstream release with `--build-arg SS_VERSION=1.25.0`. The
build verifies the release SHA-256 before unpacking.

If you would rather not build at all, upstream publishes official images at
`ghcr.io/shadowsocks/ssserver-rust`.

### BuildKit is required

`$BUILDPLATFORM` is only defined under BuildKit. The legacy builder fails with
an opaque `"" is an invalid OS component` error, and Azure ACR Tasks
(`az acr build`) fails its dependency scan with `unable to understand line
FROM --platform=$BUILDPLATFORM`. Build locally with buildx and push the result.

On macOS, Homebrew installs buildx to `$(brew --prefix)/bin/docker-buildx` but
does not link it where the Docker CLI looks:

    mkdir -p ~/.docker/cli-plugins
    ln -sfn "$(brew --prefix)/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx

### Pushing to Azure Container Instances

BuildKit attaches provenance and SBOM attestations by default, which makes even
a single-platform build push an OCI image index containing an extra
`unknown/unknown` manifest. ACI cannot resolve that and reports
`InaccessibleImage`. Disable them so the tag points at a plain image manifest:

    docker build --platform linux/amd64 --provenance=false --sbom=false \
      -t <registry>.azurecr.io/ss:1.25.0 .

Ciphers
-------

Prefer `2022-blake3-aes-256-gcm` where both ends support it — it adds replay
protection and does not respond to malformed probes, which matters if the server
is somewhere subject to active probing. It takes two pre-shared keys:

    SERVER_PSK=$(openssl rand -base64 32)
    CLIENT_PSK=$(openssl rand -base64 32)

Otherwise use an AEAD cipher: `aes-256-gcm`, `aes-128-gcm`, or
`chacha20-ietf-poly1305`.

Stream ciphers such as `aes-256-cfb` are unauthenticated and are deprecated
upstream as UNSAFE. They still run in the current release binaries, but the
server logs a warning on startup and upstream states they will be removed in a
future release. Do not use them.

Upgrading from the old image
----------------------------

This image previously ran the Python `shadowsocks` package on Ubuntu 16.04.
That package's last release was 2.8.2 in **2015** and it is Python 2 era, so
there is no newer version of it to move to — hence the switch to
shadowsocks-rust. Three things changed in the invocation:

| Before | Now |
|---|---|
| `-s 0.0.0.0 -p 1984` | `-s 0.0.0.0:8388` — host and port are one argument |
| `-m aes-256-cfb` | `-m aes-256-gcm` or `-m 2022-blake3-aes-256-gcm` — see below |
| default port 1984 | default exposed port 8388 |

The container also now runs as a non-root user.

Note that `-m aes-256-cfb` does **not** fail after upgrading — the server still
starts and only logs a deprecation warning. Change the cipher deliberately;
nothing will force you to.

For more command line options, refer to the
[shadowsocks-rust documentation](https://github.com/shadowsocks/shadowsocks-rust).

Guides
------

- [Raspberry Pi China Exit Node](docs/china-exit-node.md) — end-to-end setup for a
  self-hosted mainland-China exit node (Pi + frp reverse tunnel + Shadowsocks-2022
  + self-hosted DNS), for reaching CN-geolocked streaming from abroad.
