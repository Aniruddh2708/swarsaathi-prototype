#!/bin/sh
# Intentionally reproduces the original six tests: five pass, one fails.
# Return the real failing test exit status; never use this as the release gate.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline=d48e4be326df061a101d11114fd6c8b532065a1e
temporary=$(mktemp -d "${TMPDIR:-/tmp}/swarsaathi-baseline.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary/Sources/SwarSaathiCore" "$temporary/Tests/SwarSaathiCoreTests"
cp "$repo/scripts/baseline/Package.swift" "$temporary/Package.swift"
cp "$repo/scripts/baseline/PitchDetectorTests.swift" "$temporary/Tests/SwarSaathiCoreTests/"
git -C "$repo" show "$baseline:Sources/SwarSaathi/MusicTheory.swift" > "$temporary/Sources/SwarSaathiCore/MusicTheory.swift"
git -C "$repo" show "$baseline:Sources/SwarSaathi/PitchDetector.swift" > "$temporary/original.swift"
# Only adapt the unavailable vDSP primitives on Linux. Keep original YIN and
# smoothing unchanged, so the silence regression is reproducible from history.
awk -v shim="$repo/scripts/baseline/linux-adapter.txt" '
    /^import Accelerate$/ { while ((getline line < shim) > 0) print line; next }
    { print }
' "$temporary/original.swift" > "$temporary/Sources/SwarSaathiCore/PitchDetector.swift"
sh "$repo/scripts/test.sh" --package-path "$temporary"
