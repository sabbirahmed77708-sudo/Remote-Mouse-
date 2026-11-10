import json
import os
import unittest

from helpers import norm  # noqa: F401  (also sets sys.path)
from make_vectors import build
from remotex_server import protocol as P

VECTORS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "protocol", "test_vectors.json")


class ProtocolTests(unittest.TestCase):
    def test_vectors_file_is_current(self):
        with open(VECTORS) as f:
            self.assertEqual(json.load(f), build(), "run: python server/tests/make_vectors.py")

    def test_vectors_match_helpers(self):
        v = build()
        self.assertEqual(P.normalize_code(v["code_as_typed"]), v["code_normalized"])
        self.assertEqual(P.normalize_code(v["code_lookalikes_typed"]), v["code_lookalikes_normalized"])
        self.assertEqual(P.fp_from_b64(v["fingerprint_b64"]), v["fingerprint"])

    def test_codes(self):
        for _ in range(200):
            code = P.new_code()
            self.assertEqual(len(code), P.CODE_LENGTH)
            self.assertTrue(all(c in P.CODE_ALPHABET for c in code))
            self.assertEqual(P.normalize_code(P.format_code(code)), code)

    def test_proofs_differ_by_purpose_and_inputs(self):
        a = P.pair_proof("ABCDEFGHJKMN", "n1" * 16, "n2" * 16, "d" * 32, "f" * 64)
        self.assertNotEqual(a, P.server_proof("ABCDEFGHJKMN", "n1" * 16, "n2" * 16, "d" * 32, "f" * 64))
        self.assertNotEqual(a, P.pair_proof("ABCDEFGHJKMN", "n1" * 16, "n2" * 16, "d" * 32, "e" * 64))
        self.assertTrue(P.proofs_equal(a, a))
        self.assertFalse(P.proofs_equal(a, None))
        self.assertFalse(P.proofs_equal(a, 123))

    def test_hex_validators(self):
        self.assertTrue(P.is_hex32("0" * 32))
        self.assertFalse(P.is_hex32("0" * 31))
        self.assertFalse(P.is_hex32("G" * 32))
        self.assertFalse(P.is_hex32(None))


if __name__ == "__main__":
    unittest.main()
