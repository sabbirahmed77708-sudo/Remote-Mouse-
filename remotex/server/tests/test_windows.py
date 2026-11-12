import base64
import struct
import unittest
import zlib

from helpers import RefClient, make_engine
from remotex_server.engine import dispatch
from remotex_server.inputs import DryRunInput
from remotex_server import windows_api as W


def make_controller():
    log = []
    ctl = DryRunInput(log.append)
    ctl.fake_front = 101
    ctl.fake_windows = [
        {"id": 101, "title": "Docs - Chrome", "app": "chrome.exe", "min": False},
        {"id": 102, "title": "Notes", "app": "notepad.exe", "min": True},
    ]
    ctl.fake_icons = {"chrome.exe": "QUJD"}
    return ctl, log


class WindowCommandTests(unittest.TestCase):
    def test_windows_list_reply(self):
        ctl, _ = make_controller()
        reply = dispatch(ctl, {"t": "windows"})
        self.assertEqual(reply["t"], "windows")
        self.assertEqual(reply["fg"], 101)
        self.assertEqual([w["id"] for w in reply["items"]], [101, 102])
        self.assertTrue(reply["items"][1]["min"])

    def test_list_is_capped(self):
        ctl, _ = make_controller()
        ctl.fake_windows = [{"id": i + 1, "title": "w", "app": "a.exe", "min": False} for i in range(W.MAX_WINDOWS + 25)]
        self.assertEqual(len(dispatch(ctl, {"t": "windows"})["items"]), W.MAX_WINDOWS)

    def test_icon_known_and_unknown(self):
        ctl, _ = make_controller()
        self.assertEqual(dispatch(ctl, {"t": "icon", "k": "chrome.exe"}), {"t": "icon", "k": "chrome.exe", "png": "QUJD"})
        self.assertIsNone(dispatch(ctl, {"t": "icon", "k": "nothing.exe"})["png"])

    def test_icon_rejects_bad_keys(self):
        ctl, _ = make_controller()
        for bad in (None, 5, "", "x" * 121, ["a"], {"a": 1}):
            self.assertIsNone(dispatch(ctl, {"t": "icon", "k": bad}))

    def test_window_actions(self):
        ctl, log = make_controller()
        for action in W.WINDOW_ACTIONS:
            self.assertIsNone(dispatch(ctl, {"t": "win", "a": action, "id": 102}))
        self.assertEqual([e["a"] for e in log], list(W.WINDOW_ACTIONS))
        self.assertTrue(all(e["op"] == "win" and e["id"] == 102 for e in log))

    def test_window_actions_ignore_invalid_input(self):
        ctl, log = make_controller()
        for msg in ({"t": "win", "a": "kill", "id": 5}, {"t": "win", "a": "close"}, {"t": "win", "a": "close", "id": 0},
                    {"t": "win", "a": "close", "id": "7"}, {"t": "win", "a": "close", "id": True},
                    {"t": "win", "a": None, "id": 5}, {"t": "win", "id": 5}):
            dispatch(ctl, msg)
        self.assertEqual(log, [])

    def test_launch_only_allowed_names(self):
        ctl, log = make_controller()
        dispatch(ctl, {"t": "launch", "k": "notepad"})
        dispatch(ctl, {"t": "launch", "k": "cmd"})
        dispatch(ctl, {"t": "launch", "k": "C:\\Windows\\System32\\cmd.exe"})
        dispatch(ctl, {"t": "launch", "k": ["notepad"]})
        dispatch(ctl, {"t": "launch"})
        self.assertEqual(log, [{"op": "launch", "k": "notepad"}])

    def test_every_launch_name_is_a_plain_word(self):
        for name, target in W.LAUNCH_APPS.items():
            self.assertTrue(name.isalnum() and name.islower(), name)
            self.assertNotIn(" ", target)

    def test_commands_need_a_ready_session(self):
        engine, log, _ = make_engine()
        for msg in ({"t": "win", "a": "close", "id": 5}, {"t": "windows"}, {"t": "launch", "k": "notepad"}):
            client = RefClient(engine)  # a new connection that has not paired or authenticated
            res = client.cmd(msg)
            self.assertEqual(res.replies[0]["code"], "bad_request")  # only pair/auth/request are accepted first
            self.assertIsNotNone(res.close)
        self.assertEqual(log, [])

    def test_through_a_paired_session(self):
        engine, log, _ = make_engine()
        code, _ = engine.current_code()
        client = RefClient(engine)
        client.pair(code)
        engine.controller.fake_windows = [{"id": 7, "title": "T", "app": "a.exe", "min": False}]
        res = client.cmd({"t": "windows"})
        self.assertEqual(res.replies[0]["items"][0]["id"], 7)
        client.cmd({"t": "win", "a": "close", "id": 7})
        self.assertEqual(log[-1], {"op": "win", "a": "close", "id": 7})


class HelperTests(unittest.TestCase):
    def test_clean_title(self):
        self.assertEqual(W.clean_title("  Hello\x00 world\n"), "Hello world")
        self.assertEqual(len(W.clean_title("x" * 500)), W.MAX_TITLE)
        self.assertEqual(W.clean_title("Avro Keyboard - \u09ac\u09be\u0982\u09b2\u09be"), "Avro Keyboard - \u09ac\u09be\u0982\u09b2\u09be")

    def test_taskbar_rules(self):
        ok = dict(visible=True, title="T", ex_style=0, has_owner=False, cloaked=False, class_name="Chrome_WidgetWin_1")
        self.assertTrue(W.is_taskbar_window(**ok))
        self.assertFalse(W.is_taskbar_window(**dict(ok, visible=False)))
        self.assertFalse(W.is_taskbar_window(**dict(ok, title="")))
        self.assertFalse(W.is_taskbar_window(**dict(ok, cloaked=True)))
        self.assertFalse(W.is_taskbar_window(**dict(ok, class_name="Progman")))
        self.assertFalse(W.is_taskbar_window(**dict(ok, ex_style=0x80)))               # tool window
        self.assertFalse(W.is_taskbar_window(**dict(ok, has_owner=True)))              # dialog owned by another window
        self.assertTrue(W.is_taskbar_window(**dict(ok, ex_style=0x80 | 0x40000)))      # tool window that asks for a button
        self.assertTrue(W.is_taskbar_window(**dict(ok, has_owner=True, ex_style=0x40000)))
        self.assertFalse(W.is_taskbar_window(**dict(ok, ex_style=0x08000000)))         # never takes focus

    def test_png_is_valid(self):
        rgba = bytes([10, 20, 30, 255, 40, 50, 60, 128, 0, 0, 0, 0, 255, 255, 255, 255])  # 2x2
        png = W.encode_rgba_png(2, 2, rgba)
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        pos, idat, header = 8, b"", None
        while pos < len(png):
            (length,) = struct.unpack(">I", png[pos:pos + 4])
            tag, data = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + length]
            (crc,) = struct.unpack(">I", png[pos + 8 + length:pos + 12 + length])
            self.assertEqual(crc, zlib.crc32(tag + data) & 0xFFFFFFFF)
            if tag == b"IHDR":
                header = struct.unpack(">IIBBBBB", data)
            elif tag == b"IDAT":
                idat += data
            pos += 12 + length
        self.assertEqual(header, (2, 2, 8, 6, 0, 0, 0))
        raw = zlib.decompress(idat)
        self.assertEqual(raw, b"\x00" + rgba[:8] + b"\x00" + rgba[8:])

    def test_alpha_recovery(self):
        # pixel layouts are BGRA. Opaque red, half-transparent blue, fully transparent.
        icon = [(0, 0, 255, 255), (255, 0, 0, 128), (0, 0, 0, 0)]
        on_black, on_white = bytearray(), bytearray()
        for b, g, r, a in icon:
            for bg, out in ((0, on_black), (255, on_white)):
                out += bytes([(c * a + bg * (255 - a)) // 255 for c in (b, g, r)]) + b"\xff"
        rgba = W.rgba_from_renders(bytes(on_black), bytes(on_white))
        self.assertEqual(tuple(rgba[0:4]), (255, 0, 0, 255))
        self.assertAlmostEqual(rgba[7], 128, delta=2)  # alpha of the half-transparent pixel
        self.assertGreaterEqual(rgba[6], 250)          # blue channel restored
        self.assertLessEqual(rgba[4], 3)               # no red
        self.assertEqual(tuple(rgba[8:12]), (0, 0, 0, 0))

    def test_alpha_recovery_rejects_mismatch(self):
        with self.assertRaises(ValueError):
            W.rgba_from_renders(b"\x00" * 8, b"\x00" * 4)

    def test_icon_message_fits_the_frame(self):
        # a worst case 32x32 icon (random-looking pixels) as base64 must stay small
        import os
        png = W.encode_rgba_png(32, 32, os.urandom(32 * 32 * 4))
        self.assertLess(len(base64.b64encode(png)), 6000)


if __name__ == "__main__":
    unittest.main()
