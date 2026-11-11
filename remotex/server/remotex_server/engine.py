"""Pairing, authentication and command dispatch. Independent of the network library (see transport.py)."""
import json
import secrets
import threading
import time

from . import protocol as P
from .inputs import BUTTONS, MEDIA_VK, vk_for


def _int(value, lo, hi, default=0):
    if isinstance(value, bool):
        return default
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return default
        value = int(value)
    if not isinstance(value, int):
        return default
    return max(lo, min(hi, value))


def _clean_name(value):
    if not isinstance(value, str):
        return "Phone"
    cleaned = "".join(ch for ch in value if ch.isprintable()).strip()[:40]
    return cleaned or "Phone"


def dispatch(controller, msg):
    """Run one session command. Returns a reply dict (for ping) or None. Invalid input is ignored."""
    t = msg.get("t")
    if t == "move":
        dx, dy = _int(msg.get("dx"), -2000, 2000), _int(msg.get("dy"), -2000, 2000)
        if dx or dy:
            controller.move(dx, dy)
    elif t == "click":
        b = msg.get("b")
        if b in BUTTONS:
            controller.click(b, 2 if msg.get("n") == 2 else 1)
    elif t == "btn":
        b = msg.get("b")
        if b in BUTTONS and isinstance(msg.get("d"), bool):
            controller.button(b, msg["d"])
    elif t == "scroll":
        dx, dy = _int(msg.get("dx"), -1200, 1200), _int(msg.get("dy"), -1200, 1200)
        if dx or dy:
            controller.scroll(dx, dy)
    elif t == "text":
        s = msg.get("s")
        if isinstance(s, str) and s:
            controller.text(s[:500])
    elif t == "key":
        k = msg.get("k")
        if vk_for(k) is not None:
            controller.key(k.lower(), _int(msg.get("n"), 1, 50, 1) or 1)
    elif t == "combo":
        keys = msg.get("k")
        if isinstance(keys, list) and 0 < len(keys) <= 5 and all(vk_for(k) is not None for k in keys):
            controller.combo([k.lower() for k in keys])
    elif t == "media":
        k = msg.get("k")
        if k in MEDIA_VK:
            controller.media(k)
    elif t == "ping":
        return {"t": "pong", "ts": _int(msg.get("ts"), 0, 2 ** 53)}
    return None


class Result:
    def __init__(self, replies=None, close=None):
        self.replies = replies or []
        self.close = close  # (code, reason) or None


class Session:
    """State machine for one WebSocket connection."""

    def __init__(self, engine, peer_ip):
        self.engine = engine
        self.peer_ip = peer_ip
        self.nonce = secrets.token_hex(16)
        self.state = "new"  # new -> ready -> closed
        self.device_id = None
        self.device_name = None
        self._close_cb = None
        self._send_cb = None
        self.request_id = None
        self._lock = threading.Lock()

    @property
    def ready(self):
        return self.state == "ready"

    def hello(self):
        return {"t": "hello", "v": P.PROTOCOL_VERSION, "id": self.engine.server_id,
                "name": self.engine.name, "nonce": self.nonce}

    def set_close_callback(self, cb):
        self._close_cb = cb

    def set_send_callback(self, cb):
        self._send_cb = cb

    def push(self, message):
        """Send a message from outside the receive loop (used for the Allow answer)."""
        cb = self._send_cb
        if cb:
            cb(message)

    def request_close(self, code, reason):
        """Called by the engine (any thread) to drop this connection."""
        cb = self._close_cb
        if cb:
            cb(code, reason)

    def closed(self):
        with self._lock:
            was_ready = self.state == "ready"
            self.state = "closed"
        self.engine._request_cancelled(self)
        self.engine._session_closed(self, was_ready)

    # ---- message handling ----
    def on_text(self, raw):
        try:
            msg = json.loads(raw)
        except ValueError:
            msg = None
        if not isinstance(msg, dict):
            if self.state == "new":
                return self._fail("bad_request", "Malformed message", P.CLOSE_BAD_REQUEST)
            return Result()
        if self.state == "new":
            return self._handshake(msg)
        if self.state == "waiting":
            if msg.get("t") == "bye":
                return Result(close=(1000, "bye"))
            return Result()  # the phone is only waiting for the PC to answer
        if self.state != "ready":
            return Result()
        if msg.get("t") == "bye":
            return Result(close=(1000, "bye"))
        reply = dispatch(self.engine.controller, msg)
        return Result([reply] if reply else [])

    def _fail(self, code, text, close_code, count_failure=False):
        if count_failure:
            self.engine._record_failure(self.peer_ip)
        return Result([{"t": "error", "code": code, "msg": text}], (close_code, code))

    def _handshake(self, msg):
        eng = self.engine
        if eng._is_locked(self.peer_ip):
            return self._fail("locked", "Too many failed attempts. Try again in a minute.", P.CLOSE_LOCKED)
        t = msg.get("t")
        device_id = msg.get("device_id")
        if t not in ("pair", "auth", "request") or not P.is_hex32(device_id):
            return self._fail("bad_request", "Expected pair, auth or request", P.CLOSE_BAD_REQUEST)

        if t == "request":
            client_nonce = msg.get("nonce")
            if not P.is_hex32(client_nonce):
                return self._fail("bad_request", "Bad nonce", P.CLOSE_BAD_REQUEST)
            name = _clean_name(msg.get("device_name"))
            sas = P.sas(self.nonce, client_nonce, device_id, eng.fingerprint)
            self.state = "waiting"
            if not eng._begin_request(self, device_id, name, sas):
                self.state = "new"
                return self._fail("busy", "The PC is already asking about another phone", P.CLOSE_UNAUTHORIZED)
            return Result([{"t": "waiting", "sas": sas, "timeout": int(P.REQUEST_TIMEOUT)}])

        if t == "pair":
            client_nonce = msg.get("nonce")
            if not P.is_hex32(client_nonce):
                return self._fail("bad_request", "Bad nonce", P.CLOSE_BAD_REQUEST)
            code = eng._active_code()
            if code is None:
                return self._fail("pairing_closed", "No pairing code is active on the PC", P.CLOSE_UNAUTHORIZED)
            expected = P.pair_proof(code, self.nonce, client_nonce, device_id, eng.fingerprint)
            if not P.proofs_equal(expected, msg.get("proof")):
                eng._pairing_failed()
                return self._fail("bad_proof", "Wrong pairing code", P.CLOSE_UNAUTHORIZED, count_failure=True)
            name = _clean_name(msg.get("device_name"))
            key_hex = secrets.token_hex(32)
            proof = P.server_proof(code, self.nonce, client_nonce, device_id, eng.fingerprint)
            eng.store.add_device(device_id, name, key_hex, self.peer_ip)
            eng._pairing_succeeded()
            self._become_ready(device_id, name)
            eng._emit({"event": "paired", "device_id": device_id, "name": name, "ip": self.peer_ip})
            return Result([{"t": "paired", "device_key": key_hex, "server_proof": proof}])

        # auth
        device = eng.store.get_device(device_id)
        if device is None:
            return self._fail("unauthorized", "This device is not paired", P.CLOSE_UNAUTHORIZED, count_failure=True)
        expected = P.auth_proof(device["key"], self.nonce, device_id, eng.fingerprint)
        if not P.proofs_equal(expected, msg.get("proof")):
            return self._fail("unauthorized", "This device is not paired", P.CLOSE_UNAUTHORIZED, count_failure=True)
        eng.store.touch(device_id, self.peer_ip)
        self._become_ready(device_id, device["name"])
        return Result([{"t": "ready", "name": eng.name}])

    def _become_ready(self, device_id, name):
        self.device_id, self.device_name = device_id, name
        self.state = "ready"
        self.engine._session_ready(self)


class Engine:
    CODE_TTL = 300.0
    MAX_PAIR_ATTEMPTS = 5
    LOCK_AFTER = 8
    LOCK_WINDOW = 60.0

    def __init__(self, store, controller, fingerprint, name, clock=time.time):
        self.store = store
        self.controller = controller
        self.fingerprint = fingerprint
        self.name = name
        self.clock = clock
        self.server_id = store.server_id
        self._lock = threading.RLock()
        self._listeners = []
        self._sessions = {}   # device_id -> set(Session)
        self._failures = {}   # ip -> [timestamps]
        self._code = None
        self._code_expires = 0.0
        self._code_attempts = 0
        self._request = None  # the one pending "Allow?" question, or None
        self.rotate_code()

    # ---- events ----
    def subscribe(self, callback):
        self._listeners.append(callback)

    def _emit(self, event):
        for cb in list(self._listeners):
            try:
                cb(event)
            except Exception:
                pass

    # ---- pairing code ----
    def rotate_code(self):
        with self._lock:
            self._code = P.new_code()
            self._code_expires = self.clock() + self.CODE_TTL
            self._code_attempts = 0
            code = self._code
        self._emit({"event": "code", "code": code})
        return code

    def current_code(self):
        """(code, seconds_left). Replaces the code first if it has expired."""
        with self._lock:
            if self.clock() >= self._code_expires:
                self.rotate_code()
            return self._code, max(0, int(self._code_expires - self.clock()))

    def _active_code(self):
        with self._lock:
            if self._code is None or self.clock() >= self._code_expires:
                return None
            return self._code

    def _pairing_failed(self):
        with self._lock:
            self._code_attempts += 1
            exhausted = self._code_attempts >= self.MAX_PAIR_ATTEMPTS
        if exhausted:
            self.rotate_code()

    def _pairing_succeeded(self):
        self.rotate_code()  # single use

    def pairing_uri(self, ips, port=P.WS_PORT):
        code, _ = self.current_code()
        base = "remotex://pair?c=%s&f=%s" % (code, P.fp_to_b64(self.fingerprint))
        suffix = "" if port == P.WS_PORT else "&p=%d" % port
        chosen = []
        for ip in ips:
            trial = base + "&h=" + ",".join(chosen + [ip]) + suffix
            if len(trial.encode("utf-8")) <= P.MAX_QR_BYTES:
                chosen.append(ip)
        if not chosen:
            raise ValueError("no address fits in the QR code")
        return base + "&h=" + ",".join(chosen) + suffix

    # ---- "Allow?" pairing (no typed code) ----
    def pending_request(self):
        with self._lock:
            return dict(self._request["info"]) if self._request else None

    def _begin_request(self, session, device_id, name, sas):
        with self._lock:
            if self._request is not None:
                return False
            rid = secrets.token_hex(8)
            session.request_id = rid
            info = {"id": rid, "device_id": device_id, "name": name, "ip": session.peer_ip, "sas": sas}
            self._request = {"info": info, "session": session}
        self._emit(dict(info, event="request"))
        return True

    def _request_cancelled(self, session):
        with self._lock:
            req = self._request
            if req is None or req["session"] is not session:
                return
            self._request = None
            rid = req["info"]["id"]
        self._emit({"event": "request_end", "id": rid, "result": "cancelled"})

    def approve(self, request_id):
        """The user pressed Allow on the PC."""
        with self._lock:
            req = self._request
            if req is None or req["info"]["id"] != request_id:
                return False
            self._request = None
            info, session = req["info"], req["session"]
        if session.state != "waiting":
            return False
        key_hex = secrets.token_hex(32)
        self.store.add_device(info["device_id"], info["name"], key_hex, info["ip"])
        session._become_ready(info["device_id"], info["name"])
        session.push({"t": "approved", "device_key": key_hex})
        self._emit({"event": "request_end", "id": request_id, "result": "approved"})
        self._emit({"event": "paired", "device_id": info["device_id"], "name": info["name"], "ip": info["ip"]})
        return True

    def deny(self, request_id):
        """The user pressed Deny (or ignored it)."""
        with self._lock:
            req = self._request
            if req is None or req["info"]["id"] != request_id:
                return False
            self._request = None
            info, session = req["info"], req["session"]
        self._record_failure(info["ip"])
        session.push({"t": "error", "code": "denied", "msg": "The PC refused the connection"})
        session.request_close(P.CLOSE_UNAUTHORIZED, "denied")
        self._emit({"event": "request_end", "id": request_id, "result": "denied"})
        return True

    # ---- failure lockout ----
    def _record_failure(self, ip):
        now = self.clock()
        with self._lock:
            lst = [t for t in self._failures.get(ip, []) if now - t < self.LOCK_WINDOW]
            lst.append(now)
            self._failures[ip] = lst
        self._emit({"event": "rejected", "ip": ip})

    def _is_locked(self, ip):
        now = self.clock()
        with self._lock:
            lst = [t for t in self._failures.get(ip, []) if now - t < self.LOCK_WINDOW]
            self._failures[ip] = lst
            return len(lst) >= self.LOCK_AFTER

    # ---- sessions ----
    def new_session(self, peer_ip):
        return Session(self, peer_ip)

    def _session_ready(self, session):
        with self._lock:
            self._sessions.setdefault(session.device_id, set()).add(session)
        self._emit({"event": "connected", "device_id": session.device_id,
                    "name": session.device_name, "ip": session.peer_ip})

    def _session_closed(self, session, was_ready):
        if not was_ready:
            return
        with self._lock:
            group = self._sessions.get(session.device_id)
            if group:
                group.discard(session)
                if not group:
                    del self._sessions[session.device_id]
        self._emit({"event": "disconnected", "device_id": session.device_id, "name": session.device_name})

    def connected_device_ids(self):
        with self._lock:
            return set(self._sessions.keys())

    def kick(self, device_id):
        """Disconnect a device now (it stays paired and may reconnect)."""
        with self._lock:
            sessions = list(self._sessions.get(device_id, ()))
        for s in sessions:
            s.request_close(P.CLOSE_REMOVED, "disconnected by the PC")
        return len(sessions)

    def forget(self, device_id):
        """Un-pair a device: remove its key and disconnect it."""
        removed = self.store.remove_device(device_id)
        self.kick(device_id)
        self._emit({"event": "forgotten", "device_id": device_id})
        return removed
