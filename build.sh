#!/bin/bash
# Builds build/MagicSwipe.app (menu bar app) and build/magicswipe-keyd (root key sender).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

clang++ -std=c++23 -O2 -Wall \
  -isystem vendor/vhid/vendor/vendor/include -isystem vendor/vhid/include \
  keyd/main.cpp -framework CoreFoundation -framework IOKit \
  -o build/magicswipe-keyd

APP=build/MagicSwipe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp app/Info.plist "$APP/Contents/Info.plist"
clang -fobjc-arc -O2 -Wall app/main.m \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
  -framework AppKit \
  -o "$APP/Contents/MacOS/MagicSwipe"

# Ad-hoc signatures. Each rebuild changes the app's signature, so Input Monitoring
# must be re-allowed for MagicSwipe after installing a rebuilt copy.
codesign --force --sign - "$APP"
codesign --force --sign - --identifier com.magicswipe.keyd build/magicswipe-keyd

echo "Built $APP and build/magicswipe-keyd"
