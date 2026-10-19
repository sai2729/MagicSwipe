#!/bin/bash
# Removes MagicSwipe. Run with: sudo ./uninstall.sh
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

USER_NAME="${SUDO_USER:?run via sudo from your own account}"
USER_ID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
DAEMON_PLIST="/Library/LaunchDaemons/com.magicswipe.keyd.plist"
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.magicswipe.agent.plist"

launchctl bootout "gui/$USER_ID" "$AGENT_PLIST" 2>/dev/null
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null
pkill -x MagicSwipe 2>/dev/null
rm -f "$DAEMON_PLIST" "$AGENT_PLIST" /var/run/magicswipe.sock
rm -rf "/Library/Application Support/MagicSwipe" /Applications/MagicSwipe.app /usr/local/bin/magicswipe-toggle

echo "MagicSwipe removed. Karabiner's driver is untouched; see README.md to remove it."
