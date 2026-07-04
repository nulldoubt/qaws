#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
rm -rf dist
zig build release --prefix .

(
  cd dist
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum qaws-* > SHA256SUMS
  else
    shasum -a 256 qaws-* > SHA256SUMS
  fi
)

echo "Built release artifacts:"
find dist -maxdepth 1 -type f -print | sort
