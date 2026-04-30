"""Transport adapters: WebSocket source connection.

The current ingestion transport is WebSocket (srsRAN's JSON metrics server).
The target transport for SC-RIC integration is E2AP/KPM — not ZMQ. A KPM
adapter will be added in Phase 1; until then the factory only returns the
WebSocket adapter. Do not add speculative transport implementations here.
"""

from __future__ import annotations

import threading
from typing import Any, Callable, Dict, Optional

import websocket

from .config import (
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


def build_transport_adapter(source: Dict[str, Any]) -> SourceTransportAdapter:
    """Build the transport adapter for *source*.

    WebSocket is the only supported backend. The future E2SM KPM adapter
    (Phase 1) will be added as a sibling subclass and this factory will gain
    source-type dispatch at that point.
    """
    return WebSocketSourceAdapter(source)
