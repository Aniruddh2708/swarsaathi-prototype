#!/bin/sh
# Reproducible setup for the managed Debian cloud machine. No system writes.
set -eu
cd "$(dirname "$0")/.."
python3 -c 'import sys; assert sys.version_info[:2] in ((3,11),(3,12)), "Python 3.11 or 3.12 required"'
if [ ! -x .venv/bin/python ]; then python3 -m venv .venv; fi
export XDG_CACHE_HOME=/workspace/.cache/swarsaathi
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
swarsaathi_native_root=/workspace/.local/swarsaathi
swarsaathi_native_lib="$swarsaathi_native_root/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$swarsaathi_native_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$PIP_CACHE_DIR" "$swarsaathi_native_root"
.venv/bin/python -m pip install -r requirements.txt
if ! .venv/bin/python -c 'import sounddevice' >/dev/null 2>&1; then
    swarsaathi_apt_root="$XDG_CACHE_HOME/apt"
    mkdir -p "$swarsaathi_apt_root/lists/partial" "$swarsaathi_apt_root/archives/partial"
    # Official Debian indexes are signature verified by apt; downloads checked
    # against their authenticated package hashes. Inherited HTTPS/CA stay intact.
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie main' > "$swarsaathi_apt_root/sources.list"
    apt-get -o Dir::Etc::sourcelist="$swarsaathi_apt_root/sources.list" -o Dir::Etc::sourceparts=- -o Dir::State::lists="$swarsaathi_apt_root/lists" -o Dir::Cache::archives="$swarsaathi_apt_root/archives" -o APT::Update::Error-Mode=any update
    (
        cd "$swarsaathi_apt_root/archives"
        apt-get -o Dir::Etc::sourcelist="$swarsaathi_apt_root/sources.list" -o Dir::Etc::sourceparts=- -o Dir::State::lists="$swarsaathi_apt_root/lists" download libportaudio2
        for swarsaathi_deb in libportaudio2_*.deb; do
            dpkg-deb -x "$swarsaathi_deb" "$swarsaathi_native_root"
        done
    )
    ln -sf libportaudio.so.2 "$swarsaathi_native_lib/libportaudio.so"
fi
.venv/bin/python -m pip check
.venv/bin/python -c 'import numpy, sounddevice; from PyQt6 import QtCore; import pyqtgraph; print("Python packages and PortAudio loaded")'
