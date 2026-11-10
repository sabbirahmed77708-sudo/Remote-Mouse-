"""Persistent state: server id and the list of paired devices (JSON files, atomic writes)."""
import json
import os
import secrets
import threading
import time


class Store:
    def __init__(self, directory):
        self.directory = directory
        self._lock = threading.RLock()
        self._server_path = os.path.join(directory, "server.json")
        self._devices_path = os.path.join(directory, "devices.json")
        self._server = self._load(self._server_path, {})
        if not isinstance(self._server.get("id"), str) or len(self._server["id"]) != 32:
            self._server["id"] = secrets.token_hex(16)
            self._write(self._server_path, self._server)
        devices = self._load(self._devices_path, {})
        self._devices = devices if isinstance(devices, dict) else {}

    # ---- helpers ----
    @staticmethod
    def _load(path, default):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    @staticmethod
    def _write(path, data):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)

    # ---- server ----
    @property
    def server_id(self):
        return self._server["id"]

    @property
    def display_name(self):
        return self._server.get("name")

    def set_display_name(self, name):
        with self._lock:
            self._server["name"] = name
            self._write(self._server_path, self._server)

    # ---- devices ----
    def add_device(self, device_id, name, key_hex, ip):
        now = time.time()
        with self._lock:
            self._devices[device_id] = {"name": name, "key": key_hex, "paired_at": now,
                                        "last_seen": now, "last_ip": ip}
            self._write(self._devices_path, self._devices)

    def get_device(self, device_id):
        with self._lock:
            d = self._devices.get(device_id)
            return dict(d, id=device_id) if d else None

    def touch(self, device_id, ip):
        with self._lock:
            d = self._devices.get(device_id)
            if d:
                d["last_seen"] = time.time()
                d["last_ip"] = ip
                self._write(self._devices_path, self._devices)

    def remove_device(self, device_id):
        with self._lock:
            if self._devices.pop(device_id, None) is not None:
                self._write(self._devices_path, self._devices)
                return True
            return False

    def list_devices(self):
        with self._lock:
            return [dict(v, id=k) for k, v in self._devices.items()]
