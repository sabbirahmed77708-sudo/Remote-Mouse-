# Remote Mouse

Control your Windows PC from your phone's browser: touchpad, scroll, keyboard, media keys and shortcuts. No app to install on the phone, and no pip packages on the PC.

## Quick start

1. Install [Python 3](https://www.python.org/downloads/) on the PC (tick "Add Python to PATH").
2. Double-click `run.bat` (or run `python remote_mouse.py`).
3. The console prints a URL and a 6-digit PIN. Open the URL on your phone (same Wi-Fi).
4. If Windows Firewall asks, allow Python on **Private networks**.

Options: `--port 8765`, `--pin 123456` (fixed PIN), `--dry-run` (print commands only, for testing).

## Features

- **Touchpad:** 1 finger moves, tap = left click, 2-finger tap = right click, 2-finger drag = scroll, tap then hold and drag = drag and drop. Speed slider and invert-scroll option.
- **Mouse buttons:** Left / Middle / Right, press and hold works.
- **Keyboard:** live typing (Bangla and other Unicode text works), Esc, Tab, Backspace, Enter, Del, arrows, Home/End, Copy/Paste/Cut/Select all/Undo, Alt+Tab, Win. Backspace, arrows and Space repeat while held.
- **Media:** play/pause, next, previous, volume up/down (hold to repeat), mute.
- **Shortcuts:** show desktop, task view, Explorer, Run, Task Manager, screenshot, lock PC; presentation and video controls; browser tab controls.
- **PIN protection:** every command needs the PIN; wrong guesses are slowed down.

## Notes

- Works only on the same network. Do not expose the port to the internet.
- Windows does not let normal programs control admin (elevated) windows. To control those, run the server as administrator.
- Some games ignore injected keyboard text.
