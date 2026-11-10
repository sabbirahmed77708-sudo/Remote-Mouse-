"""Regenerates protocol/test_vectors.json from the server implementation."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from remotex_server import protocol as P


def build():
    fp = "ab" * 32
    snonce = "00112233445566778899aabbccddeeff"
    cnonce = "ffeeddccbbaa99887766554433221100"
    device_id = "0123456789abcdef0123456789abcdef"
    device_key = "fedcba9876543210" * 4
    return {
        "_comment": "Shared by server/tests/test_protocol.py and app/test/protocol_test.dart. Regenerate with: python server/tests/make_vectors.py",
        "fingerprint": fp, "server_nonce": snonce, "client_nonce": cnonce,
        "device_id": device_id, "device_key": device_key,
        "code_as_typed": "abcd-efgh jkmn", "code_normalized": "ABCDEFGHJKMN",
        "code_lookalikes_typed": "o1il-0000-0000", "code_lookalikes_normalized": "011100000000",
        "pair_proof": P.pair_proof("abcd-efgh jkmn", snonce, cnonce, device_id, fp),
        "server_proof": P.server_proof("abcd-efgh jkmn", snonce, cnonce, device_id, fp),
        "auth_proof": P.auth_proof(device_key, snonce, device_id, fp),
        "fingerprint_b64": P.fp_to_b64(fp),
    }


if __name__ == "__main__":
    path = os.path.join(HERE, "..", "..", "protocol", "test_vectors.json")
    with open(path, "w") as f:
        json.dump(build(), f, indent=2)
    print("wrote", os.path.normpath(path))
