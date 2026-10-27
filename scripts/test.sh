#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
cache=${SWARSAATHI_SWIFT_CACHE:-/workspace/.cache/swift}
if [ "$(uname -s)" = Darwin ]; then
    exec xcrun swift test --configuration release --jobs 2 "$@"
fi
swift=${SWARSAATHI_SWIFT:-/workspace/.local/swift/usr/bin/swift}
if [ ! -x "$swift" ]; then
    echo 'Run sh scripts/install_swift.sh first, or set SWARSAATHI_SWIFT to a Swift executable.' >&2
    exit 1
fi
mkdir -p "$cache/clang" "$cache/swiftpm" "$cache/config" "$cache/security"
export CLANG_MODULE_CACHE_PATH="$cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/clang"
export XDG_CACHE_HOME="$cache"
exec "$swift" test --cache-path "$cache/swiftpm" --config-path "$cache/config" \
    --security-path "$cache/security" --configuration release --jobs 2 "$@"
