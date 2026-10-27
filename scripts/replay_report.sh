#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
    echo 'Usage: sh scripts/replay_report.sh path/to/practice.json' >&2
    exit 1
fi
if [ "$(uname -s)" = Darwin ]; then
    compiler=$(xcrun --find swiftc)
else
    compiler=${SWARSAATHI_SWIFTC:-/workspace/.local/swift/usr/bin/swiftc}
fi
mkdir -p "$repo/.build/replay-module-cache"
export CLANG_MODULE_CACHE_PATH="$repo/.build/replay-module-cache"
"$compiler" -O "$repo/Sources/SwarSaathi/MusicTheory.swift" \
    "$repo/Sources/SwarSaathi/PracticeTimeline.swift" "$repo/Tools/ReplayReport.swift" \
    -o "$repo/.build/replay-report"
exec "$repo/.build/replay-report" "$1"
