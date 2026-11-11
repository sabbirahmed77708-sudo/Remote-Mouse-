"""WebSocket-over-TLS transport. All protocol decisions live in engine.Session."""
import asyncio
import json
import logging
import threading

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from . import protocol as P

log = logging.getLogger("remotex.transport")


class TransportError(Exception):
    pass


class Transport:
    def __init__(self, engine, ssl_context, host="0.0.0.0", port=P.WS_PORT):
        self.engine = engine
        self.ssl_context = ssl_context
        self.host = host
        self.port = port
        self._thread = None
        self._loop = None
        self._stop = None
        self._started = threading.Event()
        self._error = None

    # ---- lifecycle ----
    def start(self, timeout=8.0):
        self._thread = threading.Thread(target=self._run, name="remotex-ws", daemon=True)
        self._thread.start()
        if not self._started.wait(timeout):
            raise TransportError("server did not start in time")
        if self._error is not None:
            raise TransportError(str(self._error))

    def stop(self):
        loop, stop = self._loop, self._stop
        if loop is not None and stop is not None:
            loop.call_soon_threadsafe(stop.set)
        if self._thread is not None:
            self._thread.join(timeout=5)

    def _run(self):
        try:
            asyncio.run(self._main())
        except Exception as exc:  # startup errors are reported through start()
            self._error = self._error or exc
            self._started.set()

    async def _main(self):
        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        try:
            async with serve(
                self._handler, self.host, self.port,
                ssl=self.ssl_context,
                max_size=P.MAX_MESSAGE_BYTES,
                ping_interval=10, ping_timeout=10,
                compression=None,
                origins=[None],  # native apps send no Origin header; refuse browsers
            ) as server:
                if self.port == 0:
                    self.port = server.sockets[0].getsockname()[1]
                self._started.set()
                await self._stop.wait()
        except OSError as exc:
            self._error = exc
            self._started.set()

    # ---- per-connection handler ----
    async def _handler(self, ws):
        peer = ws.remote_address[0] if ws.remote_address else "?"
        session = self.engine.new_session(peer)
        loop = asyncio.get_running_loop()

        def request_close(code, reason):
            loop.call_soon_threadsafe(lambda: asyncio.ensure_future(self._safe_close(ws, code, reason)))

        def push(message):
            async def _send():
                try:
                    await ws.send(json.dumps(message, separators=(",", ":")))
                except Exception:
                    pass
            loop.call_soon_threadsafe(lambda: asyncio.ensure_future(_send()))

        session.set_close_callback(request_close)
        session.set_send_callback(push)
        try:
            await ws.send(json.dumps(session.hello(), separators=(",", ":")))
            while True:
                if session.ready:
                    timeout = P.IDLE_TIMEOUT
                elif session.state == "waiting":
                    timeout = P.REQUEST_TIMEOUT
                else:
                    timeout = P.HANDSHAKE_TIMEOUT
                raw = await asyncio.wait_for(ws.recv(), timeout)
                if isinstance(raw, bytes):
                    await self._safe_close(ws, 1003, "text frames only")
                    break
                result = session.on_text(raw)
                for reply in result.replies:
                    await ws.send(json.dumps(reply, separators=(",", ":")))
                if result.close:
                    await self._safe_close(ws, *result.close)
                    break
        except asyncio.TimeoutError:
            await self._safe_close(ws, P.CLOSE_TIMEOUT, "timeout")
        except ConnectionClosed:
            pass
        except Exception:
            log.exception("connection handler failed")
            await self._safe_close(ws, 1011, "internal error")
        finally:
            session.closed()

    @staticmethod
    async def _safe_close(ws, code, reason):
        try:
            await ws.close(code, reason)
        except Exception:
            pass
