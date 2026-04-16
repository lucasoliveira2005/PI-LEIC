"""Transport adapters: WebSocket and ZMQ source connections."""

from __future__ import annotations

import threading
from typing import Any, Callable, Dict, Optional

import websocket

from .config import (
    METRICS_TRANSPORT_BACKEND,
    METRICS_WS_PING_INTERVAL_SECONDS,
    METRICS_WS_PING_TIMEOUT_SECONDS,
)


def websocket_keepalive_kwargs() -> Dict[str, Any]:
    if METRICS_WS_PING_INTERVAL_SECONDS <= 0:
        return {}

    keepalive_kwargs: Dict[str, Any] = {
        "ping_interval": METRICS_WS_PING_INTERVAL_SECONDS,
    }

    if METRICS_WS_PING_TIMEOUT_SECONDS > 0:
        keepalive_kwargs["ping_timeout"] = METRICS_WS_PING_TIMEOUT_SECONDS

    return keepalive_kwargs


class SourceTransportAdapter:
    def run_once(
        self,
        on_open: Callable[[Any], None],
        on_message: Callable[[Any, str], None],
        on_error: Callable[[Any, Any], None],
        on_close: Callable[[Any, Any, Any], None],
    ) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        """Interrupt a blocking run_once() call. Best-effort; subclasses override."""


class WebSocketSourceAdapter(SourceTransportAdapter):
    def __init__(self, source: Dict[str, Any]):
        self.source = source
        self._ws_lock = threading.Lock()
        self._ws_app: Optional[Any] = None

    def run_once(
        self,
        on_open: Callable[[Any], None],
        on_message: Callable[[Any, str], None],
        on_error: Callable[[Any, Any], None],
        on_close: Callable[[Any, Any, Any], None],
    ) -> None:
        app = websocket.WebSocketApp(
            self.source["ws_url"],
            on_open=on_open,
            on_message=on_message,
            on_error=on_error,
            on_close=on_close,
        )
        with self._ws_lock:
            self._ws_app = app
        try:
            app.run_forever(**websocket_keepalive_kwargs())
        finally:
            with self._ws_lock:
                self._ws_app = None

    def stop(self) -> None:
        """Close the active WebSocket connection so run_forever() returns."""
        with self._ws_lock:
            app = self._ws_app
        if app is not None:
            try:
                app.close()
            except Exception:
                pass


class ZmqSourceAdapter(SourceTransportAdapter):
    def __init__(self, source: Dict[str, Any]):
        self.source = source

    def run_once(
        self,
        on_open: Callable[[Any], None],
        on_message: Callable[[Any, str], None],
        on_error: Callable[[Any, Any], None],
        on_close: Callable[[Any, Any, Any], None],
    ) -> None:
        raise NotImplementedError(
            "ZMQ transport adapter is not implemented yet. "
            "Set METRICS_TRANSPORT_BACKEND=websocket for current runtime support."
        )

    def stop(self) -> None:
        pass  # No active connection to close until ZMQ is implemented.


def build_transport_adapter(
    source: Dict[str, Any],
    backend: Optional[str] = None,
) -> SourceTransportAdapter:
    """Build the appropriate transport adapter for *source*.

    Parameters
    ----------
    source:
        Source config dict (must contain ``ws_url`` or ``zmq_endpoint`` depending
        on the active backend).
    backend:
        Override the active transport backend.  Defaults to the module-level
        ``METRICS_TRANSPORT_BACKEND`` env var.  Pass explicitly in tests to avoid
        monkeypatching module globals.
    """
    _backend = backend if backend is not None else METRICS_TRANSPORT_BACKEND
    if _backend == "websocket":
        return WebSocketSourceAdapter(source)
    if _backend == "zmq":
        return ZmqSourceAdapter(source)

    raise ValueError(
        f"Unsupported transport backend: {_backend!r}. Supported values: websocket, zmq"
    )
