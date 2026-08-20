#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ZIG_BIN="${ZIG_BIN:-zig}"
SOURCE="$ROOT_DIR/native-reading-time-package/reading-syncd.c"
OUT="$ROOT_DIR/native-reading-time-package/bin"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT_DIR/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ROOT_DIR/.zig-cache/local}"

mkdir -p "$OUT" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
"$ZIG_BIN" cc -std=c11 -Os -s -static -target arm-linux-musleabihf "$SOURCE" -o "$OUT/reading-syncd-armv7"
"$ZIG_BIN" cc -std=c11 -Os -s -static -target aarch64-linux-musl "$SOURCE" -o "$OUT/reading-syncd-arm64"
chmod 755 "$OUT/reading-syncd-armv7" "$OUT/reading-syncd-arm64"

file "$OUT/reading-syncd-armv7" "$OUT/reading-syncd-arm64"
