import os
import tempfile
import unittest

from remotex_server import updater as U


class VersionTests(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(U.parse_version("remotex-v1.6.4"), (1, 6, 4))
        self.assertIsNone(U.parse_version("nothing"))
        self.assertTrue(U.is_newer("1.7.0", "1.6.4"))
        self.assertTrue(U.is_newer("1.10.0", "1.9.9"))
        self.assertFalse(U.is_newer("1.6.4", "1.6.4"))
        self.assertFalse(U.is_newer("1.6.3", "1.6.4"))
        self.assertFalse(U.is_newer(None, "1.6.4"))

    def test_tag_from_location(self):
        self.assertEqual(U.tag_from_location("https://github.com/o/r/releases/tag/remotex-v1.7.0"), "remotex-v1.7.0")
        self.assertIsNone(U.tag_from_location("https://github.com/o/r/releases"))
        self.assertIsNone(U.tag_from_location(None))

    def test_asset_url(self):
        self.assertTrue(U.asset_url("remotex-v1.7.0").endswith("/releases/download/remotex-v1.7.0/Remote-Mouse-Setup.exe"))


class UpdaterTests(unittest.TestCase):
    def make(self, latest, busy=False, elevated=True, auto=True, fail_download=False):
        self.tmp = tempfile.mkdtemp()
        self.launched, self.changes, self.installs = [], [], []

        def fake_download(url, dest, sha256=None, **kw):
            if fail_download:
                raise OSError("offline")
            with open(dest, "wb") as f:
                f.write(b"x" * 10)
            return dest

        return U.Updater("1.6.4", self.tmp, busy=lambda: busy, elevated=lambda: elevated,
                         on_change=lambda: self.changes.append(1), on_install=lambda: self.installs.append(1),
                         auto=auto, fetch=lambda: latest, fetch_file=fake_download,
                         launch=lambda p: self.launched.append(p))

    def test_up_to_date_does_nothing(self):
        u = self.make(("1.6.4", "remotex-v1.6.4"))
        self.assertIsNone(u.check())
        self.assertIsNone(u.version)
        self.assertFalse(u.maybe_install())

    def test_newer_is_downloaded_and_installed_when_idle_and_elevated(self):
        u = self.make(("1.7.0", "remotex-v1.7.0"))
        self.assertEqual(u.check(), "1.7.0")
        self.assertTrue(u.ready and os.path.exists(u.ready))
        self.assertTrue(u.maybe_install())
        self.assertEqual(len(self.launched), 1)
        self.assertEqual(self.installs, [1])
        self.assertFalse(u.install(), "the same installer is never started twice")

    def test_waits_while_a_phone_is_connected(self):
        u = self.make(("1.7.0", "remotex-v1.7.0"), busy=True)
        u.check()
        self.assertFalse(u.maybe_install())
        self.assertEqual(self.launched, [])

    def test_without_admin_rights_it_waits_for_the_user(self):
        u = self.make(("1.7.0", "remotex-v1.7.0"), elevated=False)
        u.check()
        self.assertFalse(u.maybe_install())
        self.assertTrue(u.install())  # the tray menu entry

    def test_switched_off_does_not_install_by_itself(self):
        u = self.make(("1.7.0", "remotex-v1.7.0"), auto=False)
        u.check()
        self.assertFalse(u.maybe_install())

    def test_failed_download_is_not_ready(self):
        u = self.make(("1.7.0", "remotex-v1.7.0"), fail_download=True)
        self.assertEqual(u.check(), "1.7.0")
        self.assertIsNone(u.ready)
        self.assertFalse(u.install())


class DownloadTests(unittest.TestCase):
    def test_download_checks_size_and_hash(self):
        import hashlib
        import http.server
        import threading

        body = os.urandom(2_000_000)

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = "http://127.0.0.1:%d/x.exe" % srv.server_address[1]
        tmp = tempfile.mkdtemp()
        try:
            dest = os.path.join(tmp, "a.exe")
            U.download(url, dest, sha256=hashlib.sha256(body).hexdigest())
            self.assertEqual(os.path.getsize(dest), len(body))
            bad = os.path.join(tmp, "b.exe")
            with self.assertRaises(ValueError):
                U.download(url, bad, sha256="0" * 64)
            self.assertFalse(os.path.exists(bad))
            self.assertFalse(os.path.exists(bad + ".part"))
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
