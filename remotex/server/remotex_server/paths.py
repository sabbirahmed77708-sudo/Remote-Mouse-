"""Where RemoteX keeps its files (certificate, paired devices, log)."""
import os


def data_dir(override=None):
    if override:
        d = override
    else:
        base = os.environ.get("APPDATA")
        d = os.path.join(base, "RemoteX") if base else os.path.join(os.path.expanduser("~"), ".remotex")
    os.makedirs(d, exist_ok=True)
    return d
