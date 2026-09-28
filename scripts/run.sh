#!/bin/bash
# Rebuild and (re)launch DynamicBar.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DynamicBar.app"

"$ROOT/scripts/build.sh"

# A previous instance would make the new one exit immediately (single-instance guard).
if pgrep -f "DynamicBar.app/Contents/MacOS/DynamicBar" >/dev/null 2>&1; then
  echo "==> stopping the running instance"
  pkill -f "DynamicBar.app/Contents/MacOS/DynamicBar" || true
  sleep 1
fi

echo "==> launching $APP"
open "$APP"
sleep 1
if pgrep -f "DynamicBar.app/Contents/MacOS/DynamicBar" >/dev/null 2>&1; then
  echo "==> running (pid $(pgrep -f 'DynamicBar.app/Contents/MacOS/DynamicBar' | head -1))"
  echo "    hover the top-centre of the screen, or click the menu bar icon."
else
  echo "!! process is not running — check ~/Library/Logs/DynamicBar/DynamicBar.log" >&2
  exit 1
fi
