#!/bin/bash
# Yubisashi.app を作る。--install を付けると ~/Applications に入れて起動する。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Yubisashi.app"
rm -rf "build/Yubisashi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Yubisashi "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# 同じ証明書で署名し続けると、作り直しても画面収録やマイクの許可が保たれる
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built: $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
  pkill -x Yubisashi || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Yubisashi.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Yubisashi.app"
  echo "installed: ~/Applications/Yubisashi.app"
fi
