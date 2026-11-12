"""Notification-area (tray) icon so the server can live in the background without a window."""
import os
import sys


def _icon_path():
    base = getattr(sys, "_MEIPASS", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    return os.path.join(base, "assets", "icon.ico")


class Tray:
    """post(event_dict) is called from the tray thread; the window turns events into actions."""

    def __init__(self, post, name):
        import pystray  # imported here so the server still runs (with a window) if it is missing
        from PIL import Image

        image = Image.open(_icon_path())
        image.load()

        def open_window(icon, item):
            post({"event": "ui_open"})

        def quit_app(icon, item):
            post({"event": "ui_quit"})

        menu = pystray.Menu(
            pystray.MenuItem("Open Remote Mouse Server", open_window, default=True),
            pystray.MenuItem("Quit", quit_app),
        )
        self._icon = pystray.Icon("RemoteMouse", image, "Remote Mouse Server - %s" % name, menu)
        self.running = False

    def start(self):
        self._icon.run_detached()
        self.running = True

    def notify(self, text, title="Remote Mouse Server"):
        try:
            self._icon.notify(text, title)
        except Exception:
            pass

    def stop(self):
        try:
            self._icon.stop()
        except Exception:
            pass
        self.running = False
