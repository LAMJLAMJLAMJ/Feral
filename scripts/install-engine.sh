#!/bin/bash
# Builds the engine and installs it as a launchd agent that starts at login and restarts itself if it
# crashes. Run it again after pulling changes to update the engine.
#
#   ./scripts/install-engine.sh                  install or update
#   ./scripts/install-engine.sh "MADIface XT"    and, on first install, set the audio device
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="local.feral.engine"
DEST="$HOME/Library/Application Support/Feral"
LOGS="$HOME/Library/Logs/Feral"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ENGINE="$DEST/FeralEngine.app/Contents/MacOS/feral-engine"
DOMAIN="gui/$(id -u)"

./scripts/build-engine-app.sh

mkdir -p "$DEST" "$LOGS" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -rf "$DEST/FeralEngine.app"
cp -R build/FeralEngine.app "$DEST/"

if [ ! -f "$DEST/engine.json" ]; then
    if [ $# -gt 0 ]; then "$ENGINE" init-config --device "$1"; else "$ENGINE" init-config; fi
elif [ $# -gt 0 ]; then
    echo "Note: $DEST/engine.json exists already, so the device was not changed. Edit it, then run ./scripts/engine.sh reload."
fi

sed -e "s|@ENGINE@|$ENGINE|" -e "s|@LOGS@|$LOGS|" launchd/local.feral.engine.plist > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "feral-engine is running under launchd as $LABEL."
echo "  Settings: $DEST/engine.json   (./scripts/engine.sh reload after editing)"
echo "  Log:      $LOGS/feral-engine.log   (./scripts/engine.sh log)"
