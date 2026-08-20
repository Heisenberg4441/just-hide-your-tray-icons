#!/bin/bash
# Builds JustHide.app. No Xcode project, no SwiftPM — just swiftc and a bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/JustHide.app"
MACOS_MIN="13.0"
SOURCES=(Sources/*.swift)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

build_slice() {
  local arch="$1" out="$2"
  swiftc -O -swift-version 5 \
    -target "${arch}-apple-macosx${MACOS_MIN}" \
    -o "$out" "${SOURCES[@]}"
}

# Universal when the SDK can produce both slices, native-only otherwise.
if build_slice arm64 build/JustHide-arm64 2>/dev/null \
   && build_slice x86_64 build/JustHide-x86_64 2>/dev/null; then
  lipo -create build/JustHide-arm64 build/JustHide-x86_64 \
       -output "$APP/Contents/MacOS/JustHide"
  rm -f build/JustHide-arm64 build/JustHide-x86_64
  echo "built universal (arm64 + x86_64)"
else
  rm -f build/JustHide-arm64 build/JustHide-x86_64
  build_slice "$(uname -m)" "$APP/Contents/MacOS/JustHide"
  echo "built $(uname -m) only"
fi

# Ad-hoc signature: without one the bundle identity changes on every rebuild,
# which loses the login-item registration and the saved icon position.
codesign --force --sign - --timestamp=none "$APP"

echo "→ $APP"
