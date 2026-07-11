#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

version=$(sed -n 's/^pub const string = "\([0-9][0-9.]*\)";$/\1/p' src/version.zig)
if [ -z "$version" ]; then
  echo "Could not read qaws version from src/version.zig" >&2
  exit 1
fi

require_text() {
  file=$1
  expected=$2
  if ! grep -Fq "$expected" "$file"; then
    echo "$file does not contain expected version metadata: $expected" >&2
    exit 1
  fi
}

require_text build.zig.zon ".version = \"$version\""
require_text README.md "qaws is currently \`$version\`."
require_text scripts/docker-build-push.sh "VERSION=\"\${QAWS_VERSION:-$version}\""

changelog_version=$(awk '/^### / { print $2; exit }' CHANGELOG.md)
if [ "$changelog_version" != "$version" ]; then
  echo "CHANGELOG.md starts with $changelog_version, expected $version" >&2
  exit 1
fi

echo "qaws version metadata is consistent at $version"
