"""Keeps the PC program up to date.

It looks for a newer version now and then, downloads the installer itself (so Windows does not put a
"downloaded from the internet" mark on it, which is what triggers the SmartScreen warning) and runs it
quietly. With administrator rights that needs no question; without, the user starts it from the tray menu.
"""
import hashlib
import logging
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("remotex.update")

REPO = "sabbirahmed77708-sudo/remote-mouse-"
ASSET = "Remote-Mouse-Setup.exe"
CHECK_EVERY = 12 * 3600


def parse_version(text):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(x) for x in m.groups()) if m else None


def is_newer(latest, current):
    a, b = parse_version(latest), parse_version(current)
    return bool(a and b and a > b)


def tag_from_location(location):
    m = re.search(r"/releases/tag/([^/?#]+)$", location or "")
    return m.group(1) if m else None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def fetch_latest(timeout=10, opener=None):
    """(version, tag) of the newest release, or None. Uses the 'latest' page redirect (no rate limit)."""
    opener = opener or urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request("https://github.com/%s/releases/latest" % REPO,
                                 headers={"User-Agent": "Remote-Mouse-Server"})
    try:
        opener.open(req, timeout=timeout)
        return None
    except urllib.error.HTTPError as exc:
        if exc.code not in (301, 302, 303, 307, 308):
            return None
        tag = tag_from_location(exc.headers.get("Location"))
        version = ".".join(map(str, parse_version(tag))) if parse_version(tag) else None
        return (version, tag) if version else None


def asset_url(tag):
    return "https://github.com/%s/releases/download/%s/%s" % (REPO, tag, ASSET)


def download(url, dest, sha256=None, timeout=30, opener=None):
    """Downloads to [dest] (via a .part file). Raises on any problem; leaves nothing half-written behind."""
    opener = opener or urllib.request.build_opener()
    req = urllib.request.Request(url, headers={"User-Agent": "Remote-Mouse-Server"})
    part = dest + ".part"
    digest = hashlib.sha256()
    try:
        with opener.open(req, timeout=timeout) as res, open(part, "wb") as out:
            while True:
                chunk = res.read(262144)
                if not chunk:
                    break
                out.write(chunk)
                digest.update(chunk)
        if os.path.getsize(part) < 1_000_000:
            raise ValueError("downloaded file is too small to be the installer")
        if sha256 and digest.hexdigest() != sha256.lower():
            raise ValueError("checksum mismatch")
        os.replace(part, dest)
    finally:
        try:
            os.remove(part)
        except OSError:
            pass
    return dest


def launch_installer(path):
    flags = 0
    if os.name == "nt":
        flags = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    subprocess.Popen([path, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS", "/RESTARTAPP=1"],
                     close_fds=True, creationflags=flags)


class Updater:
    """Background checker. [busy]() says whether a phone is connected; [on_change]() tells the tray/window."""

    def __init__(self, current, directory, busy, elevated, on_change=None, on_install=None, auto=True,
                 fetch=fetch_latest, fetch_file=download, launch=launch_installer):
        self.current = current
        self.dir = os.path.join(directory, "updates")
        self.busy, self.elevated = busy, elevated
        self.on_change, self.on_install = on_change or (lambda: None), on_install or (lambda: None)
        self.auto = auto
        self._fetch, self._download, self._launch = fetch, fetch_file, launch
        self.version = None   # newest version found (None: up to date or unknown)
        self.ready = None     # path of the downloaded installer
        self._tried = set()
        self._last_check = 0.0
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def start(self, first_delay=45):
        threading.Thread(target=self._loop, args=(first_delay,), name="remotex-update", daemon=True).start()

    def stop(self):
        self._stop.set()

    def _loop(self, first_delay):
        if self._stop.wait(first_delay):
            return
        while not self._stop.is_set():
            try:
                if time.time() - self._last_check >= CHECK_EVERY:
                    self.check()
                self.maybe_install()
            except Exception:
                log.debug("update loop error", exc_info=True)
            self._stop.wait(60)

    def check(self):
        """Look for a newer version and download it. Returns the new version or None."""
        with self._lock:
            self._last_check = time.time()
            try:
                latest = self._fetch()
            except Exception as exc:
                log.info("update check failed: %s", exc)
                return None
            if not latest or not is_newer(latest[0], self.current):
                self.version, self.ready = None, None
                return None
            version, tag = latest
            os.makedirs(self.dir, exist_ok=True)
            dest = os.path.join(self.dir, "Remote-Mouse-Setup-%s.exe" % version)
            self.version = version
            if not os.path.exists(dest):
                try:
                    self._download(asset_url(tag), dest)
                except Exception as exc:
                    log.info("update download failed: %s", exc)
                    self.ready = None
                    self.on_change()
                    return version
            self.ready = dest
            log.info("update %s is ready", version)
        self.on_change()
        return version

    def maybe_install(self):
        """Installs by itself only when no question has to be asked and nobody is using the PC remotely."""
        if self.auto and self.ready and self.elevated() and not self.busy():
            return self.install()
        return False

    def install(self):
        path = self.ready
        if not path or not os.path.exists(path) or path in self._tried:
            return False
        self._tried.add(path)  # never loop on a broken installer
        try:
            self._launch(path)
        except Exception as exc:
            log.warning("could not start the installer: %s", exc)
            return False
        log.info("installing %s", path)
        self.on_install()
        return True
