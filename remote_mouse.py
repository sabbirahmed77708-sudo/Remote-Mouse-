#!/usr/bin/env python3
"""
Remote Mouse - control your Windows PC from your phone's browser.

Run on the PC:   python remote_mouse.py
Then open the printed URL on your phone (same Wi-Fi). No pip packages needed.

Options:
  --port 8765     port to listen on
  --pin 123456    use a fixed PIN instead of a random one
  --dry-run       don't move anything, just print commands (for testing)
"""
import argparse
import ctypes
import hmac
import json
import platform
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --------------------------------------------------------------------------
# Windows SendInput structures (fixed-width types so they are correct on 32/64-bit)
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


# --------------------------------------------------------------------------
# Key names -> Windows virtual-key codes
# --------------------------------------------------------------------------
VK = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "shift": 0x10, "ctrl": 0x11,
    "alt": 0x12, "esc": 0x1B, "space": 0x20, "pgup": 0x21, "pgdn": 0x22,
    "end": 0x23, "home": 0x24, "left": 0x25, "up": 0x26, "right": 0x27,
    "down": 0x28, "insert": 0x2D, "delete": 0x2E, "win": 0x5B,
    "f4": 0x73, "f5": 0x74, "f11": 0x7A,
    # media keys
    "mute": 0xAD, "voldown": 0xAE, "volup": 0xAF, "next": 0xB0, "prev": 0xB1,
    "stop": 0xB2, "playpause": 0xB3,
}
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E}
MEDIA = {"mute", "voldown", "volup", "next", "prev", "stop", "playpause"}


def vk_for(name):
    name = str(name).lower()
    if name in VK:
        return VK[name]
    if len(name) == 1 and name.isalnum():
        return ord(name.upper())
    return None


def clamp_int(v, lim):
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return 0
    return max(-lim, min(lim, n))


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

    # low level (override)
    def _move(self, dx, dy): raise NotImplementedError
    def _mouse_flag(self, flag): raise NotImplementedError
    def _wheel(self, amount, horizontal): raise NotImplementedError
    def _unit(self, unit, up): raise NotImplementedError
    def _vk(self, vk, up): raise NotImplementedError

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
            vks = [vk_for(k) for k in c.get("k", [])][:5]
            if vks and None not in vks:
                for v in vks:
                    self._vk(v, False)
                for v in reversed(vks):
                    self._vk(v, True)
        elif a == "media":
            name = str(c.get("k", "")).lower()
            if name in MEDIA:
                self._tap(VK[name])

    def _type_text(self, s):
        for ch in s:
            if ch == "\r":
                continue
            if ch == "\n":
                self._tap(VK["enter"])
            elif ch == "\t":
                self._tap(VK["tab"])
            else:
                data = ch.encode("utf-16-le")
                for i in range(0, len(data), 2):
                    unit = int.from_bytes(data[i:i + 2], "little")
                    self._unit(unit, False)
                    self._unit(unit, True)


class WindowsController(Controller):
    def __init__(self):
        super().__init__()
        self.user32 = ctypes.windll.user32
        self.user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user32.SendInput.restype = ctypes.c_uint
        self.user32.MapVirtualKeyW.argtypes = [ctypes.c_uint, ctypes.c_uint]
        self.user32.MapVirtualKeyW.restype = ctypes.c_uint

    def _send(self, inp):
        self.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

    def _mouse(self, flags, dx=0, dy=0, data=0):
        inp = INPUT(type=INPUT_MOUSE)
        inp.mi = MOUSEINPUT(dx, dy, data & 0xFFFFFFFF, flags, 0, 0)
        self._send(inp)

    def _move(self, dx, dy):
        self._mouse(MOUSEEVENTF_MOVE, dx, dy)

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


class DryRunController(Controller):
    def _move(self, dx, dy): print(f"[dry] move {dx},{dy}")
    def _mouse_flag(self, flag): print(f"[dry] mouse flag {flag:#06x}")
    def _wheel(self, amount, horizontal): print(f"[dry] wheel {'H' if horizontal else 'V'} {amount}")
    def _unit(self, unit, up): print(f"[dry] unicode {unit:#06x} {'up' if up else 'down'}")
    def _vk(self, vk, up): print(f"[dry] vk {vk:#04x} {'up' if up else 'down'}")


# --------------------------------------------------------------------------
# Web UI
# --------------------------------------------------------------------------
INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#0f1115">
<title>Remote Mouse</title>
<style>
  :root { --bg:#0f1115; --panel:#181b22; --panel2:#222733; --text:#e8eaf0; --muted:#8b93a7; --accent:#4f8cff; --ok:#3ddc84; --bad:#ff5d5d; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-touch-callout:none; user-select:none; -webkit-user-select:none; }
  html, body { height:100%; margin:0; background:var(--bg); color:var(--text); font:16px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; overscroll-behavior:none; }
  body { display:flex; flex-direction:column; padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display:flex; align-items:center; gap:10px; padding:10px 16px; color:var(--muted); font-size:14px; }
  .dot { width:10px; height:10px; border-radius:50%; background:var(--bad); }
  .dot.ok { background:var(--ok); }
  main { flex:1; min-height:0; position:relative; }
  .tab { display:none; position:absolute; inset:0; padding:0 16px 12px; flex-direction:column; gap:12px; overflow:auto; }
  .tab.active { display:flex; }
  #pad { flex:1; min-height:200px; border-radius:20px; background:radial-gradient(circle at 50% 40%, #222a3b, var(--panel)); border:1px solid #2b3345; touch-action:none; display:flex; align-items:center; justify-content:center; color:#3c465c; font-size:14px; text-align:center; padding:20px; }
  .row { display:flex; gap:10px; }
  .row > * { flex:1; }
  button { border:0; border-radius:14px; background:var(--panel2); color:var(--text); font:inherit; font-weight:600; padding:16px 8px; touch-action:manipulation; }
  button:active, button.on { background:var(--accent); }
  .big { padding:26px 8px; font-size:20px; }
  .opts { display:flex; flex-direction:column; gap:10px; padding:4px 2px; color:var(--muted); font-size:14px; }
  .opts label { display:flex; align-items:center; gap:10px; }
  input[type=range] { flex:1; }
  textarea { width:100%; height:92px; resize:none; border-radius:14px; border:1px solid #2b3345; background:var(--panel); color:var(--text); font:inherit; padding:12px; user-select:text; -webkit-user-select:text; }
  textarea:focus { outline:2px solid var(--accent); }
  .hint { color:var(--muted); font-size:13px; }
  .grid4 { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
  .grid3 { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
  nav { display:flex; background:var(--panel); border-top:1px solid #2b3345; }
  nav button { flex:1; border-radius:0; background:transparent; color:var(--muted); padding:16px 8px; }
  nav button.active { color:var(--accent); }
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
    <div class="opts">
      <label>Speed <input type="range" id="speed" min="0.5" max="4" step="0.1" value="1.6"></label>
      <label><input type="checkbox" id="invert"> Invert scroll direction</label>
    </div>
  </section>

  <section class="tab" id="tab-kb">
    <textarea id="live" placeholder="Type here - it goes straight to the PC" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
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
      <button data-key="win">Win</button>
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

  <section class="tab" id="tab-short">
    <div class="hint">Windows</div>
    <div class="grid3">
      <button data-combo="win+d">Desktop</button>
      <button data-combo="win+tab">Task View</button>
      <button data-combo="alt+tab">Alt+Tab</button>
      <button data-combo="win+e">Explorer</button>
      <button data-combo="win+r">Run</button>
      <button data-combo="ctrl+shift+esc">Task Mgr</button>
      <button data-combo="win+shift+s">Screenshot</button>
      <button data-combo="win+l">Lock PC</button>
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
</main>
<nav>
  <button class="active" data-tab="pad">Mouse</button>
  <button data-tab="kb">Keyboard</button>
  <button data-tab="media">Media</button>
  <button data-tab="short">Shortcuts</button>
</nav>

<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
    del: function (k) { try { localStorage.removeItem(k); } catch (e) {} }
  };

  // ---------- PIN ----------
  var pin = new URLSearchParams(location.search).get('pin') || store.get('rm_pin') || '';
  function askPin() {
    var p = prompt('Enter the PIN shown on your PC');
    if (p) { pin = p.trim(); }
    ping();
  }

  // ---------- Status ----------
  function setStatus(ok, text) {
    $('dot').className = 'dot' + (ok ? ' ok' : '');
    $('status').textContent = text;
  }
  $('hdr').addEventListener('click', askPin);

  // ---------- Sending ----------
  var q = [], mx = 0, my = 0, sx = 0, sy = 0, inflight = false;
  var invert = store.get('rm_invert') === '1';
  var speed = parseFloat(store.get('rm_speed') || '1.6');
  $('invert').checked = invert;
  $('speed').value = speed;
  $('invert').addEventListener('change', function () { invert = this.checked; store.set('rm_invert', invert ? '1' : '0'); });
  $('speed').addEventListener('input', function () { speed = parseFloat(this.value); store.set('rm_speed', String(speed)); });

  function flushMotion() {
    var ix = Math.trunc(mx), iy = Math.trunc(my);
    if (ix || iy) { q.push({ a: 'move', dx: ix, dy: iy }); mx -= ix; my -= iy; }
    var jx = Math.trunc(sx), jy = Math.trunc(sy);
    if (jx || jy) { q.push({ a: 'scroll', dx: jx, dy: jy }); sx -= jx; sy -= jy; }
  }
  function push(cmd) { flushMotion(); q.push(cmd); pump(); }

  function post(cmds) {
    return fetch('/cmd', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Pin': pin },
      body: JSON.stringify({ cmds: cmds })
    });
  }
  function handleResp(r) {
    if (r.status === 403) { setStatus(false, 'Wrong PIN - tap here to enter it'); return; }
    if (r.ok) { store.set('rm_pin', pin); setStatus(true, 'Connected'); }
  }
  function pump() {
    if (inflight || !q.length) return;
    inflight = true;
    var body = q.splice(0, q.length);
    post(body).then(handleResp).catch(function () { setStatus(false, 'Offline - is the PC server running?'); })
      .then(function () { inflight = false; pump(); });
  }
  function ping() {
    if (inflight) return;
    inflight = true;
    post([]).then(handleResp).catch(function () { setStatus(false, 'Offline - is the PC server running?'); })
      .then(function () { inflight = false; });
  }
  setInterval(function () { flushMotion(); pump(); }, 12);
  setInterval(function () { if (!q.length) ping(); }, 4000);
  if (!pin) { askPin(); } else { ping(); }

  function buzz() { if (navigator.vibrate) navigator.vibrate(8); }

  // ---------- Tabs ----------
  var tabBtns = document.querySelectorAll('nav button');
  Array.prototype.forEach.call(tabBtns, function (b) {
    b.addEventListener('click', function () {
      Array.prototype.forEach.call(tabBtns, function (x) { x.classList.toggle('active', x === b); });
      Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (t) {
        t.classList.toggle('active', t.id === 'tab-' + b.dataset.tab);
      });
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
      var k = invert ? -4 : 4;
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
  Array.prototype.forEach.call(document.querySelectorAll('[data-hold]'), function (b) {
    var name = b.dataset.hold, held = false;
    b.addEventListener('pointerdown', function (e) {
      e.preventDefault(); held = true; b.setPointerCapture(e.pointerId); buzz(); push({ a: 'down', b: name });
    });
    function release() { if (held) { held = false; push({ a: 'up', b: name }); } }
    b.addEventListener('pointerup', release);
    b.addEventListener('pointercancel', release);
    b.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  });

  // ---------- Live keyboard ----------
  var live = $('live'), prev = '';
  function resetLive() { live.value = ''; prev = ''; }
  live.addEventListener('input', function () {
    var cur = live.value, p = 0, m = Math.min(prev.length, cur.length);
    while (p < m && prev.charCodeAt(p) === cur.charCodeAt(p)) p++;
    var del = prev.length - p, add = cur.slice(p);
    if (del) push({ a: 'key', k: 'backspace', n: del });
    if (add) push({ a: 'text', s: add });
    prev = cur;
    if (add.indexOf('\n') !== -1 || cur.length > 120) resetLive();
  });

  // ---------- Action buttons (keys, combos, media) with hold-to-repeat ----------
  function fire(b) {
    if (b.dataset.key) { resetLive(); push({ a: 'key', k: b.dataset.key }); }
    else if (b.dataset.combo) { resetLive(); push({ a: 'combo', k: b.dataset.combo.split('+') }); }
    else if (b.dataset.media) { push({ a: 'media', k: b.dataset.media }); }
  }
  Array.prototype.forEach.call(document.querySelectorAll('[data-key],[data-combo],[data-media]'), function (b) {
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
})();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------
def make_handler(controller, pin):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass  # keep the console quiet

        def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                self._send(200, INDEX_HTML.encode("utf-8"), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found")

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/cmd":
                self._send(404, b"not found")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length < 0 or length > 65536:
                self._send(413, b"too large")
                return
            raw = self.rfile.read(length) if length else b""
            given = self.headers.get("X-Pin", "")
            if not hmac.compare_digest(given.encode("utf-8"), pin.encode("utf-8")):
                time.sleep(0.4)  # slow down PIN guessing
                self._send(403, b"bad pin")
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

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # no packet is actually sent
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description="Remote Mouse server")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--pin", default=None, help="fixed PIN (default: random 6 digits)")
    ap.add_argument("--dry-run", action="store_true", help="print commands instead of controlling the PC")
    args = ap.parse_args()

    if args.dry_run:
        controller = DryRunController()
    elif platform.system() == "Windows":
        controller = WindowsController()
    else:
        print("This server controls a Windows PC. Use --dry-run to test on other systems.")
        sys.exit(1)

    pin = args.pin or "".join(secrets.choice("0123456789") for _ in range(6))
    server = Server((args.host, args.port), make_handler(controller, pin))

    url = f"http://{local_ip()}:{args.port}/?pin={pin}"
    print("=" * 60)
    print(" Remote Mouse is running")
    print()
    print(" Open this on your phone (same Wi-Fi):")
    print(f"   {url}")
    print()
    print(f" PIN: {pin}")
    print(" Press Ctrl+C to stop.")
    print("=" * 60)
    print("If it does not load, allow Python through Windows Firewall (Private networks).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
