# syntax=docker/dockerfile:1

ARG ZIG_VERSION=0.16.0

FROM --platform=$BUILDPLATFORM alpine:3.22 AS builder

ARG TARGETARCH
ARG BUILDARCH
ARG ZIG_VERSION

RUN apk add --no-cache ca-certificates curl tar xz

RUN set -eu; \
    case "$BUILDARCH" in \
      amd64) zig_arch="x86_64" ;; \
      arm64) zig_arch="aarch64" ;; \
      *) echo "unsupported build arch: $BUILDARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/zig; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ --strip-components=1 -C /opt/zig

ENV PATH="/opt/zig:${PATH}"

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY src ./src
COPY public ./public

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) qaws_target="x86_64-linux-musl" ;; \
      arm64) qaws_target="aarch64-linux-musl" ;; \
      *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="$qaws_target" -Doptimize=ReleaseFast --prefix /out

FROM scratch

WORKDIR /
COPY --from=builder /out/bin/qaws /qaws
COPY public /public

EXPOSE 80
ENTRYPOINT ["/qaws"]
