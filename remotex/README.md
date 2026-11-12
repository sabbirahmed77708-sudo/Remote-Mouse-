# Remote Mouse (project name: RemoteX)

Use an Android phone as a mouse, keyboard and media remote for a Windows PC over the same Wi-Fi.

- `app/` – Flutter (Material 3) Android app, Android 7+ (minSdk 24)
- `server/` – Windows server (Python, TLS WebSocket, small window with QR code), Windows 10/11
- `docs/PROTOCOL.md` – the wire protocol; `protocol/test_vectors.json` – vectors both sides are tested against

## Get the apps (no build tools needed)
GitHub → **Actions** tab → open the latest green run of
- **RemoteX app (analyze, test, APK)** → artifact `RemoteX-apk` → `Remote-Mouse-arm64.apk` (almost every phone; `arm32` for very old phones, `x86_64` for emulators)
- **RemoteX server (tests + Windows EXE)** → artifact `RemoteXServer-windows` → `RemoteXServer.exe`

(Artifacts are zip files; unzip first. Push a tag `remotex-v1.0.0` to also get them attached to a GitHub Release.)
The APK is signed with the Flutter debug key, so Android will ask you to allow installs from unknown sources.

## Use
1. On the PC run `Remote-Mouse-Setup.exe` once (it adds a firewall rule and starts RemoteX quietly in the background: only a tray icon near the clock, no window).
2. Open RemoteX on the phone (same Wi-Fi) → **Connect to a PC** → **Nearby** → tap your PC.
3. First time the PC shows **Allow this phone?** with a 6-digit number; press Allow if the phone shows the same number. (QR code and typed code still work: double-click the tray icon to see them.)
4. Next time the phone reconnects by itself (also after Wi-Fi drops).

## Bluetooth mode (nothing to install on the PC)
In the app: Connect to a PC > **Bluetooth**. Press "Make this phone visible", pair the phone in Windows (Settings > Bluetooth & devices > Add device), then tap the PC in the app. The phone acts as a Bluetooth mouse, keyboard and media keys. Needs Android 9+ and a phone that allows Bluetooth HID device mode (some makers block it); typing is US-layout characters only.

## Features
Touchpad (move, tap = left click, two-finger tap = right click, two-finger scroll, tap-then-drag), Left/Right/Middle/Double click buttons, keyboard text + special keys + shortcuts, media (play/pause, next, previous, stop, volume, mute), connection status, auto discovery, manual IP, QR pairing, light/dark theme, haptics, saved PCs, auto-reconnect. Server: shows IPs, status, QR and code, lists paired phones, Disconnect / Remove, start with Windows.

## Security model
- Every connection is TLS (`wss://`) with a self-signed certificate created on first start.
- The phone pins the certificate fingerprint (from the QR code, then stored). A different PC/certificate is refused.
- Pairing needs a one-time 12-character code (5 minutes, rotates after 5 wrong tries). Both sides prove knowledge of it with HMAC bound to the certificate, so a man in the middle fails.
- After pairing the phone holds a device key; only paired phones can send commands. Commands before authentication are ignored. Failed attempts are rate-limited per IP; the server drops idle connections.
- Removing a phone in the server window revokes it immediately.
- The server only listens on your LAN; do not port-forward it.

## Build yourself
Server (Windows, Python 3.10+): `cd server` then `build_exe.bat` → `dist\RemoteXServer.exe`.
Run from source: `pip install -r requirements.txt` then `python run_server.py`.
App: install Flutter, then `cd app`, `python tool/prepare_android.py` (creates `android/`, sets minSdk 24, permissions INTERNET/CAMERA/VIBRATE, icon), `flutter pub get`, `flutter build apk --release --split-per-abi`.

## What has actually been tested
Verified automatically on GitHub Actions (see the workflow runs):
- Server: 45 unit tests (protocol, pairing, auth, lockout, input mapping) on Linux and Windows.
- Windows EXE: builds with PyInstaller, the window opens and closes (self-test), TLS handshake with the running EXE works.
- App: `flutter analyze` has no errors; Dart crypto matches the Python test vectors; the real Dart client pairs with the real Python server, sends every command type and the server received them (dry-run input), reconnects with the stored key, and refuses wrong fingerprint, wrong code, wrong key and unauthenticated commands; release APK builds.

**Not tested** (needs real hardware, nobody has run it yet):
- Real mouse/keyboard/media input on Windows (the server was tested with input in dry-run mode; the Win32 `SendInput` code was not exercised).
- The app on a real phone: touch feel, QR camera scan, haptics, UI layout, discovery on a real router (some routers block UDP broadcast – use QR/Manual then).
- Windows Firewall prompt behaviour and start-with-Windows on a real PC.
