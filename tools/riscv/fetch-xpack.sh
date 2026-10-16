#!/bin/bash
# Download, verify and unpack the pinned xPack riscv-none-elf-gcc.
# Usage: fetch-xpack.sh [dest-dir]   (default $HOME/opt)
set -euo pipefail
VER=15.2.0-1
NAME=xpack-riscv-none-elf-gcc-$VER
URL=https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$VER/$NAME-linux-x64.tar.gz
SHA256=aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758
dest=${1:-$HOME/opt}
if [ -e "$dest/$NAME" ]; then
  echo "refusing to overwrite existing $dest/$NAME" >&2
  exit 1
fi
mkdir -p "$dest"
tmp=$(mktemp -d "$dest/.fetch-xpack.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 --progress-bar -o "$tmp/$NAME.tar.gz" "$URL"
got=$(sha256sum "$tmp/$NAME.tar.gz" | cut -d' ' -f1)
if [ "$got" != "$SHA256" ]; then
  echo "sha256 mismatch: expected $SHA256, got $got" >&2
  exit 2
fi
mkdir "$tmp/x"
tar -xzf "$tmp/$NAME.tar.gz" -C "$tmp/x"
mv "$tmp/x/$NAME" "$dest/$NAME"
echo "installed $dest/$NAME"
