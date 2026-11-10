"""Test helpers: an independent reference client written straight from docs/PROTOCOL.md."""
import hashlib
import hmac
import json
import os
import secrets
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from remotex_server.engine import Engine  # noqa: E402
from remotex_server.inputs import DryRunInput  # noqa: E402
from remotex_server.store import Store  # noqa: E402

FP = "cd" * 32


def _h(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).hexdigest()


def norm(code):
    return "".join(c for c in code.upper() if c.isalnum()).replace("O", "0").replace("I", "1").replace("L", "1")


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def make_engine(clock=None, directory=None):
    directory = directory or tempfile.mkdtemp(prefix="remotex-test-")
    log = []
    engine = Engine(Store(directory), DryRunInput(log.append), FP, "TEST-PC", clock=clock or FakeClock())
    events = []
    engine.subscribe(events.append)
    return engine, log, events


class RefClient:
    """Speaks the protocol exactly as the spec describes it (no code shared with the server)."""

    def __init__(self, engine, ip="192.168.1.50", device_id=None, name="Test Phone", fp_seen=None):
        self.engine = engine
        self.ip = ip
        self.device_id = device_id or secrets.token_hex(16)
        self.name = name
        self.fp_seen = fp_seen or engine.fingerprint
        self.device_key = None
        self.session = engine.new_session(ip)
        self.hello = self.session.hello()
        self.server_proof_ok = None

    def _send(self, msg):
        res = self.session.on_text(json.dumps(msg))
        return res

    def pair(self, code, client_nonce=None):
        cn = client_nonce or secrets.token_hex(16)
        sn = self.hello["nonce"]
        k = norm(code).encode()
        proof = _h(k, "remotex-pair|%s|%s|%s|%s" % (sn, cn, self.device_id, self.fp_seen))
        res = self._send({"t": "pair", "device_id": self.device_id, "device_name": self.name, "nonce": cn, "proof": proof})
        if res.replies and res.replies[0].get("t") == "paired":
            self.device_key = res.replies[0]["device_key"]
            want = _h(k, "remotex-srv|%s|%s|%s|%s" % (sn, cn, self.device_id, self.fp_seen))
            self.server_proof_ok = hmac.compare_digest(want, res.replies[0]["server_proof"])
        return res

    def auth(self, key=None):
        key = key or self.device_key
        proof = _h(bytes.fromhex(key), "remotex-auth|%s|%s|%s" % (self.hello["nonce"], self.device_id, self.fp_seen))
        return self._send({"t": "auth", "device_id": self.device_id, "proof": proof})

    def cmd(self, msg):
        return self._send(msg)
