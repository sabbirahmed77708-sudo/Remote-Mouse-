"""Entry point:  python -m remotex_server   (window)   or   python -m remotex_server --headless"""
import argparse
import json
import logging
import logging.handlers
import os
import platform
import socket
import sys
import time

from . import __version__, certs, paths
from . import protocol as P
from .discovery import DiscoveryResponder, local_ips
from .engine import Engine
from .inputs import DryRunInput, WindowsInput
from .store import Store
from .transport import Transport, TransportError


def _setup_logging(directory):
    handlers = [logging.handlers.RotatingFileHandler(os.path.join(directory, "server.log"),
                                                     maxBytes=500_000, backupCount=2, encoding="utf-8")]
    if sys.stderr is not None:
        handlers.append(logging.StreamHandler(sys.stderr))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s", handlers=handlers)


def _parse(argv):
    ap = argparse.ArgumentParser(prog="remotex_server", description="RemoteX Windows server")
    ap.add_argument("--version", action="version", version="RemoteX Server " + __version__)
    ap.add_argument("--headless", action="store_true", help="no window; print the pairing link in the console")
    ap.add_argument("--minimized", action="store_true", help="same as --background (kept for old start-up shortcuts)")
    ap.add_argument("--window", action="store_true", help="open the window instead of running in the background")
    ap.add_argument("--port", type=int, default=P.WS_PORT, help="WebSocket port (default %(default)s)")
    ap.add_argument("--name", default=None, help="PC name shown on the phone (default: Windows computer name)")
    ap.add_argument("--data-dir", default=None, help="where to keep the certificate and paired devices")
    ap.add_argument("--dry-run-input", action="store_true", help="do not move the mouse; report input events (testing)")
    ap.add_argument("--json-events", action="store_true", help="print one JSON object per line for every event")
    ap.add_argument("--auto-approve-requests", action="store_true", help="TESTING ONLY: press Allow automatically")
    ap.add_argument("--gui-selftest", type=int, default=0, metavar="MS", help="open the window, close it after MS ms")
    return ap.parse_args(argv)


def main(argv=None):
    if sys.stdout is None:  # windowed exe: no console attached
        sys.stdout = open(os.devnull, "w")
    args = _parse(argv)
    directory = paths.data_dir(args.data_dir)
    _setup_logging(directory)
    log = logging.getLogger("remotex")

    def emit(event):
        if args.json_events:
            print(json.dumps(event, separators=(",", ":")), flush=True)

    if args.dry_run_input:
        controller = DryRunInput(lambda e: emit(dict(e, event="input")))
    elif platform.system() == "Windows":
        controller = WindowsInput()
    else:
        print("RemoteX Server controls a Windows PC. Use --dry-run-input to test elsewhere.", file=sys.stderr)
        return 2

    store = Store(directory)
    cert_path, key_path, fingerprint = certs.ensure_certificate(directory, store.server_id)
    name = args.name or store.display_name or socket.gethostname() or "PC"
    engine = Engine(store, controller, fingerprint, name)
    engine.subscribe(emit)
    if args.auto_approve_requests:
        engine.subscribe(lambda e: engine.approve(e["id"]) if e.get("event") == "request" else None)

    transport = Transport(engine, certs.make_ssl_context(cert_path, key_path), port=args.port)
    try:
        transport.start()
    except TransportError as exc:
        msg = "Could not start on port %d: %s\nIs RemoteX Server already running?" % (args.port, exc)
        log.error(msg)
        if not args.headless and not args.gui_selftest:
            try:
                from . import gui
                if gui.ask_running_instance_to_open():
                    return 0  # it is already running: just bring its window forward
            except Exception:
                pass
        if args.gui_selftest or not args.headless:
            try:
                import tkinter
                from tkinter import messagebox
                tkinter.Tk().withdraw()
                messagebox.showerror("RemoteX Server", msg)
            except Exception:
                print(msg, file=sys.stderr)
        else:
            print(msg, file=sys.stderr)
        return 1

    discovery = DiscoveryResponder(store.server_id, name, transport.port)
    discovery.start()
    ips = local_ips()
    log.info("RemoteX Server %s listening on %s:%d (certificate %s...)", __version__, ips[0], transport.port, fingerprint[:12])

    try:
        if args.headless:
            code, _ = engine.current_code()
            ready = {"event": "ready", "server_id": store.server_id, "name": name, "port": transport.port,
                     "fingerprint": fingerprint, "code": code, "ips": ips,
                     "uri": engine.pairing_uri(ips, transport.port)}
            if args.json_events:
                print(json.dumps(ready, separators=(",", ":")), flush=True)
            else:
                print("RemoteX Server is running on %s" % name)
                print("Pairing link: " + ready["uri"])
                print("Pairing code: " + P.format_code(code) + "  (valid 5 minutes)")
                print("Press Ctrl+C to stop.")
            while True:
                time.sleep(3600)
        else:
            from . import gui

            def report(line):  # the windowed exe has no console, so the self-test writes a file
                if args.gui_selftest:
                    with open(os.path.join(directory, "selftest.txt"), "a", encoding="utf-8") as f:
                        f.write(line + "\n")

            return gui.run(engine, name, ips, transport.port, selftest_ms=args.gui_selftest,
                           background=not args.window, report=report)
    except KeyboardInterrupt:
        pass
    finally:
        discovery.stop()
        transport.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
