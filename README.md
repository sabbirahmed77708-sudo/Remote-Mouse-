# Remote Mouse

Use your phone as a mouse, keyboard and live screen for your Windows PC. Nothing to install on the phone: it opens from an icon on the home screen, named after your PC. No pip packages on the PC.

## Setup (once)

**Easiest: the Windows app.** Download `RemoteMouse.exe` from the [Releases](../../releases) page (or from the latest *Build Windows exe* run under **Actions → Artifacts**) and double-click it. No Python needed. Windows may show a SmartScreen / Firewall prompt: choose **Run anyway** and **Allow** on *Private networks*.

**Or with Python:** install [Python 3](https://www.python.org/downloads/) (tick "Add Python to PATH"), then double-click `run.bat`.

Then:

1. A page opens on the PC showing a **QR code** and a PIN (any time: http://localhost:8765/pair).
2. Put your phone on the **same Wi-Fi** as the PC.
3. Scan the QR code with the phone camera and open the link. You are connected.
4. Add it to the home screen so it shows up with your PC's name:
   - Android Chrome: ⋮ menu → *Add to Home screen*
   - iPhone Safari: Share → *Add to Home Screen*
5. On the PC page, tick **Start Remote Mouse when Windows starts** so it is always ready (it runs hidden; use the **Stop** button on that page to quit it).

From then on: tap the icon on your phone and you can control the PC, as long as both are on the same Wi-Fi and the PC is on.

If the phone cannot connect: run `setup_firewall.bat` once as administrator, and set the Wi-Fi network profile on the PC to **Private**. If your router later gives the PC a new address, open the PC page again and scan the new QR code (or use the `http://PCNAME.local:8765` address shown there, which works on many phones and does not change).

Command-line options: `--port 8765`, `--pin 123456`, `--name MyPC`, `--no-browser`, `--install-startup`, `--remove-startup`, `--dry-run` (print commands only, for testing).

## Features

**Mouse** – 1 finger moves, tap = left click, 2-finger tap = right click, 2-finger drag = scroll, tap-then-hold-and-drag = drag and drop. Left / Mid / Right buttons, double click, speed and scroll-speed sliders, invert scroll.

**Screen** – live view of the PC screen (3 quality levels). Touch to put the cursor there, drag to move it, optionally click when you lift your finger.

**Type** – live typing to the PC (Bangla and other Unicode text too), sticky Ctrl / Alt / Shift / Win for combos, Esc, Tab, Backspace, Enter, Del, arrows, Home/End, Copy/Paste/Cut/All/Undo, Alt+Tab, Alt+F4, F5. Backspace, arrows and Space repeat while held.

**Media** – play/pause, next, previous, volume up/down (hold to repeat), mute.

**Hotkeys** – Desktop, Task View, Explorer, Run, Task Manager, Screenshot, Lock; presentation and video controls; browser tab controls.

**More** – clipboard sync both ways, open a link on the PC, open Notepad / Calculator / Explorer / Task Manager / Paint / Settings, Lock / Sleep / Restart / Shut down (confirms first, 10 s delay, Cancel button).

## Safety

- Every request from the phone needs the PIN. After 5 wrong guesses an address is blocked for 1 minute.
- The pairing page (which shows the PIN) and the Stop / autostart controls only work from the PC itself, and refuse requests that arrive from websites or other devices.
- Only a fixed list of apps and power actions can be triggered, and only `http`/`https` links can be opened.
- The connection is plain HTTP on your local network, so only use it on a Wi-Fi you trust. Never forward the port to the internet.

## Notes

- Settings and the PIN are kept in `%APPDATA%\RemoteMouse`; a log is written there when running hidden.
- Home-screen shortcuts to an `http://` address open in the phone's browser; whether the browser bar is hidden depends on the phone. The icon and name always show.
- Windows does not let normal programs control admin (elevated) windows. To control those, run Remote Mouse as administrator.
- Screen view shows the primary monitor only.
- "Sleep" may hibernate instead if hibernation is enabled on your PC.
- Some games ignore injected keyboard input. Antivirus tools sometimes flag any program that sends keyboard/mouse input; the source is all in `remote_mouse.py`.
