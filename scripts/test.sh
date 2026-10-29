#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
cache=${SWARSAATHI_SWIFT_CACHE:-$repo/.cache/swift}
tools=${SWARSAATHI_TOOLS_ROOT:-$repo/.local/swift}
if [ -n "${SWARSAATHI_SWIFT:-}" ]; then
    swift=$SWARSAATHI_SWIFT
elif [ "$(uname -s)" = Darwin ]; then
    swift=$(xcrun --find swift) || {
        echo 'Swift was not found. Select an Xcode toolchain or set SWARSAATHI_SWIFT.' >&2
        exit 1
    }
elif command -v swift >/dev/null 2>&1; then
    swift=$(command -v swift)
else
    swift=$tools/usr/bin/swift
fi
swift=$(command -v "$swift") || {
    echo 'Swift was not found. Install Swift, run sh scripts/install_swift.sh, or set SWARSAATHI_SWIFT.' >&2
    exit 1
}
if [ ! -x "$swift" ]; then
    echo 'The selected Swift compiler is not executable. Check SWARSAATHI_SWIFT or the installed toolchain.' >&2
    exit 1
fi
if [ "$(uname -s)" = Darwin ]; then
    exec "$swift" test --configuration release --jobs 2 "$@"
fi
mkdir -p "$cache/clang" "$cache/swiftpm" "$cache/config" "$cache/security"
export CLANG_MODULE_CACHE_PATH="$cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/clang"
export XDG_CACHE_HOME="$cache"
exec "$swift" test --cache-path "$cache/swiftpm" --config-path "$cache/config" \
    --security-path "$cache/security" --configuration release --jobs 2 "$@"
