"""Notification-area (tray) icon so the server can live in the background without a window."""
import os
import sys


def _icon_path():
    base = getattr(sys, "_MEIPASS", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    return os.path.join(base, "assets", "icon.ico")


class Tray:
    """post(event_dict) is called from the tray thread; the window turns events into actions."""

    def __init__(self, post, name, hooks=None):
        import pystray  # imported here so the server still runs (with a window) if it is missing
        from PIL import Image

        h = hooks or {}
        phones = h.get("phones", lambda: 0)
        sharing = h.get("sharing", lambda: True)
        update_version = h.get("update_version", lambda: None)
        auto_update = h.get("auto_update", lambda: True)
        image = Image.open(_icon_path())
        image.load()

        def open_window(icon, item):
            post({"event": "ui_open"})

        def quit_app(icon, item):
            post({"event": "ui_quit"})

        def toggle_sharing(icon, item):
            if "set_sharing" in h:
                h["set_sharing"](not sharing())

        def toggle_auto(icon, item):
            if "set_auto_update" in h:
                h["set_auto_update"](not auto_update())

        def install_update(icon, item):
            if "install_update" in h:
                h["install_update"]()

        def nothing(icon, item):
            pass

        menu = pystray.Menu(
            pystray.MenuItem("Open Remote Mouse Server", open_window, default=True),
            pystray.MenuItem(lambda item: "Phones connected: %d" % phones(), nothing, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Share screen and open windows with the phone", toggle_sharing,
                             checked=lambda item: bool(sharing())),
            pystray.MenuItem(lambda item: "Install update %s now" % update_version(), install_update,
                             visible=lambda item: bool(update_version())),
            pystray.MenuItem("Update automatically", toggle_auto, checked=lambda item: bool(auto_update())),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", quit_app),
        )
        title = "Remote Mouse Server - %s%s" % (name, " (administrator)" if h.get("admin") else "")
        self._icon = pystray.Icon("RemoteMouse", image, title, menu)
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
