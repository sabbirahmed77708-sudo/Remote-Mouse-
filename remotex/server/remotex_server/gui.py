"""Desktop window: status, QR code for pairing, paired devices (disconnect / remove)."""
import os
import queue
import socket
import sys
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk

from . import __version__, autostart
from . import protocol as P
from .discovery import local_ips
from .qr import make_qr

BG, CARD, CARD2 = "#0f1115", "#181b22", "#222733"
TEXT, MUTED, ACCENT, OK, BAD = "#e8eaf0", "#8b93a7", "#4f8cff", "#3ddc84", "#ff5d5d"


def _resource(name):
    base = getattr(sys, "_MEIPASS", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    return os.path.join(base, "assets", name)


class ServerWindow:
    def __init__(self, root, engine, name, ips, port, minimized=False, background=False):
        self.root, self.engine, self.name, self.port = root, engine, name, port
        self.background = background
        self.tray = None
        self.allow = None  # (request id, Toplevel)
        self.ips = ips
        self.events = queue.Queue()
        self.shown_code = None
        self.shown_ip = None
        self.toast_until = 0.0
        engine.subscribe(self.events.put)

        root.title("RemoteX Server")
        root.configure(bg=BG)
        root.geometry("900x600")
        root.minsize(820, 560)
        try:
            root.iconbitmap(_resource("icon.ico"))
        except Exception:
            pass
        self._style()
        self._build()
        root.protocol("WM_DELETE_WINDOW", self._on_close)
        if minimized:
            root.iconify()
        self._refresh_devices()
        self._tick()
        self._poll()

    # ---- look ----
    def _style(self):
        s = ttk.Style(self.root)
        s.theme_use("clam")
        s.configure(".", background=BG, foreground=TEXT, fieldbackground=CARD2, font=("Segoe UI", 10))
        s.configure("Card.TFrame", background=CARD)
        s.configure("Card.TLabel", background=CARD, foreground=TEXT)
        s.configure("Muted.TLabel", background=CARD, foreground=MUTED)
        s.configure("Title.TLabel", background=BG, foreground=TEXT, font=("Segoe UI", 20, "bold"))
        s.configure("Status.TLabel", background=BG, foreground=MUTED, font=("Segoe UI", 11))
        s.configure("Code.TLabel", background=CARD, foreground=TEXT, font=("Consolas", 22, "bold"))
        s.configure("H.TLabel", background=CARD, foreground=TEXT, font=("Segoe UI", 12, "bold"))
        s.configure("TButton", background=CARD2, foreground=TEXT, borderwidth=0, padding=(14, 8))
        s.map("TButton", background=[("active", ACCENT), ("disabled", CARD)])
        s.configure("Danger.TButton", background="#3a2226", foreground="#ffb4b4")
        s.map("Danger.TButton", background=[("active", "#c0392b"), ("disabled", CARD)])
        s.configure("TCheckbutton", background=CARD, foreground=TEXT)
        s.configure("Treeview", background=CARD2, fieldbackground=CARD2, foreground=TEXT, rowheight=30, borderwidth=0)
        s.configure("Treeview.Heading", background=CARD, foreground=MUTED, borderwidth=0)
        s.map("Treeview", background=[("selected", ACCENT)])
        s.configure("TCombobox", fieldbackground=CARD2, background=CARD2, foreground=TEXT, arrowcolor=TEXT)

    def _build(self):
        root = self.root
        root.columnconfigure(0, weight=1)
        root.rowconfigure(1, weight=1)

        head = tk.Frame(root, bg=BG)
        head.grid(row=0, column=0, sticky="ew", padx=24, pady=(20, 8))
        ttk.Label(head, text="RemoteX Server", style="Title.TLabel").pack(side="left")
        self.status_label = ttk.Label(head, text="", style="Status.TLabel")
        self.status_label.pack(side="right")
        self.dot = tk.Canvas(head, width=14, height=14, bg=BG, highlightthickness=0)
        self.dot.pack(side="right", padx=(0, 8))
        self.dot_item = self.dot.create_oval(2, 2, 12, 12, fill=OK, outline="")

        body = tk.Frame(root, bg=BG)
        body.grid(row=1, column=0, sticky="nsew", padx=24, pady=8)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        # -- left: pairing card
        left = ttk.Frame(body, style="Card.TFrame", padding=20)
        left.grid(row=0, column=0, sticky="ns", padx=(0, 16))
        ttk.Label(left, text="Pair a phone", style="H.TLabel").pack(anchor="w")
        ttk.Label(left, text="Open RemoteX on your phone and tap\nthis PC - or scan this code.", style="Muted.TLabel").pack(anchor="w", pady=(2, 12))
        self.qr_canvas = tk.Canvas(left, width=260, height=260, bg="white", highlightthickness=0)
        self.qr_canvas.pack()
        self.code_label = ttk.Label(left, text="", style="Code.TLabel")
        self.code_label.pack(pady=(14, 0))
        ttk.Label(left, text="or type this code in the app", style="Muted.TLabel").pack()
        self.expiry_label = ttk.Label(left, text="", style="Muted.TLabel")
        self.expiry_label.pack(pady=(6, 8))
        ttk.Button(left, text="New code", command=self._new_code).pack()

        # -- right: PC + devices
        right = ttk.Frame(body, style="Card.TFrame", padding=20)
        right.grid(row=0, column=1, sticky="nsew")
        right.columnconfigure(0, weight=1)
        right.rowconfigure(4, weight=1)
        ttk.Label(right, text="This PC", style="H.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(right, text=self.name, style="Card.TLabel", font=("Segoe UI", 16)).grid(row=1, column=0, sticky="w")
        addr = ttk.Frame(right, style="Card.TFrame")
        addr.grid(row=2, column=0, sticky="ew", pady=(8, 16))
        ttk.Label(addr, text="Address for your phone:", style="Muted.TLabel").pack(side="left")
        self.ip_var = tk.StringVar(value=self.ips[0])
        self.ip_box = ttk.Combobox(addr, textvariable=self.ip_var, values=self.ips, state="readonly", width=18)
        self.ip_box.pack(side="left", padx=8)
        self.ip_box.bind("<<ComboboxSelected>>", lambda _e: self._tick(force=True))
        ttk.Label(addr, text=":%d" % self.port, style="Muted.TLabel").pack(side="left")

        ttk.Label(right, text="Paired phones", style="H.TLabel").grid(row=3, column=0, sticky="w")
        cols = ("name", "state", "seen")
        self.tree = ttk.Treeview(right, columns=cols, show="headings", selectmode="browse", height=7)
        for col, title, width in (("name", "Phone", 220), ("state", "Status", 110), ("seen", "Last seen", 170)):
            self.tree.heading(col, text=title)
            self.tree.column(col, width=width, anchor="w")
        self.tree.grid(row=4, column=0, sticky="nsew", pady=(6, 8))
        self.tree.bind("<<TreeviewSelect>>", lambda _e: self._update_buttons())
        btns = ttk.Frame(right, style="Card.TFrame")
        btns.grid(row=5, column=0, sticky="w")
        self.kick_btn = ttk.Button(btns, text="Disconnect", command=self._kick, state="disabled")
        self.kick_btn.pack(side="left")
        self.forget_btn = ttk.Button(btns, text="Remove phone", style="Danger.TButton", command=self._forget, state="disabled")
        self.forget_btn.pack(side="left", padx=8)

        foot = tk.Frame(root, bg=BG)
        foot.grid(row=2, column=0, sticky="ew", padx=24, pady=(8, 16))
        self.auto_var = tk.BooleanVar(value=autostart.is_enabled())
        chk = ttk.Checkbutton(foot, text="Start RemoteX Server when Windows starts", variable=self.auto_var, command=self._toggle_autostart)
        chk.configure(style="TCheckbutton")
        chk.pack(side="left")
        tk.Label(foot, text="Phone and PC must be on the same Wi-Fi.  v%s" % __version__, bg=BG, fg=MUTED).pack(side="right")

    # ---- actions ----
    def _new_code(self):
        self.engine.rotate_code()
        self._tick(force=True)

    def _selected(self):
        sel = self.tree.selection()
        return sel[0] if sel else None

    def _kick(self):
        dev = self._selected()
        if dev and not self.engine.kick(dev):
            self._toast("That phone is not connected right now.")

    def _forget(self):
        dev = self._selected()
        if not dev:
            return
        d = self.engine.store.get_device(dev)
        label = d["name"] if d else "this phone"
        if messagebox.askyesno("Remove phone", "Remove %s?\n\nIt will be disconnected and must be paired again." % label):
            self.engine.forget(dev)
            self._refresh_devices()

    def _toggle_autostart(self):
        try:
            autostart.set_enabled(self.auto_var.get())
        except OSError as exc:
            self.auto_var.set(not self.auto_var.get())
            messagebox.showerror("Start with Windows", "Could not change the setting:\n%s" % exc)

    def _on_close(self):
        if self.background:
            self.root.withdraw()  # keep running in the background (tray icon)
            return
        self._quit()

    def _quit(self):
        if self.engine.connected_device_ids():
            if not messagebox.askyesno("Quit RemoteX Server", "A phone is connected. Quit and disconnect it?"):
                return
        if self.tray:
            self.tray.stop()
        self.root.destroy()

    def show(self):
        self.root.deiconify()
        self.root.lift()
        try:
            self.root.focus_force()
        except tk.TclError:
            pass

    # ---- "Allow this phone?" prompt ----
    def _show_allow(self, ev):
        self._close_allow()
        top = tk.Toplevel(self.root)
        top.title("RemoteX - Allow this phone?")
        top.configure(bg=CARD)
        top.attributes("-topmost", True)
        top.resizable(False, False)
        try:
            top.iconbitmap(_resource("icon.ico"))
        except Exception:
            pass
        rid = ev["id"]
        tk.Label(top, text="Allow this phone to control this PC?", bg=CARD, fg=TEXT, font=("Segoe UI", 14, "bold")).pack(padx=28, pady=(22, 4))
        tk.Label(top, text="%s  (%s)" % (ev.get("name", "Phone"), ev.get("ip", "")), bg=CARD, fg=MUTED, font=("Segoe UI", 10)).pack()
        sas = ev.get("sas", "")
        tk.Label(top, text="%s %s" % (sas[:3], sas[3:]), bg=CARD, fg=ACCENT, font=("Consolas", 30, "bold")).pack(pady=(14, 2))
        tk.Label(top, text="Press Allow only if the phone shows the same number.", bg=CARD, fg=TEXT, font=("Segoe UI", 10)).pack()
        left = tk.Label(top, text="", bg=CARD, fg=MUTED, font=("Segoe UI", 9))
        left.pack(pady=(6, 10))
        row = tk.Frame(top, bg=CARD)
        row.pack(pady=(0, 20))
        ttk.Button(row, text="Allow", command=lambda: self._answer(rid, True)).pack(side="left", padx=6)
        ttk.Button(row, text="Deny", style="Danger.TButton", command=lambda: self._answer(rid, False)).pack(side="left", padx=6)
        top.protocol("WM_DELETE_WINDOW", lambda: self._answer(rid, False))
        top.update_idletasks()
        w, h = top.winfo_reqwidth(), top.winfo_reqheight()
        top.geometry("+%d+%d" % ((top.winfo_screenwidth() - w) // 2, (top.winfo_screenheight() - h) // 3))
        self.allow = (rid, top)
        try:
            import winsound
            winsound.MessageBeep()
        except Exception:
            pass
        deadline = time.time() + P.REQUEST_TIMEOUT

        def countdown():
            if not self.allow or self.allow[0] != rid:
                return
            remaining = int(deadline - time.time())
            if remaining <= 0:
                self._answer(rid, False)
                return
            left.configure(text="Asking again is possible after this closes (%ds)" % remaining)
            top.after(1000, countdown)
        countdown()

    def _answer(self, rid, allowed):
        if allowed:
            self.engine.approve(rid)
        else:
            self.engine.deny(rid)
        self._close_allow(rid)

    def _close_allow(self, rid=None):
        if self.allow and (rid is None or self.allow[0] == rid):
            try:
                self.allow[1].destroy()
            except tk.TclError:
                pass
            self.allow = None

    # ---- refresh ----
    def _toast(self, text, seconds=6):
        self.toast_text = text
        self.toast_until = time.time() + seconds
        self._update_status()

    def _update_status(self):
        n = len(self.engine.connected_device_ids())
        if time.time() < self.toast_until:
            text = self.toast_text
        elif n:
            text = "%d phone%s connected" % (n, "" if n == 1 else "s")
        else:
            text = "Running - waiting for a phone"
        self.status_label.configure(text=text)
        self.dot.itemconfigure(self.dot_item, fill=OK if n else ACCENT)

    def _update_buttons(self):
        has = self._selected() is not None
        self.kick_btn.configure(state="normal" if has else "disabled")
        self.forget_btn.configure(state="normal" if has else "disabled")

    def _refresh_devices(self):
        keep = self._selected()
        connected = self.engine.connected_device_ids()
        self.tree.delete(*self.tree.get_children())
        for d in sorted(self.engine.store.list_devices(), key=lambda x: -x.get("last_seen", 0)):
            state = "Connected" if d["id"] in connected else "Offline"
            seen = "now" if d["id"] in connected else time.strftime("%d %b %Y, %H:%M", time.localtime(d.get("last_seen", 0)))
            self.tree.insert("", "end", iid=d["id"], values=(d["name"], state, seen))
        if keep and self.tree.exists(keep):
            self.tree.selection_set(keep)
        self._update_buttons()
        self._update_status()

    def _draw_qr(self, uri):
        c = self.qr_canvas
        c.delete("all")
        m = make_qr(uri)
        n = len(m)
        scale = max(1, 260 // (n + 6))
        off = (260 - scale * n) // 2
        for y in range(n):
            for x in range(n):
                if m[y][x]:
                    c.create_rectangle(off + x * scale, off + y * scale, off + (x + 1) * scale, off + (y + 1) * scale,
                                       fill="black", outline="black")

    def _tick(self, force=False):
        """Once a second: keep the QR code and countdown current."""
        code, left = self.engine.current_code()
        ip = self.ip_var.get()
        if force or code != self.shown_code or ip != self.shown_ip:
            ordered = [ip] + [i for i in self.ips if i != ip]
            try:
                self._draw_qr(self.engine.pairing_uri(ordered, self.port))
            except ValueError:
                self.qr_canvas.delete("all")
            self.code_label.configure(text=P.format_code(code))
            self.shown_code, self.shown_ip = code, ip
        self.expiry_label.configure(text="Code expires in %d:%02d" % (left // 60, left % 60))
        self._update_status()
        if int(time.time()) % 10 == 0:  # pick up Wi-Fi changes
            ips = local_ips()
            if ips != self.ips:
                self.ips = ips
                self.ip_box.configure(values=ips)
                if self.ip_var.get() not in ips:
                    self.ip_var.set(ips[0])
        self.root.after(1000, self._tick)

    def _poll(self):
        changed = False
        try:
            while True:
                ev = self.events.get_nowait()
                kind = ev.get("event")
                if kind == "request":
                    self._show_allow(ev)
                elif kind == "request_end":
                    self._close_allow(ev.get("id"))
                elif kind == "ui_open":
                    self.show()
                elif kind == "ui_quit":
                    self._quit()
                elif kind == "paired":
                    self._toast("Paired with %s" % ev.get("name"))
                elif kind == "rejected":
                    self._toast("A device on %s used a wrong code or key" % ev.get("ip"))
                if kind in ("paired", "connected", "disconnected", "forgotten"):
                    changed = True
        except queue.Empty:
            pass
        if changed:
            self._refresh_devices()
        self.root.after(250, self._poll)


def _listen_for_open(window, port):
    """A second launch pings this local port, so double-clicking the shortcut opens the window."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", port))
    except OSError:
        return

    def loop():
        while True:
            try:
                data, _ = sock.recvfrom(64)
            except OSError:
                return
            if data == b"REMOTEX_OPEN":
                window.events.put({"event": "ui_open"})

    threading.Thread(target=loop, name="remotex-open", daemon=True).start()


def ask_running_instance_to_open(port=P.WS_PORT - 2):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(b"REMOTEX_OPEN", ("127.0.0.1", port))
        s.close()
        return True
    except OSError:
        return False


def run(engine, name, ips, port, minimized=False, selftest_ms=0, background=False, report=None):
    """Open the window (or, with background=True, only a tray icon and the Allow prompts).
    With selftest_ms the program closes itself and the call returns 0."""
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    root = tk.Tk()
    window = ServerWindow(root, engine, name, ips, port, minimized=minimized and not selftest_ms and not background,
                          background=background)
    _listen_for_open(window, P.WS_PORT - 2)
    if background:
        try:
            from .tray import Tray
            window.tray = Tray(window.events.put, name)
            window.tray.start()
            if report:
                report("tray=ok")
            if not selftest_ms:
                window.tray.notify("Running in the background. Open the RemoteX app on your phone and tap this PC.")
            root.withdraw()
        except Exception as exc:  # no tray available: stay usable with a minimised window
            window.tray = None
            window.background = False
            if report:
                report("tray=failed %r" % (exc,))
            root.iconify()
    if selftest_ms:
        def try_dialog():
            try:
                window._show_allow({"id": "selftest", "name": "Self-test phone", "ip": "127.0.0.1", "sas": "123456"})
                assert window.allow is not None
                root.update()
                window._answer("selftest", True)
                assert window.allow is None
                if report:
                    report("allow_dialog=ok")
            except Exception as exc:
                if report:
                    report("allow_dialog=failed %r" % (exc,))
        root.after(500, try_dialog)
        root.after(selftest_ms, root.destroy)
    root.mainloop()
    if window.tray:
        window.tray.stop()
    return 0
