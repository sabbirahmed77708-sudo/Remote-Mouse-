import unittest

from helpers import RefClient, make_engine


class AllowPairingTests(unittest.TestCase):
    def setUp(self):
        self.engine, self.log, self.events = make_engine()
        self.pushed = []

    def _client(self, **kw):
        c = RefClient(self.engine, **kw)
        c.session.set_send_callback(self.pushed.append)
        return c

    def _pending_id(self):
        return [e for e in self.events if e.get("event") == "request"][-1]["id"]

    def test_allow_pairs_and_key_works(self):
        c = self._client()
        res = c.request()
        self.assertEqual(res.replies[0]["t"], "waiting")
        self.assertEqual(res.replies[0]["sas"], c.my_sas)  # both sides compute the same number
        self.assertFalse(c.session.ready)
        self.assertTrue(self.engine.approve(self._pending_id()))
        self.assertTrue(c.session.ready)
        key = self.pushed[-1]["device_key"]
        self.assertEqual(self.pushed[-1]["t"], "approved")
        self.assertEqual(len(key), 64)
        c2 = RefClient(self.engine, device_id=c.device_id)
        self.assertEqual(c2.auth(key).replies[0]["t"], "ready")

    def test_nothing_is_stored_before_allow(self):
        c = self._client()
        c.request()
        self.assertEqual(self.engine.store.list_devices(), [])
        self.assertEqual(c.cmd({"t": "move", "dx": 5, "dy": 5}).replies, [])
        self.assertEqual(self.log, [])

    def test_deny(self):
        c = self._client()
        closed = []
        c.session.set_close_callback(lambda code, reason: closed.append((code, reason)))
        c.request()
        self.assertTrue(self.engine.deny(self._pending_id()))
        self.assertEqual(self.pushed[-1]["code"], "denied")
        self.assertEqual(closed[-1][0], 4001)
        self.assertEqual(self.engine.store.list_devices(), [])
        self.assertIsNone(self.engine.pending_request())

    def test_only_one_question_at_a_time(self):
        a, b = self._client(ip="192.168.1.50"), self._client(ip="192.168.1.51")
        a.request()
        res = b.request()
        self.assertEqual(res.replies[0]["code"], "busy")
        self.assertEqual(res.close[0], 4001)
        self.assertFalse(b.session.ready)

    def test_closing_the_connection_cancels_the_question(self):
        a = self._client()
        a.request()
        a.session.closed()
        self.assertIsNone(self.engine.pending_request())
        self.assertFalse(self.engine.approve(self._pending_id()))
        b = self._client()
        self.assertEqual(b.request().replies[0]["t"], "waiting")

    def test_stale_or_wrong_id_cannot_approve(self):
        c = self._client()
        c.request()
        self.assertFalse(self.engine.approve("deadbeef"))
        self.assertFalse(c.session.ready)

    def test_man_in_the_middle_sees_a_different_number(self):
        c = self._client(fp_seen="ee" * 32)  # phone saw another certificate than the real server's
        res = c.request()
        self.assertNotEqual(res.replies[0]["sas"], c.my_sas)

    def test_bad_nonce_rejected(self):
        c = self._client()
        res = c.request(client_nonce="zz")
        self.assertEqual(res.replies[0]["code"], "bad_request")
        self.assertIsNone(self.engine.pending_request())

    def test_repeated_denials_lock_the_address_out(self):
        for _ in range(8):
            c = self._client(ip="10.0.0.9")
            c.request()
            self.engine.deny(self._pending_id())
        c = self._client(ip="10.0.0.9")
        self.assertEqual(c.request().replies[0]["code"], "locked")


if __name__ == "__main__":
    unittest.main()
