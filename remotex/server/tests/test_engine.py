import json
import unittest

from helpers import FP, FakeClock, RefClient, make_engine
from remotex_server import protocol as P
from remotex_server.engine import dispatch


class PairingTests(unittest.TestCase):
    def test_pair_then_reconnect_with_key(self):
        engine, _log, events = make_engine()
        code, _ = engine.current_code()
        c = RefClient(engine)
        res = c.pair(code)
        self.assertEqual(res.replies[0]["t"], "paired")
        self.assertIsNone(res.close)
        self.assertTrue(c.server_proof_ok, "client must be able to verify the server proof")
        self.assertEqual(len(c.device_key), 64)
        self.assertTrue(c.session.ready)
        self.assertIn(c.device_id, engine.connected_device_ids())
        self.assertEqual(engine.store.get_device(c.device_id)["name"], "Test Phone")
        c.session.closed()

        c2 = RefClient(engine, device_id=c.device_id)
        res = c2.auth(c.device_key)
        self.assertEqual(res.replies[0]["t"], "ready")
        self.assertEqual(res.replies[0]["name"], "TEST-PC")
        self.assertEqual([e["event"] for e in events if e["event"] in ("paired", "connected", "disconnected")],
                         ["connected", "paired", "disconnected", "connected"])

    def test_code_is_single_use(self):
        engine, _, _ = make_engine()
        code, _ = engine.current_code()
        RefClient(engine).pair(code)
        self.assertNotEqual(engine.current_code()[0], code)
        res = RefClient(engine).pair(code)
        self.assertEqual(res.replies[0]["code"], "bad_proof")

    def test_wrong_code_rejected_and_nothing_stored(self):
        engine, _, _ = make_engine()
        c = RefClient(engine)
        res = c.pair("AAAA-AAAA-AAAA")
        self.assertEqual(res.replies[0]["code"], "bad_proof")
        self.assertEqual(res.close[0], P.CLOSE_UNAUTHORIZED)
        self.assertEqual(engine.store.list_devices(), [])
        self.assertFalse(c.session.ready)

    def test_code_rotates_after_5_wrong_attempts(self):
        engine, _, _ = make_engine()
        code, _ = engine.current_code()
        for _ in range(5):
            RefClient(engine, ip="10.0.0.%d" % _).pair("AAAA-AAAA-AAAA")
        self.assertNotEqual(engine.current_code()[0], code)
        self.assertEqual(RefClient(engine).pair(code).replies[0]["code"], "bad_proof")

    def test_code_expires(self):
        clock = FakeClock()
        engine, _, _ = make_engine(clock)
        code, left = engine.current_code()
        self.assertEqual(left, 300)
        clock.advance(299)
        self.assertEqual(engine.current_code()[0], code)
        clock.advance(2)
        self.assertNotEqual(engine.current_code()[0], code)

    def test_expired_code_cannot_pair(self):
        clock = FakeClock()
        engine, _, _ = make_engine(clock)
        code, _ = engine.current_code()
        c = RefClient(engine)
        clock.advance(301)
        # the engine notices expiry when asked; a connection that raced the rotation is refused
        res = c.pair(code)
        self.assertEqual(res.replies[0]["t"], "error")
        self.assertEqual(engine.store.list_devices(), [])

    def test_man_in_the_middle_with_other_certificate_fails(self):
        engine, _, _ = make_engine()
        code, _ = engine.current_code()
        c = RefClient(engine, fp_seen="ee" * 32)  # client's TLS layer saw a different certificate
        res = c.pair(code)
        self.assertEqual(res.replies[0]["code"], "bad_proof")
        self.assertEqual(engine.store.list_devices(), [])

    def test_fake_server_cannot_satisfy_client(self):
        """A server that does not know the code cannot produce a valid server_proof."""
        from remotex_server import protocol as P2
        good = P2.server_proof("ABCDEFGHJKMN", "a" * 32, "b" * 32, "c" * 32, FP)
        bad = P2.server_proof("ZZZZZZZZZZZZ", "a" * 32, "b" * 32, "c" * 32, FP)
        self.assertNotEqual(good, bad)

    def test_malformed_pair_fields(self):
        engine, _, _ = make_engine()
        code, _ = engine.current_code()
        for msg in (
            {"t": "pair", "device_id": "short", "nonce": "a" * 32, "proof": "x"},
            {"t": "pair", "device_id": "a" * 32, "nonce": "nothex", "proof": "x"},
            {"t": "pair", "device_id": "a" * 32, "nonce": "a" * 32},
            {"t": "hello"},
            {"t": "move", "dx": 1, "dy": 1},
        ):
            s = engine.new_session("10.1.1.1")
            res = s.on_text(json.dumps(msg))
            self.assertEqual(res.replies[0]["t"], "error", msg)
            self.assertIsNotNone(res.close, msg)
        s = engine.new_session("10.1.1.2")
        self.assertEqual(s.on_text("not json").replies[0]["code"], "bad_request")
        self.assertEqual(s.on_text("[1,2]").replies[0]["code"], "bad_request")
        self.assertEqual(engine.store.list_devices(), [])
        self.assertEqual(engine.current_code()[0], code)

    def test_device_name_sanitised(self):
        engine, _, _ = make_engine()
        c = RefClient(engine, name="  Evil\x00\x07 name" + "x" * 100)
        c.pair(engine.current_code()[0])
        name = engine.store.get_device(c.device_id)["name"]
        self.assertTrue(name.isprintable())
        self.assertLessEqual(len(name), 40)


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.engine, self.log, self.events = make_engine()
        self.dev = RefClient(self.engine)
        self.dev.pair(self.engine.current_code()[0])
        self.dev.session.closed()

    def test_wrong_key_rejected(self):
        c = RefClient(self.engine, device_id=self.dev.device_id)
        res = c.auth("00" * 32)
        self.assertEqual(res.replies[0]["code"], "unauthorized")
        self.assertEqual(res.close[0], P.CLOSE_UNAUTHORIZED)

    def test_unknown_device_gets_same_answer(self):
        res = RefClient(self.engine).auth("11" * 32)
        self.assertEqual(res.replies[0], {"t": "error", "code": "unauthorized", "msg": "This device is not paired"})

    def test_replayed_proof_fails_on_new_connection(self):
        first = RefClient(self.engine, device_id=self.dev.device_id)
        proof_msg = None
        import hashlib
        import hmac
        proof = hmac.new(bytes.fromhex(self.dev.device_key),
                         ("remotex-auth|%s|%s|%s" % (first.hello["nonce"], first.device_id, FP)).encode(),
                         hashlib.sha256).hexdigest()
        proof_msg = {"t": "auth", "device_id": first.device_id, "proof": proof}
        self.assertEqual(first.session.on_text(json.dumps(proof_msg)).replies[0]["t"], "ready")
        second = self.engine.new_session("10.9.9.9")  # attacker re-sends the captured message
        self.assertEqual(second.on_text(json.dumps(proof_msg)).replies[0]["code"], "unauthorized")

    def test_forget_revokes_and_kicks(self):
        c = RefClient(self.engine, device_id=self.dev.device_id)
        self.assertEqual(c.auth(self.dev.device_key).replies[0]["t"], "ready")
        closed = []
        c.session.set_close_callback(lambda code, reason: closed.append(code))
        self.assertTrue(self.engine.forget(self.dev.device_id))
        self.assertEqual(closed, [P.CLOSE_REMOVED])
        c2 = RefClient(self.engine, device_id=self.dev.device_id)
        self.assertEqual(c2.auth(self.dev.device_key).replies[0]["code"], "unauthorized")

    def test_kick_keeps_pairing(self):
        c = RefClient(self.engine, device_id=self.dev.device_id)
        c.auth(self.dev.device_key)
        closed = []
        c.session.set_close_callback(lambda code, reason: closed.append(code))
        self.assertEqual(self.engine.kick(self.dev.device_id), 1)
        self.assertEqual(closed, [P.CLOSE_REMOVED])
        self.assertIsNotNone(self.engine.store.get_device(self.dev.device_id))
        self.assertEqual(self.engine.kick("0" * 32), 0)

    def test_lockout_after_repeated_failures(self):
        ip = "10.5.5.5"
        for _ in range(8):
            RefClient(self.engine, ip=ip, device_id=self.dev.device_id).auth("22" * 32)
        good = RefClient(self.engine, ip=ip, device_id=self.dev.device_id)
        res = good.auth(self.dev.device_key)
        self.assertEqual(res.replies[0]["code"], "locked")
        self.assertEqual(res.close[0], P.CLOSE_LOCKED)
        # another address is unaffected
        other = RefClient(self.engine, ip="10.5.5.6", device_id=self.dev.device_id)
        self.assertEqual(other.auth(self.dev.device_key).replies[0]["t"], "ready")

    def test_lockout_expires(self):
        clock = FakeClock()
        engine, _, _ = make_engine(clock)
        ip = "10.6.6.6"
        for _ in range(8):
            RefClient(engine, ip=ip).auth("22" * 32)
        self.assertTrue(engine._is_locked(ip))
        clock.advance(61)
        self.assertFalse(engine._is_locked(ip))

    def test_commands_before_auth_do_nothing(self):
        s = self.engine.new_session("10.7.7.7")
        res = s.on_text(json.dumps({"t": "move", "dx": 50, "dy": 50}))
        self.assertEqual(res.replies[0]["t"], "error")
        self.assertEqual(self.log, [])


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.engine, self.log, _ = make_engine()
        self.c = RefClient(self.engine)
        self.c.pair(self.engine.current_code()[0])

    def run_cmd(self, msg):
        self.log.clear()
        res = self.c.cmd(msg)
        return res, list(self.log)

    def test_every_command_reaches_the_controller(self):
        cases = [
            ({"t": "move", "dx": 5, "dy": -3}, [{"op": "move", "dx": 5, "dy": -3}]),
            ({"t": "click", "b": "left", "n": 1}, [{"op": "click", "b": "left", "n": 1}]),
            ({"t": "click", "b": "right", "n": 1}, [{"op": "click", "b": "right", "n": 1}]),
            ({"t": "click", "b": "left", "n": 2}, [{"op": "click", "b": "left", "n": 2}]),
            ({"t": "click", "b": "middle"}, [{"op": "click", "b": "middle", "n": 1}]),
            ({"t": "btn", "b": "left", "d": True}, [{"op": "btn", "b": "left", "d": True}]),
            ({"t": "btn", "b": "left", "d": False}, [{"op": "btn", "b": "left", "d": False}]),
            ({"t": "scroll", "dx": 0, "dy": 120}, [{"op": "scroll", "dx": 0, "dy": 120}]),
            ({"t": "scroll", "dx": -40, "dy": 0}, [{"op": "scroll", "dx": -40, "dy": 0}]),
            ({"t": "text", "s": "hi অা"}, [{"op": "text", "s": "hi অা"}]),
            ({"t": "key", "k": "enter"}, [{"op": "key", "k": "enter", "n": 1}]),
            ({"t": "key", "k": "BACKSPACE", "n": 3}, [{"op": "key", "k": "backspace", "n": 3}]),
            ({"t": "combo", "k": ["ctrl", "c"]}, [{"op": "combo", "k": ["ctrl", "c"]}]),
            ({"t": "media", "k": "playpause"}, [{"op": "media", "k": "playpause"}]),
            ({"t": "media", "k": "next"}, [{"op": "media", "k": "next"}]),
            ({"t": "media", "k": "prev"}, [{"op": "media", "k": "prev"}]),
            ({"t": "media", "k": "volup"}, [{"op": "media", "k": "volup"}]),
            ({"t": "media", "k": "voldown"}, [{"op": "media", "k": "voldown"}]),
            ({"t": "media", "k": "mute"}, [{"op": "media", "k": "mute"}]),
        ]
        for msg, expected in cases:
            _res, log = self.run_cmd(msg)
            self.assertEqual(log, expected, msg)

    def test_ping_pong(self):
        res, log = self.run_cmd({"t": "ping", "ts": 123456})
        self.assertEqual(res.replies, [{"t": "pong", "ts": 123456}])
        self.assertEqual(log, [])

    def test_bye_closes(self):
        res, _ = self.run_cmd({"t": "bye"})
        self.assertEqual(res.close[0], 1000)

    def test_values_are_clamped(self):
        _, log = self.run_cmd({"t": "move", "dx": 99999, "dy": -99999})
        self.assertEqual(log, [{"op": "move", "dx": 2000, "dy": -2000}])
        _, log = self.run_cmd({"t": "scroll", "dx": 0, "dy": 10 ** 9})
        self.assertEqual(log, [{"op": "scroll", "dx": 0, "dy": 1200}])
        _, log = self.run_cmd({"t": "key", "k": "a", "n": 9999})
        self.assertEqual(log, [{"op": "key", "k": "a", "n": 50}])
        _, log = self.run_cmd({"t": "text", "s": "x" * 900})
        self.assertEqual(len(log[0]["s"]), 500)

    def test_invalid_commands_are_ignored(self):
        bad = [
            {"t": "move", "dx": "5", "dy": None},
            {"t": "move", "dx": float("nan"), "dy": float("inf")},
            {"t": "move", "dx": True, "dy": True},
            {"t": "click", "b": "side"},
            {"t": "btn", "b": "left", "d": "yes"},
            {"t": "scroll"},
            {"t": "text", "s": 5},
            {"t": "text", "s": ""},
            {"t": "key", "k": "powerbutton"},
            {"t": "key", "k": ["a"]},
            {"t": "combo", "k": "ctrl"},
            {"t": "combo", "k": []},
            {"t": "combo", "k": ["ctrl", "alt", "shift", "win", "a", "b"]},
            {"t": "combo", "k": ["ctrl", "nope"]},
            {"t": "media", "k": "eject"},
            {"t": "shutdown"},
            {"t": 5},
            {},
        ]
        for msg in bad:
            res, log = self.run_cmd(msg)
            self.assertEqual(log, [], msg)
            self.assertIsNone(res.close, msg)

    def test_garbage_after_ready_is_ignored(self):
        self.assertEqual(self.c.session.on_text("not json").replies, [])
        self.assertTrue(self.c.session.ready)

    def test_direct_dispatch_matches(self):
        self.assertEqual(dispatch(self.engine.controller, {"t": "ping", "ts": "bad"}), {"t": "pong", "ts": 0})


class QrPayloadTests(unittest.TestCase):
    def test_uri_fits_and_roundtrips(self):
        engine, _, _ = make_engine()
        code, _ = engine.current_code()
        uri = engine.pairing_uri(["192.168.100.200", "10.0.0.99", "172.16.31.200"])
        self.assertLessEqual(len(uri.encode()), P.MAX_QR_BYTES)
        self.assertTrue(uri.startswith("remotex://pair?c=" + code + "&f="))
        from urllib.parse import parse_qs, urlparse
        q = parse_qs(urlparse(uri).query)
        self.assertEqual(P.fp_from_b64(q["f"][0]), FP)
        self.assertEqual(q["c"][0], code)
        self.assertEqual(q["h"][0].split(",")[0], "192.168.100.200")
        self.assertNotIn("p", q)

    def test_custom_port_included(self):
        engine, _, _ = make_engine()
        self.assertIn("&p=50000", engine.pairing_uri(["192.168.1.2"], 50000))

    def test_worst_case_ip_fits(self):
        engine, _, _ = make_engine()
        uri = engine.pairing_uri(["255.255.255.255"], 65535)
        self.assertLessEqual(len(uri.encode()), P.MAX_QR_BYTES)


if __name__ == "__main__":
    unittest.main()
