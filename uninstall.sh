#!/bin/bash
# Reverses ./install.sh: stops the app, removes the login item, the status-line tap and the app.
#
#   ./uninstall.sh [--purge]
#
#   --purge   also delete config, calibration and saved limits (~/.config/claude-usage-tracker)
#             and the panel position
#
# Status-line backups (*.bak-claude-usage-*) are kept.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="dev.claude-usage-tracker"
DEST="$HOME/Applications/ClaudeUsage.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$(dirname "${CLAUDE_USAGE_CONFIG:-$HOME/.config/claude-usage-tracker/config.json}")"

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

echo "==> Stopping Claude Usage"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true

if [ -f "$PLIST" ]; then
  rm -f "$PLIST"
  echo "==> Removed login item"
fi

echo "==> Removing the status-line tap (if present)"
/usr/bin/python3 scripts/statusline.py uninstall

rm -rf "$DEST"
echo "==> Removed $DEST"

if [ "$purge" = 1 ]; then
  rm -rf "$STATE_DIR"
  defaults delete "$LABEL" 2>/dev/null || true
  echo "==> Removed $STATE_DIR and saved preferences"
fi
echo "Done."
