#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/dist/Whoops.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Whoops" "$APP/Contents/MacOS/Whoops"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null
fi

printf 'Built %s\n' "$APP"
