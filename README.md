# Remote Mouse

Control your Windows PC from your phone's browser: touchpad, live screen, keyboard, media keys, shortcuts, clipboard and more. Nothing to install on the phone, and no pip packages on the PC.

## Quick start

1. Install [Python 3](https://www.python.org/downloads/) on the PC (tick "Add Python to PATH").
2. Put your phone and PC on the **same Wi-Fi**.
3. Double-click `run.bat` (or run `python remote_mouse.py`).
4. The console prints a URL with a 6-digit PIN. Open it on your phone. Tip: bookmark it or add it to your home screen.
5. If the page does not load: right-click `setup_firewall.bat` and run it as administrator once, and set your Wi-Fi network profile to **Private**.

The PIN is saved in `remote_mouse_pin.txt` so the same link keeps working next time. Delete that file for a new PIN, or pass `--pin 123456`.

Options: `--port 8765`, `--pin 123456`, `--dry-run` (print commands only, for testing).

## Features

**Mouse tab**
- 1 finger moves, tap = left click, 2-finger tap = right click, 2-finger drag = scroll, tap then hold and drag = drag and drop.
- Left / Mid / Right buttons (press and hold works), double click.
- Speed and scroll-speed sliders, invert scroll.

**Screen tab**
- Live view of your PC screen (3 quality levels). Touch it to put the cursor there, drag to move it, and it clicks when you lift your finger (optional).

**Type tab**
- Live typing straight to the PC, Bangla and other Unicode text included.
- Sticky Ctrl / Alt / Shift / Win: tap one, then a key, to send a combo.
- Esc, Tab, Backspace, Enter, Del, arrows, Home/End, Copy/Paste/Cut/All/Undo, Alt+Tab, Alt+F4, F5. Backspace, arrows and Space repeat while held.

**Media tab**
- Play/pause, next, previous, volume up/down (hold to repeat), mute.

**Hotkeys tab**
- Windows: Desktop, Task View, Explorer, Run, Task Manager, Screenshot, Lock.
- Presentation / video controls. Browser tab controls.

**More tab**
- Clipboard: send text from the phone to the PC (and paste it), or read the PC clipboard on the phone.
- Open a link on the PC.
- Open Notepad, Calculator, Explorer, Task Manager, Paint, Settings.
- Lock, Sleep, Restart, Shut down (asks to confirm, 10 s delay, with a Cancel button).

## Safety

- Every request needs the PIN. After 5 wrong guesses an address is blocked for 1 minute.
- Only a fixed list of apps and power actions can be triggered, and only `http`/`https` links can be opened.
- The connection is plain HTTP on your local network, so only use it on a Wi-Fi you trust. Never forward the port to the internet.

## Notes

- Windows does not let normal programs control admin (elevated) windows. To control those, run the server as administrator.
- Screen view shows the primary monitor only.
- "Sleep" may hibernate instead if hibernation is enabled on your PC.
- Some games ignore injected keyboard input.
