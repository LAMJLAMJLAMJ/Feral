#!/bin/bash
# Controls the installed engine (see install-engine.sh).
#
#   ./scripts/engine.sh status     launchd's view: running or not, pid, restarts, last exit
#   ./scripts/engine.sh log        follow the engine's log
#   ./scripts/engine.sh reload     re-read engine.json without stopping (routing ramps in, no click)
#   ./scripts/engine.sh restart    stop and start
#   ./scripts/engine.sh stop       stop cleanly; launchd leaves it stopped until start or next login
#   ./scripts/engine.sh start
#   ./scripts/engine.sh crash      make it crash (SIGABRT), to check that launchd brings it back
#   ./scripts/engine.sh uninstall  stop it and remove the launchd agent (settings and log are kept)
set -euo pipefail

LABEL="local.feral.engine"
TARGET="gui/$(id -u)/$LABEL"
LOG="$HOME/Library/Logs/Feral/feral-engine.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-status}" in
    status)    launchctl print "$TARGET" | grep -E '^\s*(state|pid|runs|last exit code|last terminating signal) ' || echo "not loaded" ;;
    log)       tail -n 50 -F "$LOG" ;;
    reload)    launchctl kill SIGHUP "$TARGET" ;;
    restart)   launchctl kickstart -k "$TARGET" ;;
    stop)      launchctl kill SIGTERM "$TARGET" ;;
    start)     launchctl kickstart "$TARGET" ;;
    crash)     launchctl kill SIGABRT "$TARGET"; sleep 2; launchctl print "$TARGET" | grep -E '^\s*(state|pid|runs) ' ;;
    uninstall) launchctl bootout "$TARGET" 2>/dev/null || true; rm -f "$PLIST"; echo "Removed $LABEL" ;;
    *)         sed -n '2,13p' "$0"; exit 1 ;;
esac
