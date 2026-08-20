#!/bin/bash
# Builds JustHide.app and installs it into /Applications, then restarts it.
# Set JUSTHIDE_DEST to install somewhere else (used by the tests).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="${JUSTHIDE_DEST:-/Applications}/JustHide.app"

killall JustHide 2>/dev/null || true
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R build/JustHide.app "$DEST"
open "$DEST"

echo
echo "→ установлено: $DEST"
echo "  Автозапуск включается в меню по правому клику на стрелочке."
