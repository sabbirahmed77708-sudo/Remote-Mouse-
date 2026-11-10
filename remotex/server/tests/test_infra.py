"""Certificates, TLS pinning, store, discovery, QR rendering, autostart, input tables."""
import ctypes
import hashlib
import json
import os
import socket
import ssl
import tempfile
import threading
import unittest

from helpers import make_engine
from remotex_server import autostart, certs, inputs, protocol as P
from remotex_server.discovery import DiscoveryResponder, local_ips
from remotex_server.qr import make_qr
from remotex_server.store import Store


class StoreTests(unittest.TestCase):
    def test_persistence_and_removal(self):
        d = tempfile.mkdtemp()
        s = Store(d)
        sid = s.server_id
        self.assertEqual(len(sid), 32)
        s.add_device("a" * 32, "Phone A", "k" * 64, "1.2.3.4")
        s2 = Store(d)
        self.assertEqual(s2.server_id, sid)
        self.assertEqual(s2.get_device("a" * 32)["name"], "Phone A")
        self.assertEqual(len(s2.list_devices()), 1)
        self.assertTrue(s2.remove_device("a" * 32))
        self.assertFalse(s2.remove_device("a" * 32))
        self.assertEqual(Store(d).list_devices(), [])

    def test_corrupt_files_are_tolerated(self):
        d = tempfile.mkdtemp()
        open(os.path.join(d, "server.json"), "w").write("{broken")
        open(os.path.join(d, "devices.json"), "w").write("[1,2]")
        s = Store(d)
        self.assertEqual(len(s.server_id), 32)
        self.assertEqual(s.list_devices(), [])


class CertTests(unittest.TestCase):
    def test_generate_reuse_and_tls_pinning(self):
        d = tempfile.mkdtemp()
        cert, key, fp = certs.ensure_certificate(d, "ab" * 16)
        self.assertEqual(len(fp), 64)
        self.assertEqual(certs.ensure_certificate(d, "ab" * 16)[2], fp, "fingerprint must be stable across runs")

        ctx = certs.make_ssl_context(cert, key)
        self.assertGreaterEqual(ctx.minimum_version, ssl.TLSVersion.TLSv1_2)
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        seen = {}

        def serve():
            conn, _ = srv.accept()
            with ctx.wrap_socket(conn, server_side=True) as tls:
                seen["data"] = tls.recv(5)
                tls.sendall(b"pong")

        t = threading.Thread(target=serve, daemon=True)
        t.start()
        cctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        cctx.check_hostname = False
        cctx.verify_mode = ssl.CERT_NONE  # we pin by fingerprint, exactly like the app
        with socket.create_connection(("127.0.0.1", port)) as raw, cctx.wrap_socket(raw) as tls:
            der = tls.getpeercert(binary_form=True)
            self.assertEqual(hashlib.sha256(der).hexdigest(), fp, "fingerprint the client sees must equal the server's")
            self.assertIn(tls.version(), ("TLSv1.2", "TLSv1.3"))
            tls.sendall(b"hello")
            self.assertEqual(tls.recv(4), b"pong")
        t.join(2)
        srv.close()
        self.assertEqual(seen["data"], b"hello")


class DiscoveryTests(unittest.TestCase):
    def test_probe_is_answered_and_junk_is_not(self):
        r = DiscoveryResponder("ab" * 16, "TEST-PC", 48766, port=0, bind="127.0.0.1")
        self.assertTrue(r.start())
        try:
            c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            c.settimeout(2)
            c.sendto(b"junk", ("127.0.0.1", r.port))
            with self.assertRaises(socket.timeout):
                c.settimeout(0.4)
                c.recvfrom(512)
            c.settimeout(2)
            c.sendto(P.DISCOVERY_PROBE, ("127.0.0.1", r.port))
            data, _ = c.recvfrom(512)
            msg = json.loads(data)
            self.assertEqual(msg, {"t": "remotex", "v": 1, "id": "ab" * 16, "name": "TEST-PC", "port": 48766})
            self.assertNotIn("key", data.decode().lower())
            c.close()
        finally:
            r.stop()

    def test_busy_port_is_not_fatal(self):
        a = DiscoveryResponder("ab" * 16, "A", 1, port=0, bind="127.0.0.1")
        self.assertTrue(a.start())
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))  # a different socket without SO_REUSEADDR on a taken port
        busy = s.getsockname()[1]
        b = DiscoveryResponder("ab" * 16, "B", 1, port=busy, bind="127.0.0.1")
        self.assertFalse(b.start())
        s.close()
        a.stop()

    def test_local_ips_never_empty(self):
        ips = local_ips()
        self.assertTrue(ips)
        self.assertTrue(all(isinstance(i, str) for i in ips))


class QrTests(unittest.TestCase):
    def test_pairing_uri_is_scannable(self):
        try:
            import cv2
            import numpy as np
        except ImportError:
            self.skipTest("opencv not installed")
        engine, _, _ = make_engine()
        uri = engine.pairing_uri(["192.168.100.200", "10.20.30.40"])
        m = make_qr(uri)
        scale, border = 8, 4
        n = len(m)
        img = np.full(((n + 2 * border) * scale,) * 2, 255, np.uint8)
        for y in range(n):
            for x in range(n):
                if m[y][x]:
                    img[(y + border) * scale:(y + border + 1) * scale, (x + border) * scale:(x + border + 1) * scale] = 0
        text = cv2.QRCodeDetector().detectAndDecode(img)[0] or cv2.QRCodeDetectorAruco().detectAndDecode(img)[0]
        self.assertEqual(text, uri)


class InputTableTests(unittest.TestCase):
    def test_key_names(self):
        for name in ("a", "Z", "0", "9", "f1", "f12", "enter", "esc", "tab", "space", "backspace", "delete",
                     "insert", "home", "end", "pgup", "pgdn", "left", "up", "right", "down",
                     "shift", "ctrl", "alt", "win"):
            self.assertIsNotNone(inputs.vk_for(name), name)
        for name in ("f13", "ab", "", "é", "power", None, 5, "\n"):
            self.assertIsNone(inputs.vk_for(name), repr(name))
        self.assertEqual(inputs.vk_for("a"), 0x41)
        self.assertEqual(inputs.vk_for("f5"), 0x74)

    def test_struct_layout_matches_win32(self):
        if ctypes.sizeof(ctypes.c_void_p) == 8:
            self.assertEqual(ctypes.sizeof(inputs.INPUT), 40)
        else:
            self.assertEqual(ctypes.sizeof(inputs.INPUT), 28)
        self.assertEqual(ctypes.sizeof(inputs.MOUSEINPUT), 32 if ctypes.sizeof(ctypes.c_void_p) == 8 else 24)

    def test_media_keys(self):
        self.assertEqual(set(inputs.MEDIA_VK), {"mute", "voldown", "volup", "next", "prev", "stop", "playpause"})


class AutostartTests(unittest.TestCase):
    def test_script_and_toggle(self):
        folder = tempfile.mkdtemp()
        self.assertFalse(autostart.is_enabled(folder))
        autostart.set_enabled(True, folder)
        self.assertTrue(autostart.is_enabled(folder))
        raw = open(os.path.join(folder, autostart.STARTUP_FILE), "rb").read()
        self.assertEqual(raw[:2], b"\xff\xfe")
        text = raw.decode("utf-16")
        self.assertIn("remotex_server", text)
        self.assertIn("--minimized", text)
        autostart.set_enabled(False, folder)
        autostart.set_enabled(False, folder)  # idempotent
        self.assertFalse(autostart.is_enabled(folder))

    def test_quotes_are_escaped(self):
        s = autostart.vbs_script('"C:\\Program Files\\x.exe" --minimized')
        self.assertIn('sh.Run """C:\\Program Files\\x.exe"" --minimized", 0, False', s)


if __name__ == "__main__":
    unittest.main()
