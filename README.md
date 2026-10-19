# MagicSwipe

Two-finger Magic Mouse swipe on an iPad controlled through Universal Control:
| Gesture | iPad shortcut | Does |
|---|---|---|
| swipe left / right | Globe+Left / Globe+Right | switch apps |
| swipe up, or double-tap | Globe+Up | App Switcher |
| swipe down | Globe+H | Home Screen |

The double-tap does not scroll the page underneath.

Universal Control forwards only pointer, scroll and keyboard input from a mouse, so the
iPad never sees the Magic Mouse's swipe gesture. MagicSwipe reads the touches on the
Mac and presses **Globe + Left/Right arrow** on a virtual keyboard instead. The keys
come from a virtual *hardware* device (Karabiner's DriverKit driver), which Universal
Control forwards like a real keyboard. Synthetic `CGEvent` keys never reach the iPad.

## Pieces

| Piece | Runs as | When |
|---|---|---|
| `/Applications/MagicSwipe.app` | you | only while MagicSwipe is on (hand icon in the menu bar) |
| `magicswipe-keyd` | root | only while MagicSwipe is on (launchd socket activation) |
| Karabiner VirtualHIDDevice daemon | root | started/stopped by `magicswipe-keyd` |
| Karabiner VirtualHIDDevice driver | driver | always loaded once activated (idle when unused) |

`magicswipe-toggle` turns it on (starts the app) or off (quits it). Quitting
disconnects from `magicswipe-keyd`, which exits and stops the Karabiner daemon, so
nothing of MagicSwipe's runs while it is off. The state is remembered across logins.

## Control Center toggle

1. Shortcuts → Settings → Advanced → turn on **Allow Running Scripts**.
2. New shortcut named **MagicSwipe** with a **Run Shell Script** action:
   `/usr/local/bin/magicswipe-toggle`
   Optionally add **Show Notification** with the *Shell Script Result*.
3. Control Center → **Edit Controls** → Shortcuts → add **MagicSwipe**.

From Terminal: `magicswipe-toggle`, `magicswipe-toggle on`, `magicswipe-toggle off`.

Where the pointer is comes from Universal Control itself: it publishes the notify(3)
state `user.uid.<uid>.com.apple.universalcontrol.inputstate` (bit 0x2 = pointer on
another device, 0x1 = keyboard on another device). While the pointer is on the Mac,
MagicSwipe does not read the Magic Mouse touches at all; it starts reading them when
the pointer moves onto the iPad.

Universal Control sends keys to the device that was last clicked, so when the keyboard
is not yet on the iPad `magicswipe-keyd` first presses mouse button 4 on a virtual
mouse (ignored by iPadOS) to move keyboard focus there.

Universal Control forwards the Magic Mouse's scrolling straight from the hardware, so
swipes also scroll the page under the pointer a little; that cannot be blocked without
proxying all mouse input.

## Build and install

`vendor/vhid` is a git submodule pinned to Karabiner-DriverKit-VirtualHIDDevice v8.5.0
(client protocol 7); clone with `git clone --recursive` or run `git submodule update --init`.

```bash
./build.sh
sudo ./install.sh
```

No Input Monitoring permission is needed: the app reads Magic Mouse touches through
MultitouchSupport and the pointer location from Universal Control's published state.

Uninstall: `sudo ./uninstall.sh`

## Driver only, without Karabiner-Elements

MagicSwipe needs only Karabiner's driver, not the Karabiner-Elements app.

1. Karabiner-Elements Settings → **Uninstall** (this also deactivates the driver), then restart.
2. Install the standalone driver package (signed and notarized; it ships in the cloned repo):
   ```bash
   sudo installer -pkg vendor/vhid/dist/Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg -target /
   ```
3. Activate the driver, then approve it in System Settings → General → Login Items & Extensions → Driver Extensions:
   ```bash
   /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate
   ```

To remove the driver later:

```bash
bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh'
sudo bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh'
```

## Tuning (`app/main.m`)

- `kSideTravel` (0.10) / `kUpTravel` (0.06): fraction of the touch surface the fingers must travel
- `kSideRatio` / `kUpRatio`: how straight the swipe must be
- `kTapMaxDuration`, `kTapMaxMove`, `kDoubleTapWindow`: two-finger double-tap timing
- Menu → **Reverse Swipe Direction** flips which way goes to the previous app

## Logs

`/tmp/magicswipe-agent.log` (app) and `/var/log/magicswipe-keyd.log` (key sender).
