"""Open windows, their icons, and window actions (focus / close / minimise / maximise).

Windows only. The pure helpers (PNG encoding, alpha recovery, title cleaning) work everywhere
so they can be unit tested on any OS; everything that touches Win32 lives in WindowManager.
"""
import base64
import ctypes
import struct
import zlib

MAX_WINDOWS = 40
MAX_TITLE = 80
ICON_SIZE = 32

WINDOW_ACTIONS = ("focus", "close", "min", "max", "restore")

# Only these can be started from the phone (name -> what ShellExecute opens).
LAUNCH_APPS = {
    "chrome": "chrome",
    "edge": "msedge",
    "explorer": "explorer.exe",
    "notepad": "notepad.exe",
    "calc": "calc.exe",
    "taskmgr": "taskmgr.exe",
    "paint": "mspaint.exe",
    "settings": "ms-settings:",
    "snip": "ms-screenclip:",
}


# ---------------------------------------------------------------------------
# Pure helpers (tested on every OS)
# ---------------------------------------------------------------------------
def clean_title(text, limit=MAX_TITLE):
    cleaned = "".join(ch for ch in str(text) if ch.isprintable()).strip()
    return cleaned[:limit]


def encode_rgba_png(width, height, rgba):
    """Encode top-down RGBA bytes as a PNG (stdlib only)."""
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def rgba_from_renders(on_black, on_white):
    """Recover a transparent icon from two BGRA renders of it: one on black, one on white.

    Drawing an icon over a background gives  out = icon * a + background * (1 - a).
    So  white_render - black_render = 255 * (1 - a), which yields the alpha of every pixel,
    and the colour is black_render / a. Works for icons with an alpha channel and for old
    mask-only icons alike.
    """
    if len(on_black) != len(on_white) or len(on_black) % 4:
        raise ValueError("renders must have the same size (BGRA)")
    out = bytearray(len(on_black))
    for i in range(0, len(on_black), 4):
        b0, g0, r0 = on_black[i], on_black[i + 1], on_black[i + 2]
        diff = max(on_white[i] - b0, on_white[i + 1] - g0, on_white[i + 2] - r0)
        a = 255 - max(0, min(255, diff))
        if a == 0:
            continue  # fully transparent: leave 0,0,0,0
        if a == 255:
            out[i], out[i + 1], out[i + 2] = r0, g0, b0
        else:
            out[i] = min(255, r0 * 255 // a)
            out[i + 1] = min(255, g0 * 255 // a)
            out[i + 2] = min(255, b0 * 255 // a)
        out[i + 3] = a
    return bytes(out)


def is_taskbar_window(visible, title, ex_style, has_owner, cloaked, class_name):
    """The rules Windows uses to decide whether a window gets a taskbar button (simplified)."""
    WS_EX_TOOLWINDOW, WS_EX_APPWINDOW, WS_EX_NOACTIVATE = 0x00000080, 0x00040000, 0x08000000
    if not visible or not title or cloaked:
        return False
    if class_name in ("Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"):
        return False
    if ex_style & WS_EX_NOACTIVATE:
        return False
    if ex_style & WS_EX_APPWINDOW:
        return True
    if ex_style & WS_EX_TOOLWINDOW or has_owner:
        return False
    return True


# ---------------------------------------------------------------------------
# Win32 (Windows only)
# ---------------------------------------------------------------------------
class _BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_int32), ("biHeight", ctypes.c_int32),
                ("biPlanes", ctypes.c_uint16), ("biBitCount", ctypes.c_uint16), ("biCompression", ctypes.c_uint32),
                ("biSizeImage", ctypes.c_uint32), ("biXPelsPerMeter", ctypes.c_int32),
                ("biYPelsPerMeter", ctypes.c_int32), ("biClrUsed", ctypes.c_uint32),
                ("biClrImportant", ctypes.c_uint32)]


class _SHFILEINFOW(ctypes.Structure):
    _fields_ = [("hIcon", ctypes.c_void_p), ("iIcon", ctypes.c_int), ("dwAttributes", ctypes.c_uint32),
                ("szDisplayName", ctypes.c_wchar * 260), ("szTypeName", ctypes.c_wchar * 80)]


class WindowManager:
    """Lists the windows that have a taskbar button and acts on them. One instance per server."""

    def __init__(self):
        vp = ctypes.c_void_p
        u = self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        k = self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        g = self.gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
        s = self.shell32 = ctypes.WinDLL("shell32", use_last_error=True)
        try:
            self.dwm = ctypes.WinDLL("dwmapi", use_last_error=True)
        except OSError:
            self.dwm = None

        self._enum_proc = ctypes.WINFUNCTYPE(ctypes.c_int, vp, ctypes.c_ssize_t)

        def sig(fn, argtypes, restype):
            fn.argtypes, fn.restype = argtypes, restype

        sig(u.EnumWindows, [self._enum_proc, ctypes.c_ssize_t], ctypes.c_int)
        sig(u.IsWindowVisible, [vp], ctypes.c_int)
        sig(u.IsIconic, [vp], ctypes.c_int)
        sig(u.IsZoomed, [vp], ctypes.c_int)
        sig(u.IsWindow, [vp], ctypes.c_int)
        sig(u.GetWindowTextLengthW, [vp], ctypes.c_int)
        sig(u.GetWindowTextW, [vp, ctypes.c_wchar_p, ctypes.c_int], ctypes.c_int)
        sig(u.GetClassNameW, [vp, ctypes.c_wchar_p, ctypes.c_int], ctypes.c_int)
        sig(u.GetWindowLongW, [vp, ctypes.c_int], ctypes.c_long)
        sig(u.GetWindow, [vp, ctypes.c_uint], vp)
        sig(u.GetForegroundWindow, [], vp)
        sig(u.GetWindowThreadProcessId, [vp, ctypes.POINTER(ctypes.c_uint32)], ctypes.c_uint32)
        sig(u.ShowWindow, [vp, ctypes.c_int], ctypes.c_int)
        sig(u.SetForegroundWindow, [vp], ctypes.c_int)
        sig(u.BringWindowToTop, [vp], ctypes.c_int)
        sig(u.PostMessageW, [vp, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t], ctypes.c_int)
        sig(u.keybd_event, [ctypes.c_ubyte, ctypes.c_ubyte, ctypes.c_uint32, ctypes.c_size_t], None)
        sig(u.DrawIconEx, [vp, ctypes.c_int, ctypes.c_int, vp, ctypes.c_int, ctypes.c_int,
                           ctypes.c_uint, vp, ctypes.c_uint], ctypes.c_int)
        sig(u.DestroyIcon, [vp], ctypes.c_int)
        sig(u.GetDC, [vp], vp)
        sig(u.ReleaseDC, [vp, vp], ctypes.c_int)
        sig(k.OpenProcess, [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32], vp)
        sig(k.CloseHandle, [vp], ctypes.c_int)
        sig(k.QueryFullProcessImageNameW, [vp, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)],
            ctypes.c_int)
        sig(g.CreateCompatibleDC, [vp], vp)
        sig(g.CreateDIBSection, [vp, ctypes.POINTER(_BITMAPINFOHEADER), ctypes.c_uint, ctypes.POINTER(vp), vp,
                                 ctypes.c_uint32], vp)
        sig(g.SelectObject, [vp, vp], vp)
        sig(g.DeleteObject, [vp], ctypes.c_int)
        sig(g.DeleteDC, [vp], ctypes.c_int)
        sig(s.SHGetFileInfoW, [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.POINTER(_SHFILEINFOW), ctypes.c_uint,
                               ctypes.c_uint], ctypes.c_size_t)
        sig(s.ShellExecuteW, [vp, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p,
                              ctypes.c_int], vp)

        self._paths = {}   # icon key (exe file name, lower case) -> full exe path, only for windows we listed
        self._icons = {}   # icon key -> base64 PNG or None

    # ---- window list ----
    def _text(self, fn, hwnd, size=256):
        buf = ctypes.create_unicode_buffer(size)
        fn(hwnd, buf, size)
        return buf.value

    def _is_cloaked(self, hwnd):
        if self.dwm is None:
            return False
        value = ctypes.c_int(0)
        try:
            self.dwm.DwmGetWindowAttribute(ctypes.c_void_p(hwnd), 14, ctypes.byref(value), 4)  # DWMWA_CLOAKED
        except Exception:
            return False
        return value.value != 0

    def _exe_path(self, hwnd):
        pid = ctypes.c_uint32(0)
        self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if not pid.value:
            return ""
        handle = self.kernel32.OpenProcess(0x1000, 0, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ""
        try:
            size = ctypes.c_uint32(1024)
            buf = ctypes.create_unicode_buffer(1024)
            if self.kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                return buf.value
            return ""
        finally:
            self.kernel32.CloseHandle(handle)

    def _handles(self):
        found = []
        u = self.user32

        def callback(hwnd, _lparam):
            try:
                title = ""
                if u.IsWindowVisible(hwnd) and u.GetWindowTextLengthW(hwnd) > 0:
                    title = self._text(u.GetWindowTextW, hwnd)
                ex = u.GetWindowLongW(hwnd, -20) & 0xFFFFFFFF  # GWL_EXSTYLE
                if is_taskbar_window(bool(u.IsWindowVisible(hwnd)), title, ex, bool(u.GetWindow(hwnd, 4)),  # GW_OWNER
                                     self._is_cloaked(hwnd) if title else False,
                                     self._text(u.GetClassNameW, hwnd, 128) if title else ""):
                    found.append((hwnd, title))
            except Exception:
                pass
            return 1

        u.EnumWindows(self._enum_proc(callback), 0)
        return found

    def list_windows(self):
        """(id of the window in front or 0, [ {id, title, app, min} ]) in a stable order."""
        found = sorted(self._handles(), key=lambda item: item[0])[:MAX_WINDOWS]
        front = self.user32.GetForegroundWindow() or 0
        items, front_id = [], 0
        for hwnd, title in found:
            path = self._exe_path(hwnd)
            key = (path.replace("/", "\\").rsplit("\\", 1)[-1] or "app").lower()
            if path:
                self._paths[key] = path
            items.append({"id": int(hwnd), "title": clean_title(title), "app": key,
                          "min": bool(self.user32.IsIconic(hwnd))})
            if int(front) == int(hwnd):
                front_id = int(hwnd)
        return front_id, items

    # ---- icons ----
    def icon(self, key):
        """Base64 PNG (32x32) for an app we have listed, or None. Cached."""
        if key in self._icons:
            return self._icons[key]
        path = self._paths.get(key)
        if not path:
            return None  # never read an arbitrary path from the phone
        try:
            png = self._render_icon(path)
        except Exception:
            png = None
        value = base64.b64encode(png).decode("ascii") if png else None
        self._icons[key] = value
        return value

    def _render_icon(self, path):
        info = _SHFILEINFOW()
        if not self.shell32.SHGetFileInfoW(path, 0, ctypes.byref(info), ctypes.sizeof(info), 0x100):  # SHGFI_ICON
            return None
        hicon = info.hIcon
        if not hicon:
            return None
        n = ICON_SIZE
        header = _BITMAPINFOHEADER(ctypes.sizeof(_BITMAPINFOHEADER), n, -n, 1, 32, 0, 0, 0, 0, 0, 0)
        screen = self.user32.GetDC(None)
        dc = self.gdi32.CreateCompatibleDC(screen)
        bits = ctypes.c_void_p()
        bitmap = self.gdi32.CreateDIBSection(dc, ctypes.byref(header), 0, ctypes.byref(bits), None, 0)
        try:
            if not bitmap or not bits.value:
                return None
            old = self.gdi32.SelectObject(dc, bitmap)
            size = n * n * 4
            renders = []
            for fill in (0x00, 0xFF):
                ctypes.memset(bits.value, fill, size)
                self.user32.DrawIconEx(dc, 0, 0, hicon, n, n, 0, None, 3)  # DI_NORMAL
                renders.append(ctypes.string_at(bits.value, size))
            self.gdi32.SelectObject(dc, old)
            return encode_rgba_png(n, n, rgba_from_renders(renders[0], renders[1]))
        finally:
            if bitmap:
                self.gdi32.DeleteObject(bitmap)
            self.gdi32.DeleteDC(dc)
            self.user32.ReleaseDC(None, screen)
            self.user32.DestroyIcon(hicon)

    # ---- actions ----
    def act(self, action, hwnd):
        """Do `action` on a window, but only if it is one of the windows we list (never an arbitrary handle)."""
        if action not in WINDOW_ACTIONS:
            return False
        if int(hwnd) not in {int(h) for h, _t in self._handles()}:
            return False
        u = self.user32
        if action == "close":
            u.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE: the app may still ask to save
        elif action == "min":
            u.ShowWindow(hwnd, 6)   # SW_MINIMIZE
        elif action == "max":
            u.ShowWindow(hwnd, 3)   # SW_MAXIMIZE
        elif action == "restore":
            u.ShowWindow(hwnd, 9)   # SW_RESTORE
        elif action == "focus":
            if u.IsIconic(hwnd):
                u.ShowWindow(hwnd, 9)
            # Windows only lets the foreground process take focus; a tap of Alt lifts that limit.
            u.keybd_event(0x12, 0, 0, 0)
            u.keybd_event(0x12, 0, 0x0002, 0)
            u.BringWindowToTop(hwnd)
            u.SetForegroundWindow(hwnd)
        return True

    def launch(self, name):
        target = LAUNCH_APPS.get(name)
        if not target:
            return False
        return int(self.shell32.ShellExecuteW(None, "open", target, None, None, 1) or 0) > 32
