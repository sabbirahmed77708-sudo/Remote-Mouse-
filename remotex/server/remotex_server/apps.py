"""Open-window list (with real app icons) and window switching for the phone's app bar.

Only authenticated sessions can use this (see transport.py). Windows are always looked up again
by id before anything is done to them, so the phone can never act on a window that is not listed.
"""
import base64
import hashlib
import io
import logging
import os

log = logging.getLogger("remotex.apps")

MAX_APPS = 24
ICON_SIZE = 48
# 1x1 transparent PNG, used by the test source
_TINY_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


def clean_have(value):
    if not isinstance(value, list):
        return set()
    return {v for v in value[:200] if isinstance(v, str) and 0 < len(v) <= 32}


class AppSource:
    def list(self, have):
        """-> {"list": [{"id","title","exe","ic","fg"}], "icons": {icon_id: base64 png}}"""
        raise NotImplementedError

    def focus(self, window_id):
        raise NotImplementedError

    def close(self, window_id):
        raise NotImplementedError


class FakeApps(AppSource):
    """Two pretend windows. Used by tests and --dry-run-input."""

    def __init__(self, log=None):
        self.log = log or (lambda event: None)
        self.windows = [{"id": 101, "title": "Docs - Browser", "exe": "browser", "ic": "aaaa", "fg": True},
                        {"id": 102, "title": "Notes", "exe": "notes", "ic": "bbbb", "fg": False}]

    def list(self, have):
        icons = {w["ic"]: base64.b64encode(_TINY_PNG).decode() for w in self.windows if w["ic"] not in have}
        return {"list": [dict(w) for w in self.windows], "icons": icons}

    def focus(self, window_id):
        ok = any(w["id"] == window_id for w in self.windows)
        if ok:
            self.log({"op": "focus", "id": window_id})
        return ok

    def close(self, window_id):
        ok = any(w["id"] == window_id for w in self.windows)
        if ok:
            self.log({"op": "closewin", "id": window_id})
            self.windows = [w for w in self.windows if w["id"] != window_id]
        return ok


class WindowsApps(AppSource):
    def __init__(self):
        import ctypes
        from ctypes import wintypes as wt
        self.ct, self.wt = ctypes, wt
        u, g, k, s = ctypes.windll.user32, ctypes.windll.gdi32, ctypes.windll.kernel32, ctypes.windll.shell32
        self.u, self.g, self.k, self.s = u, g, k, s
        self.ENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

        u.EnumWindows.argtypes = [self.ENUMPROC, wt.LPARAM]
        u.IsWindowVisible.argtypes = [wt.HWND]
        u.IsIconic.argtypes = [wt.HWND]
        u.GetWindowTextLengthW.argtypes = [wt.HWND]
        u.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
        u.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
        u.GetWindow.argtypes = [wt.HWND, wt.UINT]
        u.GetWindow.restype = wt.HWND
        u.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
        u.GetForegroundWindow.restype = wt.HWND
        u.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
        u.SetForegroundWindow.argtypes = [wt.HWND]
        u.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
        u.SendMessageTimeoutW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM, wt.UINT, wt.UINT,
                                          ctypes.POINTER(ctypes.c_size_t)]
        u.SendMessageTimeoutW.restype = ctypes.c_ssize_t
        u.GetClassLongPtrW.argtypes = [wt.HWND, ctypes.c_int]
        u.GetClassLongPtrW.restype = ctypes.c_size_t
        u.GetDC.argtypes = [wt.HWND]
        u.GetDC.restype = wt.HDC
        u.ReleaseDC.argtypes = [wt.HWND, wt.HDC]
        u.DrawIconEx.argtypes = [wt.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                 ctypes.c_int, wt.UINT, ctypes.c_void_p, wt.UINT]
        u.DestroyIcon.argtypes = [ctypes.c_void_p]
        g.CreateCompatibleDC.argtypes = [wt.HDC]
        g.CreateCompatibleDC.restype = wt.HDC
        g.SelectObject.argtypes = [wt.HDC, ctypes.c_void_p]
        g.SelectObject.restype = ctypes.c_void_p
        g.DeleteObject.argtypes = [ctypes.c_void_p]
        g.DeleteDC.argtypes = [wt.HDC]
        g.CreateDIBSection.argtypes = [wt.HDC, ctypes.c_void_p, wt.UINT, ctypes.POINTER(ctypes.c_void_p),
                                       ctypes.c_void_p, wt.DWORD]
        g.CreateDIBSection.restype = ctypes.c_void_p
        k.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
        k.OpenProcess.restype = ctypes.c_void_p
        k.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
        k.CloseHandle.argtypes = [ctypes.c_void_p]

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [("biSize", wt.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
                        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                        ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                        ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD)]

        class SHFILEINFOW(ctypes.Structure):
            _fields_ = [("hIcon", ctypes.c_void_p), ("iIcon", ctypes.c_int), ("dwAttributes", wt.DWORD),
                        ("szDisplayName", ctypes.c_wchar * 260), ("szTypeName", ctypes.c_wchar * 80)]

        s.SHGetFileInfoW.argtypes = [wt.LPCWSTR, wt.DWORD, ctypes.POINTER(SHFILEINFOW), wt.UINT, wt.UINT]
        s.SHGetFileInfoW.restype = ctypes.c_size_t
        self.BITMAPINFOHEADER, self.SHFILEINFOW = BITMAPINFOHEADER, SHFILEINFOW
        self._icons = {}  # icon id -> base64 png
        self._me = os.getpid()

    # ---- windows ----
    def _exe(self, pid):
        ct, wt = self.ct, self.wt
        h = self.k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return ""
        try:
            buf = ct.create_unicode_buffer(1024)
            n = wt.DWORD(1024)
            if self.k.QueryFullProcessImageNameW(h, 0, buf, ct.byref(n)):
                return buf.value
        finally:
            self.k.CloseHandle(h)
        return ""

    def _cloaked(self, hwnd):
        try:
            v = self.ct.c_int(0)
            if self.ct.windll.dwmapi.DwmGetWindowAttribute(self.wt.HWND(hwnd), 14, self.ct.byref(v), 4) == 0:
                return v.value != 0
        except Exception:
            pass
        return False

    def _windows(self):
        ct, wt, u = self.ct, self.wt, self.u
        found = []
        fg = u.GetForegroundWindow() or 0

        def cb(hwnd, _):
            try:
                if not u.IsWindowVisible(hwnd) or u.GetWindow(hwnd, 4):  # GW_OWNER
                    return True
                if u.GetWindowLongW(hwnd, -20) & 0x80:  # WS_EX_TOOLWINDOW
                    return True
                n = u.GetWindowTextLengthW(hwnd)
                if n <= 0 or self._cloaked(hwnd):
                    return True
                buf = ct.create_unicode_buffer(n + 1)
                u.GetWindowTextW(hwnd, buf, n + 1)
                title = buf.value.strip()
                if not title or title == "Program Manager":
                    return True
                pid = wt.DWORD(0)
                u.GetWindowThreadProcessId(hwnd, ct.byref(pid))
                if pid.value == self._me:
                    return True
                found.append((int(hwnd), title, self._exe(pid.value), int(hwnd) == int(fg)))
            except Exception:
                pass
            return True

        u.EnumWindows(self.ENUMPROC(cb), 0)
        return found[:MAX_APPS]

    # ---- icons ----
    def _hicon(self, hwnd, exe):
        ct, u = self.ct, self.u
        res = ct.c_size_t(0)
        for kind in (1, 2, 0):  # ICON_BIG, ICON_SMALL2, ICON_SMALL
            res.value = 0
            u.SendMessageTimeoutW(hwnd, 0x7F, kind, 0, 0x2, 60, ct.byref(res))  # WM_GETICON
            if res.value:
                return res.value, False
        h = u.GetClassLongPtrW(hwnd, -14)  # GCL_HICON
        if h:
            return h, False
        if exe:
            info = self.SHFILEINFOW()
            self.s.SHGetFileInfoW(exe, 0, ct.byref(info), ct.sizeof(info), 0x100)  # SHGFI_ICON
            if info.hIcon:
                return info.hIcon, True
        return None, False

    def _png(self, hicon):
        ct, u, g = self.ct, self.u, self.g
        size = ICON_SIZE
        screen = u.GetDC(None)
        hdc = g.CreateCompatibleDC(screen)
        bmi = self.BITMAPINFOHEADER(40, size, -size, 1, 32, 0, 0, 0, 0, 0, 0)
        bits = ct.c_void_p()
        bmp = g.CreateDIBSection(hdc, ct.byref(bmi), 0, ct.byref(bits), None, 0)
        try:
            if not bmp or not bits.value:
                return None
            old = g.SelectObject(hdc, bmp)
            u.DrawIconEx(hdc, 0, 0, hicon, size, size, 0, None, 3)  # DI_NORMAL
            data = ct.string_at(bits.value, size * size * 4)
            g.SelectObject(hdc, old)
        finally:
            if bmp:
                g.DeleteObject(bmp)
            g.DeleteDC(hdc)
            u.ReleaseDC(None, screen)
        from PIL import Image, ImageChops
        img = Image.frombuffer("RGBA", (size, size), data, "raw", "BGRA", 0, 1)
        if img.split()[3].getextrema() == (0, 0):  # old icon without alpha channel
            r, g_, b, _ = img.split()
            mask = ImageChops.lighter(ImageChops.lighter(r, g_), b).point(lambda v: 255 if v else 0)
            img.putalpha(mask)
        out = io.BytesIO()
        img.save(out, "PNG", optimize=True)
        return base64.b64encode(out.getvalue()).decode()

    def _icon_for(self, hwnd, exe, icon_id):
        if icon_id in self._icons:
            return self._icons[icon_id]
        hicon, destroy = self._hicon(hwnd, exe)
        data = None
        if hicon:
            try:
                data = self._png(hicon)
            except Exception as exc:
                log.debug("icon failed: %s", exc)
            finally:
                if destroy:
                    self.u.DestroyIcon(hicon)
        if data:
            self._icons[icon_id] = data
        return data

    # ---- AppSource ----
    def list(self, have):
        apps, icons = [], {}
        for hwnd, title, exe, fg in self._windows():
            stem = os.path.splitext(os.path.basename(exe))[0] or "app"
            key = exe.lower() + ("|" + title if stem.lower() == "applicationframehost" else "")
            icon_id = hashlib.sha1(key.encode("utf-8", "replace")).hexdigest()[:10]
            if icon_id not in have and icon_id not in icons:
                data = self._icon_for(hwnd, exe, icon_id)
                if data:
                    icons[icon_id] = data
            apps.append({"id": hwnd, "title": title[:60], "exe": stem[:30], "ic": icon_id, "fg": fg})
        return {"list": apps, "icons": icons}

    def _find(self, window_id):
        return next((w for w in self._windows() if w[0] == window_id), None)

    def focus(self, window_id):
        if self._find(window_id) is None:
            return False
        u = self.u
        if u.IsIconic(window_id):
            u.ShowWindow(window_id, 9)  # SW_RESTORE
        self.ct.windll.user32.keybd_event(0x12, 0, 0, 0)  # a tap on Alt lets us take the foreground
        self.ct.windll.user32.keybd_event(0x12, 0, 2, 0)
        return bool(u.SetForegroundWindow(window_id))

    def close(self, window_id):
        if self._find(window_id) is None:
            return False
        return bool(self.u.PostMessageW(window_id, 0x10, 0, 0))  # WM_CLOSE


def default_source():
    try:
        return WindowsApps()
    except Exception:
        return None
