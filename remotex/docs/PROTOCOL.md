# RemoteX protocol, version 1

This document is the single source of truth for the wire format. The Windows server
(`server/remotex_server`) and the Android app (`app/lib/services/remotex_client.dart`)
both implement it. `protocol/test_vectors.json` holds HMAC test vectors that both test
suites check, and CI runs the real Dart client against the real Python server.

## Transport

| Item | Value |
|---|---|
| Control channel | WebSocket over TLS (`wss://<host>:48766/ws`), JSON **text** frames only |
| Discovery | UDP port `48765` |
| TLS | TLS 1.2+, self-signed ECDSA P-256 certificate created by the server on first run |
| Server identity | `fingerprint` = SHA-256 of the DER certificate, lowercase hex (64 chars) |
| Max message size | 16 KiB |

The app never trusts a certificate because of a CA. It accepts exactly one certificate:
the one whose fingerprint it pinned during pairing (or, for the very first manual
pairing, the one it sees - see "Manual pairing" below).

## Identities and secrets

* `server_id` - 32 hex chars, random, created once per server install.
* `device_id` - 32 hex chars, random, created once per app install.
* `pairing code` - 12 characters from the Crockford alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`,
  shown as `XXXX-XXXX-XXXX`. Single use, valid 5 minutes, replaced after use or expiry,
  replaced after 5 wrong attempts. Normalisation before use: upper-case, drop everything
  that is not a letter/digit, `O`->`0`, `I`->`1`, `L`->`1`.
* `device_key` - 32 random bytes (64 hex chars) created by the server for each pairing and
  stored by both sides. It is never sent again after the `paired` message.

## QR code / pairing link

```
remotex://pair?c=<code>&f=<fingerprint, base64url, no padding>&h=<ip>[,<ip>...][&p=<port>]
```

`p` is omitted when the port is 48766. The payload is at most 106 bytes so the QR code stays small.
The server name is learned from the `hello` message.

## Handshake

Every connection starts with the same steps.

1. Server -> client, immediately after the WebSocket opens:
   `{"t":"hello","v":1,"id":<server_id>,"name":<pc name>,"nonce":<32 hex>}`
2. Within **10 seconds** the client sends exactly one of `pair` or `auth`.
   Anything else, or silence, closes the connection.

### Pair (first time)

Client -> server:

```json
{"t":"pair","device_id":"<32 hex>","device_name":"Pixel 7","nonce":"<32 hex client nonce>","proof":"<hex>"}
```

```
proof = HMAC-SHA256( key = UTF-8(normalised code),
                     msg = "remotex-pair|" + server_nonce + "|" + client_nonce + "|" + device_id + "|" + fingerprint_seen )
```

`fingerprint_seen` is the fingerprint of the certificate **the client's TLS layer saw**.
The server uses the fingerprint of its **own** certificate. If a man-in-the-middle swapped
the certificate, the two differ and the proof fails.

Server -> client on success (then the session is open, no extra message):

```json
{"t":"paired","device_key":"<64 hex>","server_proof":"<hex>"}
```

```
server_proof = HMAC-SHA256( key = UTF-8(normalised code),
                            msg = "remotex-srv|" + server_nonce + "|" + client_nonce + "|" + device_id + "|" + fingerprint_seen )
```

The client **must** verify `server_proof`; this proves the server knows the code.

### Auth (every later connection)

Client -> server:

```json
{"t":"auth","device_id":"<32 hex>","proof":"<hex>"}
```

```
proof = HMAC-SHA256( key = device_key (raw 32 bytes),
                     msg = "remotex-auth|" + server_nonce + "|" + device_id + "|" + fingerprint_seen )
```

Server -> client on success: `{"t":"ready","name":"<pc name>"}`.

### Errors

`{"t":"error","code":"<code>","msg":"<text>"}` followed by a WebSocket close.

| code | meaning | close code |
|---|---|---|
| `bad_request` | malformed handshake | 4000 |
| `pairing_closed` | no valid pairing code right now | 4001 |
| `bad_proof` | pair proof wrong | 4001 |
| `unauthorized` | unknown device or wrong proof (same answer for both on purpose) | 4001 |
| `locked` | too many failures from this address, try again in a minute | 4002 |

Other close codes: `4003` = the PC user disconnected / removed this device (client must
not auto-reconnect), `4008` = handshake or idle timeout, `1001` = server stopping.

## Session messages (client -> server)

Only accepted after `paired` / `ready`. Unknown or invalid messages are ignored.

| Message | Meaning |
|---|---|
| `{"t":"move","dx":int,"dy":int}` | relative cursor move in pixels, each clamped to +-2000 |
| `{"t":"click","b":"left"\|"right"\|"middle","n":1\|2}` | click (n=2: double click) |
| `{"t":"btn","b":<button>,"d":true\|false}` | press / release (drag) |
| `{"t":"scroll","dx":int,"dy":int}` | wheel units, 120 = one notch. `dy>0` scrolls up, `dx>0` scrolls right. Clamped to +-1200 |
| `{"t":"text","s":"..."}` | type Unicode text, at most 500 characters |
| `{"t":"key","k":"<name>","n":1..50}` | tap a key `n` times |
| `{"t":"combo","k":["ctrl","c"]}` | hold the keys in order, release in reverse, at most 5 keys |
| `{"t":"media","k":"playpause"\|"next"\|"prev"\|"stop"\|"volup"\|"voldown"\|"mute"}` | media key |
| `{"t":"ping","ts":int}` | keep-alive; server answers `{"t":"pong","ts":<same>}` |
| `{"t":"bye"}` | clean close |

Key names: `a`-`z`, `0`-`9`, `f1`-`f12`, `enter`, `esc`, `tab`, `space`, `backspace`, `delete`,
`insert`, `home`, `end`, `pgup`, `pgdn`, `left`, `up`, `right`, `down`, `shift`, `ctrl`, `alt`, `win`.

The client sends `ping` every 5 s. The server closes a session that is silent for 30 s,
and the WebSocket layer also sends protocol pings every 10 s. A client that gets no `pong`
for 12 s treats the connection as lost and reconnects.

## Discovery (UDP)

The client broadcasts the 19 bytes `REMOTEX_DISCOVER_V1` to port 48765. Every server answers
the sender directly with one JSON datagram:

```json
{"t":"remotex","v":1,"id":"<server_id>","name":"<pc name>","port":48766}
```

Discovery is only a convenience for finding an address. It carries no secret and never
authorises anything; a discovered PC still needs the pinned certificate and a valid
`auth` or `pair`.

## Manual pairing (typing IP + code)

The client does not yet know the fingerprint, so it accepts the presented certificate once and
includes the fingerprint it saw in the proof. A man-in-the-middle cannot produce a proof the
real server accepts (different fingerprint), and a fake server cannot produce a valid
`server_proof` (does not know the code). On success the client pins that fingerprint.
Scanning the QR code is stronger because the fingerprint is pinned *before* connecting.

## Pairing with "Allow" (no typed code)

Used by the "Nearby" list. After `hello` the client sends

```json
{"t":"request","device_id":"<32 hex>","device_name":"Pixel 7","nonce":"<32 hex client nonce>"}
```

The server answers `{"t":"waiting","sas":"<6 digits>","timeout":60}` and shows "Allow this phone?" on the PC
with the same number. `sas` is `"%06d" % (int(sha256("remotex-sas|" + server_nonce + "|" + client_nonce + "|" + device_id + "|" + fingerprint_seen)[:10 hex chars], 16) % 1000000)`.
The client computes it itself from the certificate *it* saw and refuses if the server's number differs.
When the user presses Allow, the server sends `{"t":"approved","device_key":"<64 hex>"}` and the session is ready.
On Deny the server sends `error` code `denied` (close 4001). If nobody answers within 60 s the connection is closed (4008).
Only one question is pending at a time (`busy` otherwise); every denial counts as a failure for the per-address lockout.
Nothing is stored and no command is accepted before Allow. A man in the middle shows a different certificate, so the
phone and the PC display different numbers and the user denies.

## Brute-force protection

* Pairing code: 60 bits, single use, 5 minutes, rotated after 5 wrong attempts.
* Per source address: 8 failed handshakes within 60 s -> `locked` for 60 s.
* Handshake must finish in 10 s; unauthenticated connections can send nothing else.
