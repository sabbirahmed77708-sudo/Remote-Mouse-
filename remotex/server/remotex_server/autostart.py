"""Optional 'start with Windows' (a hidden launcher in the user's Startup folder; no admin rights needed)."""
import os
import sys

STARTUP_FILE = "RemoteXServer.vbs"


def startup_dir():
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return None
    return os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup")


def startup_command():
    if getattr(sys, "frozen", False):
        return '"%s" --minimized' % sys.executable
    exe = sys.executable
    base, name = os.path.split(exe)
    if name.lower() == "python.exe" and os.path.exists(os.path.join(base, "pythonw.exe")):
        exe = os.path.join(base, "pythonw.exe")  # no console window
    return '"%s" -m remotex_server --minimized' % exe


def vbs_script(cmd, workdir=None):
    lines = ['Set sh = CreateObject("WScript.Shell")']
    if workdir:
        lines.append('sh.CurrentDirectory = "%s"' % workdir.replace('"', '""'))
    lines.append('sh.Run "%s", 0, False' % cmd.replace('"', '""'))
    return "\r\n".join(lines) + "\r\n"


def is_enabled(folder=None):
    folder = folder or startup_dir()
    return bool(folder) and os.path.exists(os.path.join(folder, STARTUP_FILE))


def set_enabled(enabled, folder=None):
    folder = folder or startup_dir()
    if not folder:
        raise OSError("Windows startup folder not found")
    path = os.path.join(folder, STARTUP_FILE)
    if enabled:
        os.makedirs(folder, exist_ok=True)
        workdir = None if getattr(sys, "frozen", False) else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(path, "w", encoding="utf-16", newline="") as f:  # UTF-16 with BOM: safe for any user name
            f.write(vbs_script(startup_command(), workdir))
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
