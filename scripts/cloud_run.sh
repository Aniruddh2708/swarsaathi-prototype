#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export XDG_CACHE_HOME=/workspace/.cache/swarsaathi
export LD_LIBRARY_PATH="/workspace/.local/swarsaathi/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$XDG_CACHE_HOME"
if [ "$#" -eq 0 ]; then set -- main.py; fi
exec .venv/bin/python "$@"
