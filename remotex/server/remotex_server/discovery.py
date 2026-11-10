"""UDP discovery responder: answers the app's broadcast with this PC's name and port (no secrets)."""
import json
import logging
import socket
import threading
import time

from . import protocol as P

log = logging.getLogger("remotex.discovery")


def local_ips():
    """IPv4 addresses of this PC, best guess (default route) first. Never returns an empty list."""
    ips = []
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))  # documentation address: nothing is sent, it only selects a route
        ips.append(s.getsockname()[0])
    except OSError:
        pass
    finally:
        s.close()
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith("127.") and not ip.startswith("169.254.") and ip not in ips:
                ips.append(ip)
    except OSError:
        pass
    ips = [ip for ip in ips if not ip.startswith("127.") and ip != "0.0.0.0"] or ["127.0.0.1"]
    return ips


class DiscoveryResponder:
    def __init__(self, server_id, name, ws_port, port=P.DISCOVERY_PORT, bind="0.0.0.0"):
        self.server_id = server_id
        self.name = name
        self.ws_port = ws_port
        self.port = port
        self.bind = bind
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

    def start(self):
        """Returns True when listening. Discovery is optional, so a busy port is not fatal."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((self.bind, self.port))
        except OSError as exc:
            sock.close()
            log.warning("discovery disabled: %s", exc)
            return False
        sock.settimeout(0.5)
        self.port = sock.getsockname()[1]
        self._sock = sock
        self._thread = threading.Thread(target=self._run, name="remotex-discovery", daemon=True)
        self._thread.start()
        return True

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        if self._sock:
            self._sock.close()

    def _run(self):
        reply = json.dumps({"t": "remotex", "v": P.PROTOCOL_VERSION, "id": self.server_id,
                            "name": self.name, "port": self.ws_port}, separators=(",", ":")).encode("utf-8")
        window_start, count = time.monotonic(), 0
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(256)
            except socket.timeout:
                continue
            except OSError:
                break
            if data.strip() != P.DISCOVERY_PROBE:
                continue
            now = time.monotonic()
            if now - window_start > 1.0:
                window_start, count = now, 0
            count += 1
            if count > 20:  # at most 20 answers per second: no amplification / flooding
                continue
            try:
                self._sock.sendto(reply, addr)
            except OSError:
                pass
