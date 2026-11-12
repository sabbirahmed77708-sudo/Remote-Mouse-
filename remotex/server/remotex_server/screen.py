"""Live screen preview: grabs the desktop and encodes small JPEG frames for the phone.

Only sessions that finished pairing/authentication can ask for frames (see transport.py).
"""
import io
import logging

log = logging.getLogger("remotex.screen")

MIN_WIDTH, MAX_WIDTH = 240, 1280
MIN_QUALITY, MAX_QUALITY = 20, 80


def clamp_options(width, quality):
    def num(v, lo, hi, default):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
            return default
        return int(max(lo, min(hi, v)))
    return num(width, MIN_WIDTH, MAX_WIDTH, 640), num(quality, MIN_QUALITY, MAX_QUALITY, 45)


def encode(image, width, quality, cursor=None):
    """PIL image -> JPEG bytes, scaled to [width] pixels wide. [cursor] is (x, y) in 0..1 or None."""
    from PIL import ImageDraw
    image = image.convert("RGB")
    w, h = image.size
    if w > width:
        image = image.resize((width, max(1, round(h * width / w))))
    if cursor is not None:
        cx, cy = cursor[0] * image.size[0], cursor[1] * image.size[1]
        s = max(8, image.size[0] // 60)
        pts = [(cx, cy), (cx, cy + s * 1.6), (cx + s * 0.45, cy + s * 1.2),
               (cx + s * 0.8, cy + s * 1.9), (cx + s * 1.05, cy + s * 1.75),
               (cx + s * 0.7, cy + s * 1.1), (cx + s * 1.2, cy + s * 1.1)]
        draw = ImageDraw.Draw(image)
        draw.polygon(pts, fill=(255, 255, 255), outline=(0, 0, 0))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=quality, optimize=False)
    return out.getvalue()


class ScreenSource:
    """Interface: grab(width, quality) -> JPEG bytes, or None when nothing could be captured."""

    def grab(self, width, quality):
        raise NotImplementedError


class FakeScreen(ScreenSource):
    """A moving gradient. Used by tests and --dry-run-input."""

    def __init__(self):
        self.n = 0

    def grab(self, width, quality):
        self.n += 1
        try:
            from PIL import Image
        except ImportError:  # CI on Linux has no Pillow: any bytes will do for a protocol test
            return b"\xff\xd8fake-frame-%d\xff\xd9" % self.n
        c = (self.n * 7) % 256
        return encode(Image.new("RGB", (width, width * 9 // 16), (c, 80, 160)), width, quality)


class WindowsScreen(ScreenSource):
    def __init__(self):
        import ctypes
        self._user32 = ctypes.windll.user32
        self._ctypes = ctypes

    def _cursor(self):
        ctypes = self._ctypes

        class POINT(ctypes.Structure):
            _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
        p = POINT()
        if not self._user32.GetCursorPos(ctypes.byref(p)):
            return None
        sw, sh = self._user32.GetSystemMetrics(0), self._user32.GetSystemMetrics(1)
        if sw <= 0 or sh <= 0:
            return None
        return max(0.0, min(1.0, p.x / sw)), max(0.0, min(1.0, p.y / sh))

    def grab(self, width, quality):
        try:
            from PIL import ImageGrab
            image = ImageGrab.grab()
            return encode(image, width, quality, self._cursor())
        except Exception as exc:  # secure desktop (UAC), locked screen, ...
            log.debug("screen grab failed: %s", exc)
            return None


def default_source():
    try:
        return WindowsScreen()
    except Exception:
        return None
