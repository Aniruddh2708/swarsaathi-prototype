#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
    echo 'Usage: sh scripts/replay_report.sh path/to/practice.json' >&2
    exit 1
fi
tools=${SWARSAATHI_TOOLS_ROOT:-$repo/.local/swift}
if [ -n "${SWARSAATHI_SWIFTC:-}" ]; then
    compiler=$SWARSAATHI_SWIFTC
elif [ "$(uname -s)" = Darwin ]; then
    compiler=$(xcrun --find swiftc) || {
        echo 'Swift compiler was not found. Select an Xcode toolchain or set SWARSAATHI_SWIFTC.' >&2
        exit 1
    }
elif command -v swiftc >/dev/null 2>&1; then
    compiler=$(command -v swiftc)
else
    compiler=$tools/usr/bin/swiftc
fi
compiler=$(command -v "$compiler") || {
    echo 'Swift compiler was not found. Install Swift, run sh scripts/install_swift.sh, or set SWARSAATHI_SWIFTC.' >&2
    exit 1
}
if [ ! -x "$compiler" ]; then
    echo 'The selected Swift compiler is not executable. Check SWARSAATHI_SWIFTC or the installed toolchain.' >&2
    exit 1
fi
mkdir -p "$repo/.build/replay-module-cache"
export CLANG_MODULE_CACHE_PATH="$repo/.build/replay-module-cache"
"$compiler" -O "$repo/Sources/SwarSaathi/MusicTheory.swift" \
    "$repo/Sources/SwarSaathi/PracticeTimeline.swift" "$repo/Tools/ReplayReport.swift" \
    -o "$repo/.build/replay-report"
exec "$repo/.build/replay-report" "$1"
