#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
rm -rf dist
zig build release --prefix .

echo "Built release artifacts:"
find dist -maxdepth 1 -type f -print | sort
