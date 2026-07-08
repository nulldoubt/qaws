#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

VERSION="${QAWS_VERSION:-0.2.4}"
PLATFORMS="${QAWS_PLATFORMS:-linux/amd64,linux/arm64}"

docker buildx build \
  --platform "$PLATFORMS" \
  --provenance=false \
  --sbom=false \
  --tag "code.alkhatib.online/alkhatib/qaws:${VERSION}" \
  --tag "code.alkhatib.online/alkhatib/qaws:latest" \
  --tag "ghcr.io/nulldoubt/qaws:${VERSION}" \
  --tag "ghcr.io/nulldoubt/qaws:latest" \
  --push \
  .
