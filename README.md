# MagicSwipe

**Use Magic Mouse gestures on your iPad through Universal Control.**

With Universal Control you can move your Mac's Magic Mouse onto an iPad, but the
mouse's swipe gestures don't come along. A two-finger swipe that switches apps on
the Mac does nothing on the iPad, so you end up reaching for the trackpad or the iPad
screen. MagicSwipe fixes that:

| On the iPad, with the Magic Mouse | Does | Sends |
|---|---|---|
| two-finger swipe left / right | switch to the previous / next app | Globe + ← / → |
| two-finger swipe up, or two-finger double-tap | open the App Switcher | Globe + ↑ |
| two-finger swipe down | go to the Home Screen | Globe + H |

While the pointer is on the Mac, MagicSwipe stays out of the way and your Mac gestures
work as usual. You can switch it on and off from Control Center, and when it's off
none of its processes run.

> Tested on macOS 27 with a Magic Mouse (Bluetooth product ID 0x0269) and an iPad using
> Universal Control. It relies on undocumented Apple internals (see
> [How it works](#how-it-works)), so a future macOS update may break it.

## Requirements

- A Mac and an iPad set up for [Universal Control](https://support.apple.com/102459)
- A Magic Mouse connected to the Mac
- Xcode or the Command Line Tools (`xcode-select --install`), with a compiler that supports C++23 (Xcode 16 or later)
- An administrator account (installation uses `sudo`)
- macOS 26 or later for the Control Center button (on older versions, use the Terminal command or a keyboard shortcut instead)

## Install

### 1. Get the code

```bash
git clone --recursive https://github.com/sai2729/MagicSwipe.git
cd MagicSwipe
```

`--recursive` also downloads [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice),
the open-source virtual keyboard driver MagicSwipe sends keys through. If you already
cloned without it, run `git submodule update --init`.

### 2. Install the virtual keyboard driver

MagicSwipe needs only this driver, not the Karabiner-Elements app. The package below
is signed and notarized by its author and comes with the submodule.

```bash
sudo installer -pkg vendor/vhid/dist/Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg -target /
/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate
```

Then approve the driver: **System Settings → General → Login Items & Extensions →
Driver Extensions** (click ⓘ next to *.Karabiner-VirtualHIDDevice-Manager*) → turn it on.

Check that it's active. The line should end in `[activated enabled]`:

```bash
systemextensionsctl list | grep pqrs
```

> **Already using Karabiner-Elements?** It installs the same driver, so you can skip
> this step. MagicSwipe is built against driver package 8.5.0 (client protocol 7). If
> your Karabiner-Elements ships a different driver version and keys never arrive, see
> [Troubleshooting](#troubleshooting).

### 3. Build and install MagicSwipe

```bash
./build.sh
sudo ./install.sh
```

This installs:

- `/Applications/MagicSwipe.app`, the app that recognises the gestures (a hand icon in the menu bar while it's on)
- `magicswipe-keyd`, a small helper that runs as root and presses the keys on the virtual keyboard
- `/usr/local/bin/magicswipe-toggle`, which turns MagicSwipe on and off

MagicSwipe turns on straight away. Move the pointer onto your iPad and try a two-finger
swipe on the Magic Mouse.

No Input Monitoring or Accessibility permission is needed.

### 4. Add an on/off button to Control Center (optional)

1. Open **Shortcuts** → Settings → **Advanced** → turn on **Allow Running Scripts**.
2. Create a shortcut named **MagicSwipe** with a **Run Shell Script** action containing
   `/usr/local/bin/magicswipe-toggle`.
   To see "MagicSwipe is on/off" when you tap it, add a **Show Notification** action
   with *Shell Script Result*.
3. Open **Control Center → Edit Controls → Shortcuts** and add **MagicSwipe**.

You can also use Terminal: `magicswipe-toggle`, `magicswipe-toggle on`,
`magicswipe-toggle off`. MagicSwipe remembers whether it was on or off after a restart.

## Using it

- Gestures work only while the pointer is on the iPad. You don't need to click on the iPad first.
- Swipes move the page under the pointer a little, because Universal Control also forwards the mouse's scrolling. The two-finger **double-tap** opens the App Switcher without any scrolling.
- If left and right feel backwards, use the menu bar icon → **Reverse Swipe Direction**.
- To turn it off, use the Control Center button, `magicswipe-toggle off`, or the menu → **Turn Off MagicSwipe**.

### What runs on your Mac

| Process | When it runs | Memory |
|---|---|---|
| MagicSwipe.app | only while it's on | ~18 MB |
| magicswipe-keyd (root) | only while it's on (started on demand by launchd) | ~6 MB |
| Karabiner VirtualHIDDevice daemon (root) | only while it's on (started and stopped by magicswipe-keyd) | ~10 MB |
| Karabiner VirtualHIDDevice driver | always (an idle system driver) | ~3 MB |

While the pointer is on the Mac, MagicSwipe doesn't read the mouse's touches at all, so it uses no CPU.

## Uninstall

```bash
sudo ./uninstall.sh
```

To remove the driver as well:

```bash
bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh'
sudo bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh'
```

Remove the **MagicSwipe** shortcut from Shortcuts and Control Center yourself.

## Troubleshooting

Check the logs first:

```bash
tail -20 /var/log/magicswipe-keyd.log /tmp/magicswipe-agent.log
```

| Symptom | Likely cause / fix |
|---|---|
| Menu says *Key sender not reachable* | Run `sudo ./install.sh` again. |
| Log says *could not start … Karabiner-VirtualHIDDevice-Daemon* | The driver isn't installed: repeat step 2. |
| Log never says *virtual keyboard ready: yes* | The driver isn't approved, or its version doesn't match. Check `systemextensionsctl list \| grep pqrs`; if you're using Karabiner-Elements' driver, install the 8.5.0 package from step 2 instead. |
| Log shows *sent Globe+…*, but the iPad does nothing | Check that the Globe shortcuts work on your iPad: with the pointer on the iPad, press 🌐 + ← on a real keyboard. |
| Gestures aren't recognised | Run the probe (below) to see what MagicSwipe detects. As a last resort, allow MagicSwipe under Privacy & Security → Input Monitoring. |
| Stopped working after a macOS update | One of the undocumented interfaces probably changed. The probe shows which one. |

**Probe mode** logs every gesture and Universal Control state change, and sends nothing:

```bash
magicswipe-toggle off
/Applications/MagicSwipe.app/Contents/MacOS/MagicSwipe --probe
```

**Test the key path without gestures.** With the pointer on the iPad, this should switch apps after 5 seconds:

```bash
sudo "/Library/Application Support/MagicSwipe/magicswipe-keyd" --test L --focus-button 4
```

## How it works

Here's why something this simple needs a driver:

1. **Universal Control ignores fake key presses.** Keys made with `CGEventPost` or AppleScript only reach the Mac. Universal Control picks up input lower down, at the hardware (HID) level, so the keys have to come from a device that looks like real hardware. Karabiner's DriverKit driver provides a virtual keyboard and mouse that macOS treats exactly like physical ones. Only root processes may use it, which is why `magicswipe-keyd` runs as root.
2. **Universal Control sorts devices by type.** It sends a trackpad's raw finger data to the iPad, which is why trackpad gestures work there. For anything it classifies as a *mouse*, including the Magic Mouse, it only sends pointer movement, buttons and scrolling. A live, draggable app switch would need a virtual *trackpad*, and Apple only grants drivers permission for that case by case. So MagicSwipe uses the iPad's keyboard shortcuts instead.
3. **Reading the gestures.** The app reads Magic Mouse touches from Apple's private `MultitouchSupport.framework` and recognises two-finger swipes and taps itself.
4. **Knowing where the pointer is.** Universal Control publishes a notify(3) state, `user.uid.<uid>.com.apple.universalcontrol.inputstate`. Bit `0x2` means the pointer is on another device, and `0x1` means the keyboard is. MagicSwipe reads touches only while bit `0x2` is set.
5. **Keyboard focus.** Universal Control sends typing to the device you last clicked. If the keyboard isn't on the iPad yet, `magicswipe-keyd` first presses mouse button 4 on the virtual mouse. iPadOS ignores that button, but it moves the keyboard to the iPad, so you never have to click there.
6. **Running only when on.** `magicswipe-keyd` is a launchd socket-activated daemon. It starts when the app connects and exits when the app disconnects, and it stops the Karabiner daemon as it goes. It accepts only one-byte commands from the logged-in user (checked with `getpeereid`), and only ever presses the four shortcuts above.

### Tuning

These are in `app/main.m`. Rebuild and reinstall after changing them.

- `kSideTravel` (0.10) / `kUpTravel` (0.06): how far the fingers must travel, as a fraction of the touch surface
- `kSideRatio` / `kUpRatio`: how straight the swipe must be
- `kTapMaxDuration`, `kTapMaxMove`, `kDoubleTapWindow`: double-tap timing

## Credits and license

MagicSwipe is MIT licensed (see [LICENSE](LICENSE)). The virtual HID driver and client
library are [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
by Takayama Fumihiko, which is public domain. MagicSwipe isn't affiliated with Apple or
the Karabiner project.
