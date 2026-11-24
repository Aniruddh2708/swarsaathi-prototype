#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 2 ]; then
    echo 'Usage: sh scripts/validate_recording.sh mono-16-bit.wav reference.csv' >&2
    exit 1
fi
compiler=${SWARSAATHI_SWIFTC:-swiftc}
if ! command -v "$compiler" >/dev/null 2>&1; then
    compiler=${SWARSAATHI_TOOLS_ROOT:-$repo/.local/swift}/usr/bin/swiftc
fi
mkdir -p "$repo/.build/validation-cache"
export CLANG_MODULE_CACHE_PATH="$repo/.build/validation-cache"
"$compiler" -O "$repo/Sources/SwarSaathi/MusicTheory.swift" \
    "$repo/Sources/SwarSaathi/PitchDetector.swift" "$repo/Tools/ValidateRecording.swift" \
    -o "$repo/.build/validate-recording"
exec "$repo/.build/validate-recording" "$1" "$2"
