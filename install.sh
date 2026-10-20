#!/bin/bash
# Builds Claude Usage and installs it to ~/Applications.
#
#   ./install.sh [--login-item] [--statusline]
#
#   --login-item   start it at every login (a LaunchAgent for the current user)
#   --statusline   add the tap to your Claude Code status line, for live % readings
#
# Undo everything with ./uninstall.sh.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="dev.claude-usage-tracker"
DEST="$HOME/Applications/ClaudeUsage.app"
BIN="$DEST/Contents/MacOS/ClaudeUsage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

login_item=0 statusline=0
for arg in "$@"; do
  case "$arg" in
    --login-item) login_item=1 ;;
    --statusline) statusline=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

[ "$(uname)" = Darwin ] || { echo "Claude Usage runs on macOS only."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "Claude Usage needs macOS 14 (Sonoma) or later."; exit 1; }
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are needed to build. Install them with:"
  echo "  xcode-select --install"
  echo "then run ./install.sh again."
  exit 1
fi

echo "==> Building"
make >/dev/null

echo "==> Installing to $DEST"
# Stop a running copy first so the new build is the one that runs.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto build/ClaudeUsage.app "$DEST"

if [ "$login_item" = 1 ]; then
  echo "==> Adding login item ($PLIST)"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<!-- Restart after a crash, but not after Quit from the menu. -->
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

if [ "$statusline" = 1 ]; then
  echo "==> Adding the tap to your Claude Code status line"
  /usr/bin/python3 scripts/statusline.py install "$BIN"
fi

# The login item starts it already; otherwise start it now. A second copy exits on its own.
[ "$login_item" = 1 ] || open "$DEST"

echo "Done. Claude Usage is in the menu bar and on the desktop."
[ "$statusline" = 1 ] || echo "Tip: ./install.sh --statusline gives live % readings from Claude Code."
