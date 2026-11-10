"""Mouse / keyboard injection. WindowsInput uses the Win32 SendInput API (no PyAutoGUI delay or fail-safe)."""
import ctypes
import time

# ---------------------------------------------------------------------------
# Key names (see docs/PROTOCOL.md) -> Windows virtual-key codes
# ---------------------------------------------------------------------------
VK = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "shift": 0x10, "ctrl": 0x11, "alt": 0x12,
    "esc": 0x1B, "space": 0x20, "pgup": 0x21, "pgdn": 0x22, "end": 0x23, "home": 0x24,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "insert": 0x2D, "delete": 0x2E,
    "win": 0x5B,
}
for _i in range(1, 13):
    VK["f%d" % _i] = 0x6F + _i
MEDIA_VK = {"mute": 0xAD, "voldown": 0xAE, "volup": 0xAF, "next": 0xB0, "prev": 0xB1,
            "stop": 0xB2, "playpause": 0xB3}
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B,
            0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3}
BUTTONS = ("left", "right", "middle")


def vk_for(name):
    """Virtual-key code for a protocol key name, or None if the name is not allowed."""
    if not isinstance(name, str):
        return None
    name = name.lower()
    if name in VK:
        return VK[name]
    if len(name) == 1 and name.isascii() and name.isalnum():
        return ord(name.upper())
    return None


class InputController:
    """Interface. Every argument is already validated by engine.dispatch()."""

    def move(self, dx, dy): raise NotImplementedError
    def button(self, name, down): raise NotImplementedError
    def click(self, name, count=1): raise NotImplementedError
    def scroll(self, dx, dy): raise NotImplementedError
    def text(self, s): raise NotImplementedError
    def key(self, name, repeat=1): raise NotImplementedError
    def combo(self, names): raise NotImplementedError
    def media(self, name): raise NotImplementedError


class DryRunInput(InputController):
    """Records what would have happened. Used by tests and by --dry-run-input."""

    def __init__(self, log=None):
        self.log = log or (lambda event: None)

    def move(self, dx, dy): self.log({"op": "move", "dx": dx, "dy": dy})
    def button(self, name, down): self.log({"op": "btn", "b": name, "d": down})
    def click(self, name, count=1): self.log({"op": "click", "b": name, "n": count})
    def scroll(self, dx, dy): self.log({"op": "scroll", "dx": dx, "dy": dy})
    def text(self, s): self.log({"op": "text", "s": s})
    def key(self, name, repeat=1): self.log({"op": "key", "k": name, "n": repeat})
    def combo(self, names): self.log({"op": "combo", "k": list(names)})
    def media(self, name): self.log({"op": "media", "k": name})


# ---------------------------------------------------------------------------
# Windows implementation
# ---------------------------------------------------------------------------
INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x0001, 0x0002, 0x0004
MOUSEEVENTF_MOVE, MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x0001, 0x0800, 0x1000
_MOUSE_FLAGS = {"left": (0x0002, 0x0004), "right": (0x0008, 0x0010), "middle": (0x0020, 0x0040)}


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_int32), ("dy", ctypes.c_int32), ("mouseData", ctypes.c_uint32),
                ("dwFlags", ctypes.c_uint32), ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_uint16), ("wScan", ctypes.c_uint16), ("dwFlags", ctypes.c_uint32),
                ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_uint32), ("wParamL", ctypes.c_uint16), ("wParamH", ctypes.c_uint16)]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", ctypes.c_uint32), ("u", _INPUT_UNION)]


class WindowsInput(InputController):
    def __init__(self):
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user32.SendInput.restype = ctypes.c_uint
        self.user32.MapVirtualKeyW.argtypes = [ctypes.c_uint, ctypes.c_uint]
        self.user32.MapVirtualKeyW.restype = ctypes.c_uint

    # ---- low level ----
    def _send(self, inputs):
        if not inputs:
            return
        arr = (INPUT * len(inputs))(*inputs)
        self.user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))

    @staticmethod
    def _mouse(flags, dx=0, dy=0, data=0):
        i = INPUT(type=INPUT_MOUSE)
        i.mi = MOUSEINPUT(dx, dy, data & 0xFFFFFFFF, flags, 0, 0)
        return i

    def _vk_input(self, vk, up):
        i = INPUT(type=INPUT_KEYBOARD)
        flags = (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED else 0) | (KEYEVENTF_KEYUP if up else 0)
        i.ki = KEYBDINPUT(vk, self.user32.MapVirtualKeyW(vk, 0), flags, 0, 0)
        return i

    @staticmethod
    def _unit_input(unit, up):
        i = INPUT(type=INPUT_KEYBOARD)
        i.ki = KEYBDINPUT(0, unit, KEYEVENTF_UNICODE | (KEYEVENTF_KEYUP if up else 0), 0, 0)
        return i

    # ---- mouse ----
    def move(self, dx, dy):
        self._send([self._mouse(MOUSEEVENTF_MOVE, dx, dy)])

    def button(self, name, down):
        flags = _MOUSE_FLAGS[name]
        self._send([self._mouse(flags[0] if down else flags[1])])

    def click(self, name, count=1):
        down, up = _MOUSE_FLAGS[name]
        for n in range(count):
            self._send([self._mouse(down), self._mouse(up)])
            if n + 1 < count:
                time.sleep(0.02)

    def scroll(self, dx, dy):
        batch = []
        if dy:
            batch.append(self._mouse(MOUSEEVENTF_WHEEL, 0, 0, dy))
        if dx:
            batch.append(self._mouse(MOUSEEVENTF_HWHEEL, 0, 0, dx))
        self._send(batch)

    # ---- keyboard ----
    def text(self, s):
        batch = []
        for ch in s:
            if ch == "\r":
                continue
            if ch == "\n":
                batch += [self._vk_input(VK["enter"], False), self._vk_input(VK["enter"], True)]
            elif ch == "\t":
                batch += [self._vk_input(VK["tab"], False), self._vk_input(VK["tab"], True)]
            else:
                data = ch.encode("utf-16-le", "surrogatepass")
                for k in range(0, len(data), 2):
                    unit = int.from_bytes(data[k:k + 2], "little")
                    batch += [self._unit_input(unit, False), self._unit_input(unit, True)]
        self._send(batch)

    def key(self, name, repeat=1):
        vk = vk_for(name)
        if vk is None:
            return
        batch = []
        for _ in range(repeat):
            batch += [self._vk_input(vk, False), self._vk_input(vk, True)]
        self._send(batch)

    def combo(self, names):
        vks = [vk_for(n) for n in names]
        if not vks or None in vks:
            return
        self._send([self._vk_input(v, False) for v in vks] + [self._vk_input(v, True) for v in reversed(vks)])

    def media(self, name):
        vk = MEDIA_VK.get(name)
        if vk is not None:
            self._send([self._vk_input(vk, False), self._vk_input(vk, True)])
