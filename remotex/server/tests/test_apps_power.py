import unittest

from helpers import make_engine
from remotex_server import apps as A
from remotex_server.engine import dispatch


class PowerTests(unittest.TestCase):
    def setUp(self):
        self.engine, self.log, self.events = make_engine()

    def test_known_actions_reach_the_controller(self):
        for a in ("lock", "sleep", "restart", "shutdown", "signout", "cancel"):
            dispatch(self.engine.controller, {"t": "power", "a": a})
        self.assertEqual([e["a"] for e in self.log if e.get("op") == "power"],
                         ["lock", "sleep", "restart", "shutdown", "signout", "cancel"])

    def test_unknown_or_bad_actions_are_ignored(self):
        for a in ("format", "", None, 5, ["lock"], "LOCK"):
            dispatch(self.engine.controller, {"t": "power", "a": a})
        self.assertEqual([e for e in self.log if e.get("op") == "power"], [])


class AppsTests(unittest.TestCase):
    def test_icons_only_for_unknown_ids(self):
        src = A.FakeApps()
        first = src.list(set())
        self.assertEqual(len(first["list"]), 2)
        self.assertEqual(set(first["icons"]), {"aaaa", "bbbb"})
        second = src.list({"aaaa"})
        self.assertEqual(set(second["icons"]), {"bbbb"})

    def test_focus_and_close_only_listed_windows(self):
        events = []
        src = A.FakeApps(events.append)
        self.assertTrue(src.focus(101))
        self.assertFalse(src.focus(999))
        self.assertTrue(src.close(102))
        self.assertFalse(src.close(102))
        self.assertEqual([e["op"] for e in events], ["focus", "closewin"])

    def test_clean_have(self):
        self.assertEqual(A.clean_have(["a", 1, "", "x" * 40, None, "b"]), {"a", "b"})
        self.assertEqual(A.clean_have("abc"), set())


if __name__ == "__main__":
    unittest.main()
