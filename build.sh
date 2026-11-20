#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Rexboard Overlay.app"
BIN="$APP/Contents/MacOS/RexboardOverlay"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework SwiftUI \
  "$ROOT/main.swift" \
  -o "$BIN"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "built $APP"
echo "run:    open -a \"$APP\""
echo "toggle: open 'rexboard-overlay://toggle'"
