"""Small Windows helpers."""


def is_admin():
    """True when this program runs with administrator rights (then it can also control admin windows)."""
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False
