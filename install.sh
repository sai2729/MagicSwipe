#!/bin/bash
# Installs MagicSwipe:
#   /Applications/MagicSwipe.app                 menu bar app, started at login (LaunchAgent)
#   magicswipe-keyd                              root key sender, started by launchd only while
#                                                the app is switched on (socket activation)
# Requires the Karabiner-DriverKit-VirtualHIDDevice driver (standalone package or Karabiner-Elements).
# Run with: sudo ./install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

USER_NAME="${SUDO_USER:?run via sudo from your own account}"
USER_ID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="/Library/Application Support/MagicSwipe"
APP="/Applications/MagicSwipe.app"
SOCKET="/var/run/magicswipe.sock"
DAEMON_PLIST="/Library/LaunchDaemons/com.magicswipe.keyd.plist"
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.magicswipe.agent.plist"
VHID_DAEMON="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app"

[[ -x "$HERE/build/magicswipe-keyd" && -d "$HERE/build/MagicSwipe.app" ]] ||
  { echo "Missing build output — run ./build.sh first" >&2; exit 1; }
[[ -d "$VHID_DAEMON" ]] ||
  echo "Warning: Karabiner's VirtualHIDDevice driver is not installed; MagicSwipe cannot send keys until it is." >&2

# Stop any running copies (including the earlier command-line version) before replacing files.
launchctl bootout "gui/$USER_ID" "$AGENT_PLIST" 2>/dev/null || true
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
pkill -x magicswipe 2>/dev/null || true
pkill -x MagicSwipe 2>/dev/null || true
rm -f "$SOCKET" "$PREFIX/magicswipe"

mkdir -p "$PREFIX"
install -m 755 -o root -g wheel "$HERE/build/magicswipe-keyd" "$PREFIX/magicswipe-keyd"
install -d /usr/local/bin
install -m 755 -o root -g wheel "$HERE/magicswipe-toggle" /usr/local/bin/magicswipe-toggle
rm -rf "$APP"
cp -R "$HERE/build/MagicSwipe.app" "$APP"
chown -R root:wheel "$APP"

cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.magicswipe.keyd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PREFIX/magicswipe-keyd</string>
    <string>--uid</string>
    <string>$USER_ID</string>
    <!-- Press mouse button 4 (ignored by iPadOS) when needed so Universal Control
         moves keyboard focus to the iPad without a real click. -->
    <string>--focus-button</string>
    <string>4</string>
  </array>
  <!-- Not running until the app connects; exits when the app switches off. -->
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockPathName</key><string>$SOCKET</string>
      <key>SockPathMode</key><integer>438</integer>
    </dict>
  </dict>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>StandardErrorPath</key><string>/var/log/magicswipe-keyd.log</string>
  <key>StandardOutPath</key><string>/var/log/magicswipe-keyd.log</string>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

mkdir -p "$(dirname "$AGENT_PLIST")"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.magicswipe.agent</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/MagicSwipe</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Restart after a crash, but stay quit after "Quit MagicSwipe" until next login. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/magicswipe-agent.log</string>
</dict>
</plist>
EOF
chown "$USER_NAME" "$AGENT_PLIST"
chmod 644 "$AGENT_PLIST"

launchctl bootstrap system "$DAEMON_PLIST"
launchctl bootstrap "gui/$USER_ID" "$AGENT_PLIST"

echo "MagicSwipe installed. While it is on, a hand icon shows in the menu bar."
echo "Turn it on/off with: magicswipe-toggle   (or a Control Center shortcut, see README.md)"
echo "Logs: /var/log/magicswipe-keyd.log and /tmp/magicswipe-agent.log"
