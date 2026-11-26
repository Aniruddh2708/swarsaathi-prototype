#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 3 ]; then echo "Usage: diagnose_development_recording.sh mono.wav reference.csv baseline|gain2|long-window" >&2; exit 1; fi
compiler=${SWARSAATHI_SWIFTC:-swiftc}
mkdir -p "$repo/.build/validation-cache"
export CLANG_MODULE_CACHE_PATH="$repo/.build/validation-cache"
"$compiler" -O "$repo/Sources/SwarSaathi/MusicTheory.swift" "$repo/Sources/SwarSaathi/PitchDetector.swift" "$repo/Tools/DiagnoseDevelopmentRecording.swift" -o "$repo/.build/diagnose-development-recording"
exec "$repo/.build/diagnose-development-recording" "$1" "$2" "$3"
