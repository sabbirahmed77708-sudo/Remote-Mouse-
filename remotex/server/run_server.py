"""Launcher used by PyInstaller and for double-click starts."""
import sys

from remotex_server.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
