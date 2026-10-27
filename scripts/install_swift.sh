#!/bin/sh
# Reproduce the Linux test toolchain. On a Mac use Xcode's Apple toolchain.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
    xcrun swift --version
    exit 0
fi
root=${SWARSAATHI_TOOLS_ROOT:-/workspace/.local/swift}
cache=${SWARSAATHI_DOWNLOAD_CACHE:-/workspace/.cache/swift-download}
if [ -x "$root/usr/bin/swift" ]; then
    "$root/usr/bin/swift" --version
    exit 0
fi
case "$(uname -m)" in x86_64) ;; *) echo 'Linux installer requires x86_64 Debian 12.' >&2; exit 1 ;; esac
mkdir -p "$cache" "$root"
url=https://download.swift.org/swift-6.2.1-release/debian12/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE-debian12.tar.gz
archive="$cache/swift-6.2.1.tar.gz"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 5 --output "$archive.part" "$url"
    mv "$archive.part" "$archive"
fi
curl --fail --location --retry 5 --output "$archive.sig" "$url.sig"
keyring="$cache/verification-keyring"
mkdir -p "$keyring"
chmod 700 "$keyring"
# Public key obtained from swiftlang/swift-org-website/keys/all-keys.asc.
# Pin the full Swift 6.x release key fingerprint; never disable verification.
gpg --batch --homedir "$keyring" --import "$repo/scripts/swift-release-key.asc"
gpg --batch --homedir "$keyring" --with-colons --fingerprint EF80A866B47A981F > "$cache/fingerprint.txt"
if ! grep -q '52BB7E3DE28A71BE22EC05FFEF80A866B47A981F' "$cache/fingerprint.txt"; then
    echo 'Swift release signing key fingerprint mismatch.' >&2; exit 1
fi
gpg --batch --homedir "$keyring" --verify "$archive.sig" "$archive"
tar -xzf "$archive" -C "$root" --strip-components=1
"$root/usr/bin/swift" --version
