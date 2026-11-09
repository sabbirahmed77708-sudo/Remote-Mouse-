#!/usr/bin/env python3
"""
Remote Mouse - control your Windows PC from your phone's browser.

Run on the PC:   python remote_mouse.py
Then open the printed URL on your phone (same Wi-Fi). No pip packages needed.

Features: touchpad, scroll, drag, keyboard (any language), media keys,
hotkeys, live PC screen with tap-to-move, clipboard sync, open link,
open apps, lock/sleep/restart/shutdown.

Options:
  --port 8765     port to listen on
  --pin 123456    use a fixed PIN (otherwise a random one is made once and saved)
  --dry-run       don't touch the PC, just print commands (for testing)
"""
import argparse
import ctypes
import hmac
import html as htmllib
import json
import math
import os
import platform
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import webbrowser
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# --------------------------------------------------------------------------
# Windows structures (fixed-width types so they are correct on 32/64-bit)
# --------------------------------------------------------------------------
INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x0001, 0x0002, 0x0004
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x0800, 0x1000


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_int32), ("dy", ctypes.c_int32),
                ("mouseData", ctypes.c_uint32), ("dwFlags", ctypes.c_uint32),
                ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_uint16), ("wScan", ctypes.c_uint16),
                ("dwFlags", ctypes.c_uint32), ("time", ctypes.c_uint32),
                ("dwExtraInfo", ctypes.c_size_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_uint32), ("wParamL", ctypes.c_uint16),
                ("wParamH", ctypes.c_uint16)]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", ctypes.c_uint32), ("u", _INPUT_UNION)]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_int32),
                ("biHeight", ctypes.c_int32), ("biPlanes", ctypes.c_uint16),
                ("biBitCount", ctypes.c_uint16), ("biCompression", ctypes.c_uint32),
                ("biSizeImage", ctypes.c_uint32), ("biXPelsPerMeter", ctypes.c_int32),
                ("biYPelsPerMeter", ctypes.c_int32), ("biClrUsed", ctypes.c_uint32),
                ("biClrImportant", ctypes.c_uint32)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", ctypes.c_uint32 * 3)]


# --------------------------------------------------------------------------
# Key names -> Windows virtual-key codes
# --------------------------------------------------------------------------
VK = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "shift": 0x10, "ctrl": 0x11,
    "alt": 0x12, "esc": 0x1B, "space": 0x20, "pgup": 0x21, "pgdn": 0x22,
    "end": 0x23, "home": 0x24, "left": 0x25, "up": 0x26, "right": 0x27,
    "down": 0x28, "insert": 0x2D, "delete": 0x2E, "win": 0x5B,
    # media keys
    "mute": 0xAD, "voldown": 0xAE, "volup": 0xAF, "next": 0xB0, "prev": 0xB1,
    "stop": 0xB2, "playpause": 0xB3,
}
for _i in range(1, 13):
    VK["f%d" % _i] = 0x6F + _i
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B}
MEDIA = {"mute", "voldown", "volup", "next", "prev", "stop", "playpause"}

# Only these apps / power actions can be triggered from the phone.
APPS = {"notepad": "notepad.exe", "calc": "calc.exe", "explorer": "explorer.exe",
        "taskmgr": "taskmgr.exe", "paint": "mspaint.exe", "settings": "ms-settings:"}
POWER = ("lock", "sleep", "restart", "shutdown", "cancel")


def vk_for(name):
    name = str(name).lower()
    if name in VK:
        return VK[name]
    if len(name) == 1 and name.isalnum() and name.isascii():
        return ord(name.upper())
    return None


def clamp_int(v, lim):
    try:
        n = int(float(v))
    except (TypeError, ValueError, OverflowError):
        return 0
    return max(-lim, min(lim, n))


def clamp01(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return 0.0
    if v != v:  # NaN
        return 0.0
    return max(0.0, min(1.0, v))


def encode_png(w, h, bgra):
    """Encode raw top-down BGRA bytes as an RGB PNG (stdlib only)."""
    rgb = bytearray(w * h * 3)
    rgb[0::3] = bgra[2::4]
    rgb[1::3] = bgra[1::4]
    rgb[2::3] = bgra[0::4]
    stride = w * 3
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type: none
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 1))
            + chunk(b"IEND", b""))


# --------------------------------------------------------------------------
# QR code (byte mode, error correction M, versions 1-6) - stdlib only
# --------------------------------------------------------------------------
_QR_EC = {1: (10, 1), 2: (16, 1), 3: (26, 1), 4: (18, 2), 5: (24, 2), 6: (16, 4)}  # ec cw per block, blocks
_QR_TOTAL = {1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172}
_QR_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34]}
_QR_MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def _gf_mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_generator(degree):
    res = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            res[j] = _gf_mul(res[j], root)
            if j + 1 < degree:
                res[j] ^= res[j + 1]
        root = _gf_mul(root, 2)
    return res


def _rs_remainder(data, gen):
    res = [0] * len(gen)
    for b in data:
        factor = b ^ res.pop(0)
        res.append(0)
        for i, c in enumerate(gen):
            res[i] ^= _gf_mul(c, factor)
    return res


def make_qr(text, mask=None):
    """Return the QR code as a list of rows of booleans (True = dark)."""
    data = text.encode("utf-8")
    for ver in range(1, 7):
        ecl, nblocks = _QR_EC[ver]
        data_cw = _QR_TOTAL[ver] - ecl * nblocks
        if 12 + 8 * len(data) <= data_cw * 8:
            break
    else:
        raise ValueError("text too long for this QR encoder")

    bits = []

    def put(val, n):
        bits.extend((val >> i) & 1 for i in range(n - 1, -1, -1))

    put(0b0100, 4)
    put(len(data), 8)
    for b in data:
        put(b, 8)
    cap = data_cw * 8
    put(0, min(4, cap - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    pad = 0
    while len(bits) < cap:
        put((0xEC, 0x11)[pad % 2], 8)
        pad += 1
    codewords = [int("".join(map(str, bits[j:j + 8])), 2) for j in range(0, len(bits), 8)]

    per = data_cw // nblocks
    blocks = [codewords[i * per:(i + 1) * per] for i in range(nblocks)]
    gen = _rs_generator(ecl)
    ecs = [_rs_remainder(b, gen) for b in blocks]
    final = [b[i] for i in range(per) for b in blocks] + [e[i] for i in range(ecl) for e in ecs]

    size = ver * 4 + 17
    mod = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def setfn(x, y, dark):
        mod[y][x] = dark
        fn[y][x] = True

    for i in range(size):
        setfn(6, i, i % 2 == 0)
        setfn(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    setfn(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    pos = _QR_ALIGN[ver]
    for i, px in enumerate(pos):
        for j, py in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setfn(px + dx, py + dy, max(abs(dx), abs(dy)) != 1)

    def draw_format(m):
        d = m  # error-correction level M has format bits 00
        rem = d
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        fb = ((d << 10) | rem) ^ 0x5412

        def bit(i):
            return ((fb >> i) & 1) != 0

        for i in range(0, 6):
            setfn(8, i, bit(i))
        setfn(8, 7, bit(6))
        setfn(8, 8, bit(7))
        setfn(7, 8, bit(8))
        for i in range(9, 15):
            setfn(14 - i, 8, bit(i))
        for i in range(0, 8):
            setfn(size - 1 - i, 8, bit(i))
        for i in range(8, 15):
            setfn(8, size - 15 + i, bit(i))
        setfn(8, size - 8, True)

    draw_format(0)  # reserve the format areas

    i = 0
    for right in range(size - 1, 0, -2):
        if right <= 6:
            right -= 1
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = size - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x] and i < len(final) * 8:
                    mod[y][x] = ((final[i >> 3] >> (7 - (i & 7))) & 1) != 0
                    i += 1

    def apply_mask(m):
        f = _QR_MASKS[m]
        for y in range(size):
            for x in range(size):
                if not fn[y][x] and f(x, y):
                    mod[y][x] = not mod[y][x]

    def penalty():
        score = 0
        lines = [row for row in mod] + [[mod[y][x] for y in range(size)] for x in range(size)]
        for line in lines:  # runs of 5+ same-colour modules
            run = 1
            for k in range(1, size):
                if line[k] == line[k - 1]:
                    run += 1
                else:
                    if run >= 5:
                        score += 3 + run - 5
                    run = 1
            if run >= 5:
                score += 3 + run - 5
        for line in lines:  # finder-like patterns (1:1:3:1:1 with 4 light modules beside it)
            s = "".join("1" if c else "0" for c in line)
            for pat in ("10111010000", "00001011101"):
                k = s.find(pat)
                while k != -1:
                    score += 40
                    k = s.find(pat, k + 1)
        for y in range(size - 1):  # 2x2 blocks
            for x in range(size - 1):
                if mod[y][x] == mod[y][x + 1] == mod[y + 1][x] == mod[y + 1][x + 1]:
                    score += 3
        dark = sum(sum(row) for row in mod)
        score += (abs(dark * 20 - size * size * 10) // (size * size)) * 10
        return score

    if mask is None:
        best, best_score = 0, None
        for m in range(8):
            apply_mask(m)
            draw_format(m)
            s = penalty()
            apply_mask(m)
            if best_score is None or s < best_score:
                best, best_score = m, s
        mask = best
    apply_mask(mask)
    draw_format(mask)
    return mod


def qr_svg(text):
    m = make_qr(text)
    n, b = len(m), 4
    path = "".join("M%d %dh1v1h-1z" % (x + b, y + b) for y in range(n) for x in range(n) if m[y][x])
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">'
            '<rect width="100%%" height="100%%" fill="#fff"/><path d="%s" fill="#000"/></svg>'
            % (n + 2 * b, n + 2 * b, path))


# --------------------------------------------------------------------------
# App icon (drawn in code so no image files are needed)
# --------------------------------------------------------------------------
_ICON_CACHE = {}


def make_icon_png(size):
    if size in _ICON_CACHE:
        return _ICON_CACHE[size]
    bg, body, wheel = (15, 17, 21), (79, 140, 255), (232, 234, 240)
    S = float(size)

    def cover(d):
        return max(0.0, min(1.0, 0.5 - d * S))

    def rrect(u, v, cx, cy, hx, hy, r):
        qx, qy = abs(u - cx) - (hx - r), abs(v - cy) - (hy - r)
        return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r

    def mix(c1, c2, t):
        return tuple(c1[k] + (c2[k] - c1[k]) * t for k in range(3))

    px = bytearray(size * size * 4)
    n = 0
    for y in range(size):
        v = (y + 0.5) / S
        for x in range(size):
            u = (x + 0.5) / S
            a = cover(rrect(u, v, 0.5, 0.5, 0.19, 0.29, 0.19))
            col = mix(bg, body, a)
            if a > 0:
                lv = cover(abs(u - 0.5) - 0.008) if v < 0.47 else 0.0
                lh = cover(abs(v - 0.47) - 0.008)
                col = mix(col, bg, max(lv, lh) * a)
                col = mix(col, wheel, cover(rrect(u, v, 0.5, 0.37, 0.022, 0.045, 0.022)) * a)
            px[n] = int(col[2])
            px[n + 1] = int(col[1])
            px[n + 2] = int(col[0])
            px[n + 3] = 255
            n += 4
    png = encode_png(size, size, bytes(px))
    _ICON_CACHE[size] = png
    return png


# --------------------------------------------------------------------------
# App data folder and "start with Windows"
# --------------------------------------------------------------------------
def data_dir():
    appdata = os.environ.get("APPDATA")
    if appdata:
        d = os.path.join(appdata, "RemoteMouse")
    elif getattr(sys, "frozen", False):
        d = os.path.dirname(sys.executable)
    else:
        d = os.path.dirname(os.path.abspath(__file__))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    return d


STARTUP_FILE = "RemoteMouse.vbs"


def startup_dir():
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return None
    return os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup")


def startup_command():
    if getattr(sys, "frozen", False):
        return '"%s" --no-browser' % sys.executable
    exe = sys.executable
    base, name = os.path.split(exe)
    if name.lower() == "python.exe" and os.path.exists(os.path.join(base, "pythonw.exe")):
        exe = os.path.join(base, "pythonw.exe")  # no console window
    return '"%s" "%s" --no-browser' % (exe, os.path.abspath(__file__))


def vbs_script(cmd):
    return 'CreateObject("WScript.Shell").Run "%s", 0, False\r\n' % cmd.replace('"', '""')


def startup_enabled(folder=None):
    folder = folder or startup_dir()
    return bool(folder) and os.path.exists(os.path.join(folder, STARTUP_FILE))


def set_startup(enabled, folder=None):
    folder = folder or startup_dir()
    if not folder:
        raise OSError("Windows startup folder not found")
    path = os.path.join(folder, STARTUP_FILE)
    if enabled:
        os.makedirs(folder, exist_ok=True)
        with open(path, "w", encoding="utf-16", newline="") as f:  # UTF-16 with BOM: safe for any user name
            f.write(vbs_script(startup_command()))
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


# --------------------------------------------------------------------------
# Controllers
# --------------------------------------------------------------------------
class Controller:
    """High-level command handling. Subclasses implement the low-level calls."""

    BUTTONS = {  # name -> (down flag, up flag)
        "left": (0x0002, 0x0004),
        "right": (0x0008, 0x0010),
        "middle": (0x0020, 0x0040),
    }

    def __init__(self):
        self.lock = threading.Lock()

    # ---- low level (override) ----
    def _move(self, dx, dy): raise NotImplementedError
    def _abs(self, fx, fy): raise NotImplementedError
    def _mouse_flag(self, flag): raise NotImplementedError
    def _wheel(self, amount, horizontal): raise NotImplementedError
    def _unit(self, unit, up): raise NotImplementedError
    def _vk(self, vk, up): raise NotImplementedError
    def _clip_get(self): raise NotImplementedError
    def _clip_set(self, text): raise NotImplementedError
    def _launch(self, target): raise NotImplementedError
    def _open_url(self, url): raise NotImplementedError
    def _power(self, action): raise NotImplementedError
    def _screen(self, width): raise NotImplementedError  # -> (png bytes, fx, fy)

    # ---- public helpers used by the HTTP layer ----
    def screenshot(self, width):
        width = max(240, min(1280, int(width)))
        return self._screen(width)

    def get_clipboard(self):
        with self.lock:
            return self._clip_get()

    # ---- command handling ----
    def _tap(self, vk):
        self._vk(vk, False)
        self._vk(vk, True)

    def handle_batch(self, cmds):
        with self.lock:
            for c in cmds:
                try:
                    self.handle(c)
                except Exception as e:  # never let one bad command kill the batch
                    print("command error:", ascii(c), e)

    def handle(self, c):
        a = c.get("a")
        if a == "move":
            dx, dy = clamp_int(c.get("dx"), 2000), clamp_int(c.get("dy"), 2000)
            if dx or dy:
                self._move(dx, dy)
        elif a == "abs":
            self._abs(clamp01(c.get("x")), clamp01(c.get("y")))
        elif a in ("click", "down", "up"):
            flags = self.BUTTONS.get(c.get("b", "left"))
            if not flags:
                return
            if a in ("click", "down"):
                self._mouse_flag(flags[0])
            if a in ("click", "up"):
                self._mouse_flag(flags[1])
        elif a == "scroll":
            dy, dx = clamp_int(c.get("dy"), 1200), clamp_int(c.get("dx"), 1200)
            if dy:
                self._wheel(dy, False)
            if dx:
                self._wheel(dx, True)
        elif a == "text":
            self._type_text(str(c.get("s", ""))[:500])
        elif a == "key":
            vk = vk_for(c.get("k"))
            if vk is not None:
                for _ in range(max(1, min(clamp_int(c.get("n", 1), 200), 200))):
                    self._tap(vk)
        elif a == "combo":
            keys = c.get("k", [])
            if not isinstance(keys, list):
                return
            vks = [vk_for(k) for k in keys][:5]
            if vks and None not in vks:
                for v in vks:
                    self._vk(v, False)
                for v in reversed(vks):
                    self._vk(v, True)
        elif a == "media":
            name = str(c.get("k", "")).lower()
            if name in MEDIA:
                self._tap(VK[name])
        elif a == "clip_set":
            self._clip_set(str(c.get("s", ""))[:15000])
            if c.get("paste"):
                time.sleep(0.05)
                self.handle({"a": "combo", "k": ["ctrl", "v"]})
        elif a == "url":
            u = str(c.get("s", "")).strip()
            if not u or len(u) > 2000 or any(ch.isspace() or ord(ch) < 32 for ch in u):
                return
            if "://" not in u:
                u = "https://" + u
            try:
                p = urlparse(u)
                host = p.hostname or ""
                p.port  # raises ValueError for a bad port
            except ValueError:
                return
            if p.scheme in ("http", "https") and host and ("." in host or host == "localhost") \
                    and all(ch.isalnum() or ch in ".-_:" for ch in host):
                self._open_url(u)
        elif a == "app":
            target = APPS.get(str(c.get("k", "")))
            if target:
                self._launch(target)
        elif a == "power":
            action = str(c.get("k", ""))
            if action in POWER:
                self._power(action)

    def _type_text(self, s):
        for ch in s:
            if ch == "\r":
                continue
            if ch == "\n":
                self._tap(VK["enter"])
            elif ch == "\t":
                self._tap(VK["tab"])
            else:
                data = ch.encode("utf-16-le", "surrogatepass")
                for i in range(0, len(data), 2):
                    unit = int.from_bytes(data[i:i + 2], "little")
                    self._unit(unit, False)
                    self._unit(unit, True)


class WindowsController(Controller):
    def __init__(self):
        super().__init__()
        c = ctypes
        u = self.user32 = c.WinDLL("user32", use_last_error=True)
        g = self.gdi32 = c.WinDLL("gdi32", use_last_error=True)
        k = self.kernel32 = c.WinDLL("kernel32", use_last_error=True)
        vp = c.c_void_p

        def sig(fn, argtypes, restype):
            fn.argtypes, fn.restype = argtypes, restype

        sig(u.SendInput, [c.c_uint, c.POINTER(INPUT), c.c_int], c.c_uint)
        sig(u.MapVirtualKeyW, [c.c_uint, c.c_uint], c.c_uint)
        sig(u.GetSystemMetrics, [c.c_int], c.c_int)
        sig(u.SetCursorPos, [c.c_int, c.c_int], c.c_int)
        sig(u.GetCursorPos, [c.POINTER(POINT)], c.c_int)
        sig(u.GetDC, [vp], vp)
        sig(u.ReleaseDC, [vp, vp], c.c_int)
        sig(u.OpenClipboard, [vp], c.c_int)
        sig(u.CloseClipboard, [], c.c_int)
        sig(u.EmptyClipboard, [], c.c_int)
        sig(u.GetClipboardData, [c.c_uint], vp)
        sig(u.SetClipboardData, [c.c_uint, vp], vp)
        sig(u.LockWorkStation, [], c.c_int)
        sig(g.CreateCompatibleDC, [vp], vp)
        sig(g.CreateCompatibleBitmap, [vp, c.c_int, c.c_int], vp)
        sig(g.SelectObject, [vp, vp], vp)
        sig(g.SetStretchBltMode, [vp, c.c_int], c.c_int)
        sig(g.StretchBlt, [vp, c.c_int, c.c_int, c.c_int, c.c_int,
                           vp, c.c_int, c.c_int, c.c_int, c.c_int, c.c_uint], c.c_int)
        sig(g.GetDIBits, [vp, vp, c.c_uint, c.c_uint, vp, vp, c.c_uint], c.c_int)
        sig(g.DeleteObject, [vp], c.c_int)
        sig(g.DeleteDC, [vp], c.c_int)
        sig(k.GlobalAlloc, [c.c_uint, c.c_size_t], vp)
        sig(k.GlobalLock, [vp], vp)
        sig(k.GlobalUnlock, [vp], c.c_int)
        sig(k.GlobalFree, [vp], vp)
        try:
            u.SetProcessDPIAware()  # so screen sizes / cursor coords are real pixels
        except Exception:
            pass

    # ---- input ----
    def _send(self, inp):
        self.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

    def _mouse(self, flags, dx=0, dy=0, data=0):
        inp = INPUT(type=INPUT_MOUSE)
        inp.mi = MOUSEINPUT(dx, dy, data & 0xFFFFFFFF, flags, 0, 0)
        self._send(inp)

    def _move(self, dx, dy):
        self._mouse(MOUSEEVENTF_MOVE, dx, dy)

    def _screen_size(self):
        return max(1, self.user32.GetSystemMetrics(0)), max(1, self.user32.GetSystemMetrics(1))

    def _abs(self, fx, fy):
        sw, sh = self._screen_size()
        self.user32.SetCursorPos(int(fx * (sw - 1)), int(fy * (sh - 1)))

    def _mouse_flag(self, flag):
        self._mouse(flag)

    def _wheel(self, amount, horizontal):
        self._mouse(MOUSEEVENTF_HWHEEL if horizontal else MOUSEEVENTF_WHEEL, 0, 0, amount)

    def _unit(self, unit, up):
        inp = INPUT(type=INPUT_KEYBOARD)
        flags = KEYEVENTF_UNICODE | (KEYEVENTF_KEYUP if up else 0)
        inp.ki = KEYBDINPUT(0, unit, flags, 0, 0)
        self._send(inp)

    def _vk(self, vk, up):
        inp = INPUT(type=INPUT_KEYBOARD)
        flags = (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED else 0) | (KEYEVENTF_KEYUP if up else 0)
        scan = self.user32.MapVirtualKeyW(vk, 0)
        inp.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
        self._send(inp)

    # ---- clipboard ----
    def _clip_get(self):
        u, k = self.user32, self.kernel32
        if not u.OpenClipboard(None):
            return ""
        try:
            h = u.GetClipboardData(13)  # CF_UNICODETEXT
            if not h:
                return ""
            p = k.GlobalLock(h)
            if not p:
                return ""
            try:
                return ctypes.wstring_at(p)[:15000]
            finally:
                k.GlobalUnlock(h)
        finally:
            u.CloseClipboard()

    def _clip_set(self, text):
        u, k = self.user32, self.kernel32
        data = (text + "\0").encode("utf-16-le", "surrogatepass")
        h = k.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        if not h:
            return
        p = k.GlobalLock(h)
        if not p:
            k.GlobalFree(h)
            return
        ctypes.memmove(p, data, len(data))
        k.GlobalUnlock(h)
        if not u.OpenClipboard(None):
            k.GlobalFree(h)
            return
        try:
            u.EmptyClipboard()
            if not u.SetClipboardData(13, h):
                k.GlobalFree(h)
        finally:
            u.CloseClipboard()

    # ---- apps / links / power ----
    def _launch(self, target):
        os.startfile(target)

    def _open_url(self, url):
        webbrowser.open(url)

    def _power(self, action):
        flags = 0x08000000  # CREATE_NO_WINDOW
        if action == "lock":
            self.user32.LockWorkStation()
        elif action == "sleep":
            subprocess.Popen(["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"], creationflags=flags)
        elif action == "restart":
            subprocess.Popen(["shutdown", "/r", "/t", "10"], creationflags=flags)
        elif action == "shutdown":
            subprocess.Popen(["shutdown", "/s", "/t", "10"], creationflags=flags)
        elif action == "cancel":
            subprocess.Popen(["shutdown", "/a"], creationflags=flags)

    # ---- screen capture ----
    def _screen(self, width):
        u, g = self.user32, self.gdi32
        sw, sh = self._screen_size()
        w = min(width, sw)
        h = max(1, int(sh * w / sw))
        hdc_screen = u.GetDC(None)
        if not hdc_screen:
            raise OSError("GetDC failed")
        hdc_mem = hbmp = old = None
        try:
            hdc_mem = g.CreateCompatibleDC(hdc_screen)
            hbmp = g.CreateCompatibleBitmap(hdc_screen, w, h)
            if not hdc_mem or not hbmp:
                raise OSError("could not create bitmap")
            old = g.SelectObject(hdc_mem, hbmp)
            g.SetStretchBltMode(hdc_mem, 4)  # HALFTONE (smooth downscale)
            if not g.StretchBlt(hdc_mem, 0, 0, w, h, hdc_screen, 0, 0, sw, sh, 0x00CC0020 | 0x40000000):
                raise OSError("StretchBlt failed")
            g.SelectObject(hdc_mem, old)  # bitmap must not be selected for GetDIBits
            old = None
            bmi = BITMAPINFO()
            bmi.bmiHeader = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
            buf = ctypes.create_string_buffer(w * h * 4)
            if not g.GetDIBits(hdc_screen, hbmp, 0, h, buf, ctypes.byref(bmi), 0):
                raise OSError("GetDIBits failed")
            pt = POINT()
            u.GetCursorPos(ctypes.byref(pt))
            fx, fy = clamp01(pt.x / max(1, sw - 1)), clamp01(pt.y / max(1, sh - 1))
            return encode_png(w, h, buf.raw), fx, fy
        finally:
            if old and hdc_mem:
                g.SelectObject(hdc_mem, old)
            if hbmp:
                g.DeleteObject(hbmp)
            if hdc_mem:
                g.DeleteDC(hdc_mem)
            u.ReleaseDC(None, hdc_screen)


class DryRunController(Controller):
    def __init__(self):
        super().__init__()
        self.clip = ""
        self.cx = self.cy = 0.5

    def _move(self, dx, dy):
        print(f"[dry] move {dx},{dy}")
        self.cx = clamp01(self.cx + dx / 1920)
        self.cy = clamp01(self.cy + dy / 1080)

    def _abs(self, fx, fy):
        print(f"[dry] abs {fx:.3f},{fy:.3f}")
        self.cx, self.cy = fx, fy

    def _mouse_flag(self, flag): print(f"[dry] mouse flag {flag:#06x}")
    def _wheel(self, amount, horizontal): print(f"[dry] wheel {'H' if horizontal else 'V'} {amount}")
    def _unit(self, unit, up): print(f"[dry] unicode {unit:#06x} {'up' if up else 'down'}")
    def _vk(self, vk, up): print(f"[dry] vk {vk:#04x} {'up' if up else 'down'}")
    def _clip_get(self): return self.clip

    def _clip_set(self, text):
        print(f"[dry] clipboard set ({len(text)} chars)")
        self.clip = text

    def _launch(self, target): print(f"[dry] launch {target}")
    def _open_url(self, url): print(f"[dry] open url {url}")
    def _power(self, action): print(f"[dry] power {action}")

    def _screen(self, width):
        w, h = width, width * 9 // 16
        px = bytearray(w * h * 4)
        for y in range(h):
            row = bytearray()
            for x in range(w):
                row += bytes((x * 255 // w, y * 255 // h, 140, 255))
            px[y * w * 4:(y + 1) * w * 4] = row
        return encode_png(w, h, bytes(px)), self.cx, self.cy


# --------------------------------------------------------------------------
# Web UI
# --------------------------------------------------------------------------
INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#0f1115">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="__PCNAME__">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon-192.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<title>__PCNAME__</title>
<style>
  :root { --bg:#0f1115; --panel:#181b22; --panel2:#222733; --text:#e8eaf0; --muted:#8b93a7; --accent:#4f8cff; --ok:#3ddc84; --bad:#ff5d5d; --warn:#c0392b; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-touch-callout:none; user-select:none; -webkit-user-select:none; }
  html, body { height:100%; margin:0; background:var(--bg); color:var(--text); font:16px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; overscroll-behavior:none; }
  body { display:flex; flex-direction:column; padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display:flex; align-items:center; gap:10px; padding:10px 16px; color:var(--muted); font-size:14px; }
  .dot { width:10px; height:10px; border-radius:50%; background:var(--bad); flex:none; }
  .dot.ok { background:var(--ok); }
  main { flex:1; min-height:0; position:relative; }
  .tab { display:none; position:absolute; inset:0; padding:0 16px 12px; flex-direction:column; gap:12px; overflow:auto; }
  .tab.active { display:flex; }
  .tab > * { flex-shrink:0; }
  #pad { flex:1; min-height:200px; border-radius:20px; background:radial-gradient(circle at 50% 40%, #222a3b, var(--panel)); border:1px solid #2b3345; touch-action:none; display:flex; align-items:center; justify-content:center; color:#3c465c; font-size:14px; text-align:center; padding:20px; }
  .row { display:flex; gap:10px; }
  .row > * { flex:1; }
  button { border:0; border-radius:14px; background:var(--panel2); color:var(--text); font:inherit; font-weight:600; padding:16px 8px; touch-action:manipulation; }
  button:active, button.on { background:var(--accent); }
  button.danger { background:#3a2226; }
  button.danger:active { background:var(--warn); }
  .big { padding:26px 8px; font-size:20px; }
  .opts { display:flex; flex-direction:column; gap:10px; padding:4px 2px; color:var(--muted); font-size:14px; }
  .opts label { display:flex; align-items:center; gap:10px; }
  input[type=range] { flex:1; }
  textarea, input[type=text], input[type=url], select { width:100%; border-radius:14px; border:1px solid #2b3345; background:var(--panel); color:var(--text); font:inherit; padding:12px; user-select:text; -webkit-user-select:text; }
  textarea { height:92px; resize:none; }
  textarea:focus, input:focus { outline:2px solid var(--accent); }
  select { width:auto; padding:8px 10px; }
  .hint { color:var(--muted); font-size:13px; }
  .grid4 { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
  .grid3 { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
  .grid2 { display:grid; grid-template-columns:repeat(2,1fr); gap:10px; }
  nav { display:flex; background:var(--panel); border-top:1px solid #2b3345; }
  nav button { flex:1; border-radius:0; background:transparent; color:var(--muted); padding:15px 2px; font-size:13px; }
  nav button.active { color:var(--accent); }
  #scrwrap { position:relative; width:100%; min-height:120px; background:#000; border-radius:12px; overflow:hidden; touch-action:none; flex:none; }
  #scr { width:100%; display:block; pointer-events:none; -webkit-user-drag:none; }
  #scrmsg { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; color:var(--muted); font-size:14px; pointer-events:none; }
  #cur { position:absolute; width:16px; height:16px; margin:-8px 0 0 -8px; border-radius:50%; border:2px solid #fff; background:rgba(79,140,255,.85); box-shadow:0 0 0 1px #000; pointer-events:none; display:none; }
</style>
</head>
<body>
<header id="hdr"><div class="dot" id="dot"></div><span id="status">Connecting...</span></header>
<main>
  <section class="tab active" id="tab-pad">
    <div id="pad">Touchpad<br>1 finger: move &middot; tap: click &middot; 2-finger tap: right click<br>2 fingers: scroll &middot; tap then hold &amp; drag: drag</div>
    <div class="row">
      <button class="big" data-hold="left">Left</button>
      <button class="big" data-hold="middle">Mid</button>
      <button class="big" data-hold="right">Right</button>
    </div>
    <button id="dbl">Double click</button>
    <div class="opts">
      <label>Speed <input type="range" id="speed" min="0.5" max="4" step="0.1" value="1.6"></label>
      <label>Scroll <input type="range" id="sspeed" min="1" max="10" step="0.5" value="4"></label>
      <label><input type="checkbox" id="invert"> Invert scroll direction</label>
    </div>
  </section>

  <section class="tab" id="tab-screen">
    <div id="scrwrap">
      <img id="scr" alt="">
      <div id="scrmsg">Loading screen...</div>
      <div id="cur"></div>
    </div>
    <div class="opts">
      <label>Quality
        <select id="quality">
          <option value="480">Low (fastest)</option>
          <option value="720" selected>Medium</option>
          <option value="1024">High</option>
        </select>
      </label>
      <label><input type="checkbox" id="tapclick" checked> Click when I lift my finger</label>
    </div>
    <div class="row">
      <button data-hold="left">Left</button>
      <button data-hold="right">Right</button>
    </div>
    <div class="hint">Touch the screen to put the cursor there. Drag to move it.</div>
  </section>

  <section class="tab" id="tab-kb">
    <textarea id="live" placeholder="Type here - it goes straight to the PC" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
    <div class="grid4">
      <button data-mod="ctrl">Ctrl</button>
      <button data-mod="alt">Alt</button>
      <button data-mod="shift">Shift</button>
      <button data-mod="win">Win</button>
    </div>
    <div class="hint">Tap Ctrl / Alt / Shift / Win first, then a key, to send a combo (e.g. Ctrl then C).</div>
    <div class="grid4">
      <button data-key="esc">Esc</button>
      <button data-key="tab">Tab</button>
      <button data-key="backspace" data-repeat>&#9003;</button>
      <button data-key="enter">Enter</button>
      <button data-key="delete" data-repeat>Del</button>
      <button data-key="home">Home</button>
      <button data-key="end">End</button>
      <button data-key="space" data-repeat>Space</button>
    </div>
    <div class="grid3">
      <button data-key="left" data-repeat>&larr;</button>
      <button data-key="up" data-repeat>&uarr;</button>
      <button data-key="right" data-repeat>&rarr;</button>
      <span></span>
      <button data-key="down" data-repeat>&darr;</button>
      <span></span>
    </div>
    <div class="grid4">
      <button data-combo="ctrl+c">Copy</button>
      <button data-combo="ctrl+v">Paste</button>
      <button data-combo="ctrl+x">Cut</button>
      <button data-combo="ctrl+a">All</button>
      <button data-combo="ctrl+z">Undo</button>
      <button data-combo="alt+tab">Alt+Tab</button>
      <button data-combo="alt+f4">Alt+F4</button>
      <button data-key="f5">F5</button>
    </div>
    <div class="hint">Bangla and other languages work too (typed as Unicode).</div>
  </section>

  <section class="tab" id="tab-media">
    <div class="grid3">
      <button class="big" data-media="prev">&#9198;</button>
      <button class="big" data-media="playpause">&#9199;</button>
      <button class="big" data-media="next">&#9197;</button>
      <button class="big" data-media="voldown" data-repeat>Vol &minus;</button>
      <button class="big" data-media="mute">Mute</button>
      <button class="big" data-media="volup" data-repeat>Vol +</button>
    </div>
  </section>

  <section class="tab" id="tab-hot">
    <div class="hint">Windows</div>
    <div class="grid3">
      <button data-combo="win+d">Desktop</button>
      <button data-combo="win+tab">Task View</button>
      <button data-combo="alt+tab">Alt+Tab</button>
      <button data-combo="win+e">Explorer</button>
      <button data-combo="win+r">Run</button>
      <button data-combo="ctrl+shift+esc">Task Mgr</button>
      <button data-combo="win+shift+s">Screenshot</button>
      <button data-power="lock">Lock PC</button>
      <button data-key="win">Start</button>
    </div>
    <div class="hint">Presentation / video</div>
    <div class="grid3">
      <button data-key="f5">Start (F5)</button>
      <button data-key="esc">Exit (Esc)</button>
      <button data-key="f11">Fullscreen</button>
      <button data-key="left" data-repeat>&larr; Prev</button>
      <button data-key="space">Play/Pause</button>
      <button data-key="right" data-repeat>Next &rarr;</button>
    </div>
    <div class="hint">Browser</div>
    <div class="grid3">
      <button data-combo="ctrl+t">New tab</button>
      <button data-combo="ctrl+w">Close tab</button>
      <button data-key="f5">Reload</button>
      <button data-combo="alt+left">Back</button>
      <button data-combo="alt+right">Forward</button>
      <button data-combo="ctrl+l">Address bar</button>
    </div>
  </section>

  <section class="tab" id="tab-more">
    <div class="hint">Clipboard</div>
    <textarea id="clipbox" placeholder="Type or paste text here to send it to the PC. &quot;Get from PC&quot; shows the PC clipboard here."></textarea>
    <div class="grid3">
      <button id="clipSend">Send</button>
      <button id="clipPaste">Send + Paste</button>
      <button id="clipGet">Get from PC</button>
    </div>

    <div class="hint">Open a link on the PC</div>
    <input type="url" id="urlbox" placeholder="e.g. youtube.com" autocapitalize="off" autocorrect="off" spellcheck="false">
    <button id="urlGo">Open on PC</button>

    <div class="hint">Open an app</div>
    <div class="grid3">
      <button data-app="notepad">Notepad</button>
      <button data-app="calc">Calculator</button>
      <button data-app="explorer">Explorer</button>
      <button data-app="taskmgr">Task Mgr</button>
      <button data-app="paint">Paint</button>
      <button data-app="settings">Settings</button>
    </div>

    <div class="hint">Power</div>
    <div class="grid2">
      <button data-power="lock">Lock</button>
      <button data-power="sleep" class="danger">Sleep</button>
      <button data-power="restart" class="danger">Restart</button>
      <button data-power="shutdown" class="danger">Shut down</button>
    </div>
    <button data-power="cancel">Cancel restart / shutdown</button>
    <div class="hint">Restart and shutdown wait 10 seconds - tap Cancel if you change your mind.</div>
  </section>
</main>
<nav>
  <button class="active" data-tab="pad">Mouse</button>
  <button data-tab="screen">Screen</button>
  <button data-tab="kb">Type</button>
  <button data-tab="media">Media</button>
  <button data-tab="hot">Hotkeys</button>
  <button data-tab="more">More</button>
</nav>

<script>
(function () {
  var PC = __PCNAME_JSON__;
  var $ = function (id) { return document.getElementById(id); };
  var each = function (list, fn) { Array.prototype.forEach.call(list, fn); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };

  // ---------- PIN ----------
  var params = new URLSearchParams(location.search);
  var pin = params.get('pin') || store.get('rm_pin') || '';
  if (params.get('pin')) { try { history.replaceState(null, '', location.pathname); } catch (e) {} }
  var blockedUntil = 0;
  function blocked() { return Date.now() < blockedUntil; }
  function askPin() {
    var p = prompt('Enter the PIN for ' + PC + ' (shown on the PC at http://localhost:' + location.port + '/pair)');
    if (p) { pin = p.trim(); }
    blockedUntil = 0;
    ping();
  }

  // ---------- Status / API ----------
  function setStatus(ok, text) {
    $('dot').className = 'dot' + (ok ? ' ok' : '');
    $('status').textContent = text;
  }
  $('hdr').addEventListener('click', askPin);
  function offline() { setStatus(false, 'Can\'t reach ' + PC + ' - same Wi-Fi? Is Remote Mouse running?'); }

  function api(path, opts) {
    opts = opts || {};
    opts.headers = Object.assign({ 'X-Pin': pin }, opts.headers || {});
    return fetch(path, opts);
  }
  function authOk(r) {
    if (r.status === 403) { blockedUntil = Infinity; setStatus(false, 'Wrong PIN - tap here to enter it'); return false; }
    if (r.status === 429) { blockedUntil = Date.now() + 60000; setStatus(false, 'Too many wrong PINs - wait 1 minute'); return false; }
    if (r.ok) { store.set('rm_pin', pin); setStatus(true, 'Connected to ' + PC); return true; }
    return false;
  }

  // ---------- Sending ----------
  var q = [], mx = 0, my = 0, sx = 0, sy = 0, ax = null, ay = null, inflight = false;
  var invert = store.get('rm_invert') === '1';
  var speed = parseFloat(store.get('rm_speed') || '1.6');
  var sspeed = parseFloat(store.get('rm_sspeed') || '4');
  $('invert').checked = invert;
  $('speed').value = speed;
  $('sspeed').value = sspeed;
  $('invert').addEventListener('change', function () { invert = this.checked; store.set('rm_invert', invert ? '1' : '0'); });
  $('speed').addEventListener('input', function () { speed = parseFloat(this.value); store.set('rm_speed', String(speed)); });
  $('sspeed').addEventListener('input', function () { sspeed = parseFloat(this.value); store.set('rm_sspeed', String(sspeed)); });

  function flushMotion() {
    var ix = Math.trunc(mx), iy = Math.trunc(my);
    if (ix || iy) { q.push({ a: 'move', dx: ix, dy: iy }); mx -= ix; my -= iy; }
    var jx = Math.trunc(sx), jy = Math.trunc(sy);
    if (jx || jy) { q.push({ a: 'scroll', dx: jx, dy: jy }); sx -= jx; sy -= jy; }
    if (ax !== null) { q.push({ a: 'abs', x: ax, y: ay }); ax = ay = null; }
  }
  function push(cmd) { flushMotion(); q.push(cmd); pump(); }

  function pump() {
    if (inflight || !q.length) return;
    if (blocked()) { q.length = 0; return; }
    inflight = true;
    var body = q.splice(0, 150);
    api('/cmd', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cmds: body }) })
      .then(authOk).catch(offline)
      .then(function () { inflight = false; pump(); });
  }
  function ping() {
    if (inflight) return;
    inflight = true;
    api('/cmd', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"cmds":[]}' })
      .then(authOk).catch(offline)
      .then(function () { inflight = false; });
  }
  setInterval(function () { flushMotion(); pump(); }, 12);
  setInterval(function () { if (!q.length && !blocked()) ping(); }, 4000);
  if (!pin) { askPin(); } else { ping(); }

  function buzz() { if (navigator.vibrate) navigator.vibrate(8); }

  // ---------- Tabs ----------
  var currentTab = 'pad';
  var tabBtns = document.querySelectorAll('nav button');
  each(tabBtns, function (b) {
    b.addEventListener('click', function () {
      currentTab = b.dataset.tab;
      each(tabBtns, function (x) { x.classList.toggle('active', x === b); });
      each(document.querySelectorAll('.tab'), function (t) {
        t.classList.toggle('active', t.id === 'tab-' + currentTab);
      });
      updateScreenLoop();
    });
  });

  // ---------- Touchpad ----------
  var pad = $('pad');
  var g = { startT: 0, moved: 0, lx: 0, ly: 0, cx: 0, cy: 0, maxF: 0, lastTapEnd: 0, dragging: false };

  function centroid(ts) {
    return { x: (ts[0].clientX + ts[1].clientX) / 2, y: (ts[0].clientY + ts[1].clientY) / 2 };
  }
  pad.addEventListener('touchstart', function (e) {
    e.preventDefault();
    var ts = e.targetTouches, n = ts.length;
    if (n === 1 && e.changedTouches.length === 1) {
      g.maxF = 1; g.moved = 0; g.startT = Date.now();
      g.lx = ts[0].clientX; g.ly = ts[0].clientY;
      if (Date.now() - g.lastTapEnd < 300 && !g.dragging) { g.dragging = true; push({ a: 'down', b: 'left' }); }
    } else if (n >= 2) {
      g.maxF = Math.max(g.maxF, n);
      var c = centroid(ts); g.cx = c.x; g.cy = c.y;
    }
  }, { passive: false });

  pad.addEventListener('touchmove', function (e) {
    e.preventDefault();
    var ts = e.targetTouches, n = ts.length;
    if (n === 1) {
      var x = ts[0].clientX, y = ts[0].clientY;
      var dx = x - g.lx, dy = y - g.ly;
      g.lx = x; g.ly = y;
      if (g.maxF >= 2) return; // a finger was just lifted from a 2-finger gesture
      g.moved += Math.abs(dx) + Math.abs(dy);
      var gain = speed * (1 + Math.min(Math.hypot(dx, dy), 30) / 30);
      mx += dx * gain; my += dy * gain;
    } else if (n >= 2) {
      var c = centroid(ts);
      var ddx = c.x - g.cx, ddy = c.y - g.cy;
      g.cx = c.x; g.cy = c.y;
      g.moved += Math.abs(ddx) + Math.abs(ddy);
      var k = invert ? -sspeed : sspeed;
      sy += ddy * k; sx += ddx * k;
    }
  }, { passive: false });

  function endTouch(e) {
    e.preventDefault();
    var ts = e.targetTouches;
    if (ts.length === 1) { g.lx = ts[0].clientX; g.ly = ts[0].clientY; }
    if (ts.length > 0) return;
    var dur = Date.now() - g.startT;
    if (g.dragging) {
      g.dragging = false; push({ a: 'up', b: 'left' });
    } else if (g.moved < 10 && dur < 250) {
      if (g.maxF === 1) { buzz(); push({ a: 'click', b: 'left' }); g.lastTapEnd = Date.now(); }
      else if (g.maxF === 2) { buzz(); push({ a: 'click', b: 'right' }); }
    }
    g.maxF = 0;
  }
  pad.addEventListener('touchend', endTouch, { passive: false });
  pad.addEventListener('touchcancel', endTouch, { passive: false });

  // ---------- Mouse buttons (press & hold works for dragging) ----------
  each(document.querySelectorAll('[data-hold]'), function (b) {
    var name = b.dataset.hold, held = false;
    b.addEventListener('pointerdown', function (e) {
      e.preventDefault(); held = true; b.setPointerCapture(e.pointerId); buzz(); push({ a: 'down', b: name });
    });
    function release() { if (held) { held = false; push({ a: 'up', b: name }); } }
    b.addEventListener('pointerup', release);
    b.addEventListener('pointercancel', release);
    b.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  });
  $('dbl').addEventListener('click', function () {
    buzz(); push({ a: 'click', b: 'left' }); push({ a: 'click', b: 'left' });
  });

  // ---------- Live screen ----------
  var scrActive = false, scrBusy = false, prevUrl = null, curUrl = null, scrDelay = 40;
  var scrImg = $('scr'), scrWrap = $('scrwrap'), cur = $('cur'), cursorF = null;
  function placeCursor() {
    if (!cursorF) return;
    cur.style.display = 'block';
    cur.style.left = (cursorF.x * 100) + '%';
    cur.style.top = (cursorF.y * 100) + '%';
  }
  scrImg.addEventListener('load', function () {
    $('scrmsg').style.display = 'none';
    placeCursor();
    if (prevUrl) { URL.revokeObjectURL(prevUrl); prevUrl = null; }
  });
  function scrLoop() {
    if (!scrActive || scrBusy) return;
    if (blocked()) { setTimeout(scrLoop, 1000); return; }
    scrBusy = true; scrDelay = 40;
    api('/screen.png?w=' + $('quality').value).then(function (r) {
      if (!authOk(r)) throw new Error('bad status');
      var c = (r.headers.get('X-Cursor') || '').split(',');
      if (c.length === 2) { cursorF = { x: parseFloat(c[0]), y: parseFloat(c[1]) }; }
      return r.blob();
    }).then(function (b) {
      prevUrl = curUrl;
      curUrl = URL.createObjectURL(b);
      scrImg.src = curUrl;
    }).catch(function () { scrDelay = 800; })
      .then(function () { scrBusy = false; if (scrActive) setTimeout(scrLoop, scrDelay); });
  }
  function updateScreenLoop() {
    var want = currentTab === 'screen' && !document.hidden;
    if (want && !scrActive) { scrActive = true; scrLoop(); }
    else if (!want) { scrActive = false; }
  }
  document.addEventListener('visibilitychange', updateScreenLoop);

  function frac(e) {
    var r = scrWrap.getBoundingClientRect();
    return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
             y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) };
  }
  var ptrDown = false;
  scrWrap.addEventListener('pointerdown', function (e) {
    e.preventDefault(); scrWrap.setPointerCapture(e.pointerId); ptrDown = true;
    var f = frac(e); ax = f.x; ay = f.y; cursorF = f; placeCursor();
  });
  scrWrap.addEventListener('pointermove', function (e) {
    if (!ptrDown) return;
    var f = frac(e); ax = f.x; ay = f.y; cursorF = f; placeCursor();
  });
  function scrUp() {
    if (!ptrDown) return;
    ptrDown = false;
    if ($('tapclick').checked) { buzz(); push({ a: 'click', b: 'left' }); } else { flushMotion(); pump(); }
  }
  scrWrap.addEventListener('pointerup', scrUp);
  scrWrap.addEventListener('pointercancel', function () { ptrDown = false; });

  // ---------- Live keyboard + sticky modifiers ----------
  var MODS = ['ctrl', 'alt', 'shift', 'win'], modState = {};
  function activeMods() { return MODS.filter(function (m) { return modState[m]; }); }
  function clearMods() {
    MODS.forEach(function (m) { modState[m] = false; });
    each(document.querySelectorAll('[data-mod]'), function (b) { b.classList.remove('on'); });
  }
  each(document.querySelectorAll('[data-mod]'), function (b) {
    b.addEventListener('click', function () {
      var m = b.dataset.mod;
      modState[m] = !modState[m];
      b.classList.toggle('on', modState[m]);
      buzz();
    });
  });

  var live = $('live'), prev = '';
  function resetLive() { live.value = ''; prev = ''; }
  live.addEventListener('input', function () {
    var cur2 = live.value, p = 0, m = Math.min(prev.length, cur2.length);
    while (p < m && prev.charCodeAt(p) === cur2.charCodeAt(p)) p++;
    var del = prev.length - p, add = cur2.slice(p);
    if (del) push({ a: 'key', k: 'backspace', n: del });
    if (add) {
      var am = activeMods();
      if (am.length && add.length === 1 && /^[a-z0-9]$/i.test(add)) {
        push({ a: 'combo', k: am.concat([add.toLowerCase()]) });
        clearMods(); resetLive();
        return;
      }
      for (var i = 0; i < add.length; i += 400) push({ a: 'text', s: add.slice(i, i + 400) });
    }
    prev = cur2;
    if (add.indexOf('\n') !== -1 || cur2.length > 120) resetLive();
  });

  // ---------- Action buttons (keys, combos, media, power, apps) ----------
  function fire(b) {
    if (b.dataset.key) {
      resetLive();
      var am = activeMods();
      if (am.length) { push({ a: 'combo', k: am.concat([b.dataset.key]) }); clearMods(); }
      else { push({ a: 'key', k: b.dataset.key }); }
    }
    else if (b.dataset.combo) { resetLive(); push({ a: 'combo', k: b.dataset.combo.split('+') }); }
    else if (b.dataset.media) { push({ a: 'media', k: b.dataset.media }); }
  }
  each(document.querySelectorAll('[data-key],[data-combo],[data-media]'), function (b) {
    var t1 = null, t2 = null;
    function stop() { clearTimeout(t1); clearInterval(t2); t1 = t2 = null; }
    b.addEventListener('pointerdown', function (e) {
      e.preventDefault(); buzz(); fire(b);
      if (b.hasAttribute('data-repeat')) {
        t1 = setTimeout(function () { t2 = setInterval(function () { fire(b); }, 90); }, 350);
      }
    });
    b.addEventListener('pointerup', stop);
    b.addEventListener('pointerleave', stop);
    b.addEventListener('pointercancel', stop);
    b.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  });

  each(document.querySelectorAll('[data-app]'), function (b) {
    b.addEventListener('click', function () { buzz(); push({ a: 'app', k: b.dataset.app }); });
  });
  var CONFIRM = { sleep: 'Put the PC to sleep?', restart: 'Restart the PC in 10 seconds?', shutdown: 'Shut down the PC in 10 seconds?' };
  each(document.querySelectorAll('[data-power]'), function (b) {
    b.addEventListener('click', function () {
      var k = b.dataset.power;
      if (CONFIRM[k] && !confirm(CONFIRM[k])) return;
      buzz(); push({ a: 'power', k: k });
    });
  });

  // ---------- Clipboard + link ----------
  $('clipSend').addEventListener('click', function () {
    var t = $('clipbox').value; if (t) { buzz(); push({ a: 'clip_set', s: t }); }
  });
  $('clipPaste').addEventListener('click', function () {
    var t = $('clipbox').value; if (t) { buzz(); push({ a: 'clip_set', s: t, paste: true }); }
  });
  $('clipGet').addEventListener('click', function () {
    if (blocked()) return;
    api('/clip').then(function (r) {
      if (!authOk(r)) throw new Error('bad status');
      return r.json();
    }).then(function (j) {
      $('clipbox').value = j.text || '';
      try {
        if (navigator.clipboard && j.text) navigator.clipboard.writeText(j.text).catch(function () {});
      } catch (e) {}
    }).catch(function () {});
  });
  function openUrl() {
    var u = $('urlbox').value.trim(); if (!u) return;
    buzz(); push({ a: 'url', s: u });
  }
  $('urlGo').addEventListener('click', openUrl);
  $('urlbox').addEventListener('keydown', function (e) { if (e.key === 'Enter') openUrl(); });
})();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# PC "Pair" page (only reachable from the PC itself)
# --------------------------------------------------------------------------
PAIR_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Remote Mouse - __NAME__</title>
<link rel="icon" href="/icon-192.png">
<style>
  :root { color-scheme: dark light; --bg:#0f1115; --panel:#181b22; --text:#e8eaf0; --muted:#8b93a7; --accent:#4f8cff; --ok:#3ddc84; }
  @media (prefers-color-scheme: light) { :root { --bg:#f3f5f9; --panel:#ffffff; --text:#1b2030; --muted:#5d667a; } }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:16px/1.45 system-ui,"Segoe UI",Roboto,sans-serif; display:flex; justify-content:center; padding:32px 16px; }
  main { width:100%; max-width:760px; }
  h1 { font-size:26px; margin:0 0 4px; }
  .sub { color:var(--muted); margin:0 0 24px; }
  .ok { color:var(--ok); font-weight:600; }
  .card { background:var(--panel); border-radius:18px; padding:24px; display:flex; gap:28px; flex-wrap:wrap; align-items:center; }
  .qr { width:240px; height:240px; flex:none; border-radius:12px; overflow:hidden; background:#fff; }
  .qr svg { width:100%; height:100%; display:block; }
  ol { margin:0; padding-left:20px; flex:1; min-width:240px; }
  li { margin:0 0 10px; }
  code { background:rgba(127,127,127,.18); padding:2px 7px; border-radius:6px; font-size:15px; word-break:break-all; }
  .pin { font-size:34px; letter-spacing:6px; font-weight:700; margin:20px 0 4px; }
  .warn { background:#4a2c12; color:#ffd7a8; border-radius:12px; padding:12px 16px; margin-bottom:16px; }
  .row { display:flex; gap:12px; align-items:center; flex-wrap:wrap; margin-top:22px; }
  label.sw { display:flex; align-items:center; gap:10px; cursor:pointer; }
  button { border:0; border-radius:12px; padding:11px 18px; font:inherit; font-weight:600; background:#3a2226; color:#ffb4b4; cursor:pointer; }
  .hint { color:var(--muted); font-size:14px; margin-top:14px; }
  .hidden { display:none; }
  #msg { color:var(--muted); font-size:14px; }
</style>
</head>
<body>
<main>
  <h1>Remote Mouse</h1>
  <p class="sub"><span class="ok">&#9679; Running</span> on <b>__NAME__</b></p>
  __WARN__
  <div class="card">
    <div class="qr">__QR__</div>
    <ol>
      <li>Connect your phone to the <b>same Wi-Fi</b> as this PC.</li>
      <li>Scan this code with your phone's camera and open the link.</li>
      <li>Add it to your home screen:<br>
        <span class="hint">Android Chrome: &#8942; menu &rarr; <i>Add to Home screen</i><br>iPhone Safari: Share &rarr; <i>Add to Home Screen</i></span></li>
    </ol>
  </div>
  <div class="pin">__PIN__</div>
  <div class="hint">PIN (the phone asks for it once if it is not in the link)</div>
  <div class="hint">Link: <code>__URL__</code></div>
  __ALT__
  <div class="row __WINDOWS__">
    <label class="sw"><input type="checkbox" id="auto" __AUTOSTART__> Start Remote Mouse when Windows starts</label>
    <span id="msg"></span>
  </div>
  <div class="row"><button id="quit">Stop Remote Mouse</button></div>
  <div class="hint">If your router gives the PC a new address later, open this page again and scan the new code.</div>
</main>
<script>
(function () {
  var msg = document.getElementById('msg');
  function admin(path, body) {
    return fetch(path, { method: 'POST', headers: { 'X-Admin': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  }
  var auto = document.getElementById('auto');
  if (auto) auto.addEventListener('change', function () {
    var want = auto.checked;
    admin('/autostart', { on: want }).then(function (r) { return r.json(); }).then(function (j) {
      if (!j.ok) throw new Error(j.error || 'failed');
      msg.textContent = want ? 'Will start with Windows.' : 'Turned off.';
    }).catch(function (e) { auto.checked = !want; msg.textContent = 'Could not change: ' + e.message; });
  });
  document.getElementById('quit').addEventListener('click', function () {
    if (!confirm('Stop Remote Mouse? Your phone will lose control until you start it again.')) return;
    admin('/quit').then(function () { document.body.innerHTML = '<main><h1>Remote Mouse stopped</h1><p class="sub">You can close this tab.</p></main>'; });
  });
})();
</script>
</body>
</html>
"""


class AppInfo:
    def __init__(self, name, pin, port, ips, windows):
        self.name, self.pin, self.port, self.ips, self.windows = name, pin, port, ips, windows

    def phone_url(self):
        return "http://%s:%d/?pin=%s" % (self.ips[0], self.port, self.pin)

    def name_url(self):
        n = self.name
        if n and all(c.isalnum() or c == "-" for c in n) and n.isascii():
            return "http://%s.local:%d/" % (n, self.port)
        return None

    def pair_url(self):
        return "http://localhost:%d/pair" % self.port


def render_pair_page(info):
    esc = htmllib.escape
    warn = ""
    if info.ips[0].startswith("127."):
        warn = '<div class="warn">No Wi-Fi / network address found. Connect this PC to your Wi-Fi, then restart Remote Mouse.</div>'
    alt = []
    for ip in info.ips[1:]:
        alt.append('<div class="hint">Other address: <code>http://%s:%d/</code></div>' % (esc(ip), info.port))
    nu = info.name_url()
    if nu:
        alt.append('<div class="hint">By name (works on many phones, and survives address changes): <code>%s</code></div>' % esc(nu))
    page = PAIR_HTML
    for key, val in (("__NAME__", esc(info.name)), ("__QR__", qr_svg(info.phone_url())),
                     ("__PIN__", esc(info.pin)), ("__URL__", esc("http://%s:%d/" % (info.ips[0], info.port))),
                     ("__ALT__", "".join(alt)), ("__WARN__", warn),
                     ("__WINDOWS__", "" if info.windows else "hidden"),
                     ("__AUTOSTART__", "checked" if startup_enabled() else "")):
        page = page.replace(key, val)
    return page.encode("utf-8")


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------
class Auth:
    """PIN check with a per-IP lockout (5 wrong guesses -> 60 s)."""

    def __init__(self, pin):
        self.pin = pin
        self.fails = {}
        self.lock = threading.Lock()

    def check(self, ip, given):
        now = time.time()
        with self.lock:
            count, until = self.fails.get(ip, (0, 0.0))
            if until > now:
                return "locked"
            if hmac.compare_digest(given.encode("utf-8"), self.pin.encode("utf-8")):
                self.fails.pop(ip, None)
                return "ok"
            count += 1
            if count >= 5:
                self.fails[ip] = (0, now + 60)
            else:
                self.fails[ip] = (count, 0.0)
            return "bad"


def make_handler(controller, auth, info):
    index_html = (INDEX_HTML
                  .replace("__PCNAME_JSON__", json.dumps(info.name).replace("<", "\\u003c"))
                  .replace("__PCNAME__", htmllib.escape(info.name))).encode("utf-8")
    manifest = json.dumps({
        "name": "Remote Mouse - " + info.name,
        "short_name": info.name[:12] or "Remote Mouse",
        "description": "Use your phone as a mouse, keyboard and screen for " + info.name,
        "start_url": "/", "scope": "/", "display": "standalone", "orientation": "any",
        "background_color": "#0f1115", "theme_color": "#0f1115",
        "icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
                  {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"}],
    }).encode("utf-8")
    icons = {"/icon-192.png": 192, "/icon-512.png": 512, "/apple-touch-icon.png": 180}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass  # keep the console quiet

        def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", headers=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _authorized(self):
            state = auth.check(self.client_address[0], self.headers.get("X-Pin", ""))
            if state == "ok":
                return True
            if state == "locked":
                self._send(429, b"too many wrong PINs")
            else:
                time.sleep(0.3)  # slow down guessing
                self._send(403, b"bad pin")
            return False

        def _is_local_admin(self):
            """Request comes from this PC *and* was addressed to localhost (blocks DNS-rebinding tricks)."""
            host = (self.headers.get("Host", "") or "").split(":")[0].lower()
            return self.client_address[0].startswith("127.") and host in ("localhost", "127.0.0.1")

        def do_GET(self):
            url = urlparse(self.path)
            path = url.path
            if path in ("/", "/index.html"):
                self._send(200, index_html, "text/html; charset=utf-8")
            elif path == "/manifest.webmanifest":
                self._send(200, manifest, "application/manifest+json")
            elif path in icons:
                self._send(200, make_icon_png(icons[path]), "image/png")
            elif path == "/pair":
                if not self._is_local_admin():
                    self._send(403, b"open this page on the PC itself: " + info.pair_url().encode())
                    return
                self._send(200, render_pair_page(info), "text/html; charset=utf-8")
            elif path == "/screen.png":
                if not self._authorized():
                    return
                try:
                    width = int(parse_qs(url.query).get("w", ["720"])[0])
                except ValueError:
                    width = 720
                try:
                    png, fx, fy = controller.screenshot(width)
                except Exception as e:
                    print("screen capture error:", e)
                    self._send(500, b"capture failed")
                    return
                self._send(200, png, "image/png", {"X-Cursor": "%.5f,%.5f" % (fx, fy)})
            elif path == "/clip":
                if not self._authorized():
                    return
                try:
                    text = controller.get_clipboard()
                except Exception as e:
                    print("clipboard error:", e)
                    text = ""
                self._send(200, json.dumps({"text": text}).encode("utf-8"), "application/json")
            else:
                self._send(404, b"not found")

        def _read_body(self, limit):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length < 0 or length > limit:
                self.close_connection = True  # body is not read, so don't reuse the connection
                self._send(413, b"too large")
                return None
            return self.rfile.read(length) if length else b""

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path == "/cmd":
                raw = self._read_body(65536)
                if raw is None or not self._authorized():
                    return
                try:
                    data = json.loads(raw.decode("utf-8")) if raw else {}
                    cmds = data.get("cmds", [])
                    if not isinstance(cmds, list):
                        raise ValueError("cmds must be a list")
                    cmds = [c for c in cmds[:200] if isinstance(c, dict)]
                except (ValueError, UnicodeDecodeError, AttributeError):
                    self._send(400, b"bad request")
                    return
                controller.handle_batch(cmds)
                self._send(200, b'{"ok":true}', "application/json")
            elif path in ("/quit", "/autostart"):
                raw = self._read_body(1024)
                if raw is None:
                    return
                # custom header = cross-site pages cannot send this without a CORS preflight
                if not self._is_local_admin() or self.headers.get("X-Admin") != "1":
                    self._send(403, b"forbidden")
                    return
                if path == "/quit":
                    self._send(200, b'{"ok":true}', "application/json")
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
                    return
                try:
                    on = bool(json.loads(raw.decode("utf-8") or "{}").get("on"))
                    if not info.windows:
                        raise OSError("only available on Windows")
                    set_startup(on)
                    self._send(200, json.dumps({"ok": True, "on": on}).encode(), "application/json")
                except (OSError, ValueError, AttributeError) as e:
                    self._send(200, json.dumps({"ok": False, "error": str(e)}).encode(), "application/json")
            else:
                self._send(404, b"not found")

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def local_ips():
    """Best guess first, then any other addresses of this PC."""
    ips = []
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # no packet is actually sent
        ips.append(s.getsockname()[0])
    except OSError:
        pass
    finally:
        s.close()
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith("127.") and ip not in ips:
                ips.append(ip)
    except OSError:
        pass
    return ips or ["127.0.0.1"]


def load_or_make_pin(explicit):
    if explicit:
        return explicit
    path = os.path.join(data_dir(), "remote_mouse_pin.txt")
    try:
        with open(path, "r", encoding="ascii") as f:
            saved = f.read().strip()
        if saved.isdigit() and len(saved) == 6:
            return saved
    except OSError:
        pass
    pin = "".join(secrets.choice("0123456789") for _ in range(6))
    try:
        with open(path, "w", encoding="ascii") as f:
            f.write(pin)
    except OSError:
        pass
    return pin


def main():
    ap = argparse.ArgumentParser(description="Remote Mouse server")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--pin", default=None, help="fixed PIN (default: random 6 digits, saved for next time)")
    ap.add_argument("--name", default=None, help="name shown on the phone (default: this PC's name)")
    ap.add_argument("--no-browser", action="store_true", help="don't open the pairing page on the PC")
    ap.add_argument("--install-startup", action="store_true", help="start Remote Mouse automatically with Windows")
    ap.add_argument("--remove-startup", action="store_true", help="stop starting with Windows")
    ap.add_argument("--dry-run", action="store_true", help="print commands instead of controlling the PC")
    args = ap.parse_args()

    if sys.stdout is None or sys.stderr is None:  # started without a console (pythonw / windowed exe)
        try:
            sys.stdout = sys.stderr = open(os.path.join(data_dir(), "remote_mouse.log"), "a",
                                           encoding="utf-8", buffering=1)
        except OSError:
            pass

    if args.install_startup or args.remove_startup:
        try:
            set_startup(args.install_startup)
            print("Remote Mouse will now start with Windows." if args.install_startup
                  else "Remote Mouse will no longer start with Windows.")
        except OSError as e:
            print("Could not change startup setting:", e)
            sys.exit(1)
        return

    windows = platform.system() == "Windows"
    if args.dry_run:
        controller = DryRunController()
    elif windows:
        controller = WindowsController()
    else:
        print("This server controls a Windows PC. Use --dry-run to test on other systems.")
        sys.exit(1)

    pin = load_or_make_pin(args.pin)
    info = AppInfo(args.name or socket.gethostname() or "PC", pin, args.port, local_ips(), windows)
    try:
        server = Server((args.host, args.port), make_handler(controller, Auth(pin), info))
    except OSError as e:
        print(f"Could not start on port {args.port}: {e}")
        print("Remote Mouse may already be running - opening its pairing page instead.")
        if not args.no_browser and not args.dry_run:
            webbrowser.open(info.pair_url())
        sys.exit(1)

    print("=" * 60)
    print(f" Remote Mouse is running on {info.name}")
    print()
    print(" Phone and PC must be on the same Wi-Fi.")
    print(f" On this PC, open:  {info.pair_url()}   (QR code to scan)")
    print(f" Or type on the phone:  http://{info.ips[0]}:{args.port}/")
    for ip in info.ips[1:]:
        print(f"   (or) http://{ip}:{args.port}/")
    nu = info.name_url()
    if nu:
        print(f"   (or by name) {nu}")
    print(f" PIN: {pin}")
    print(" Press Ctrl+C to stop.")
    print("=" * 60)
    print("If the phone cannot connect: allow Python/RemoteMouse through Windows Firewall")
    print("(Private networks) and set your Wi-Fi to the 'Private' network profile.")
    if not args.no_browser and not args.dry_run:
        try:
            webbrowser.open(info.pair_url())
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
