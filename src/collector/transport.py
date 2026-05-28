"""Transport adapters for metrics sources."""

from __future__ import annotations

import threading
import time
import json
from typing import Any, Callable, Dict, Optional

import websocket

from .config import (
    METRICS_WS_PING_INTERVAL_SECONDS,
    METRICS_WS_PING_TIMEOUT_SECONDS,
)
from .oai_mac_stats import parse_oai_mac_stats_text


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


class OaiMacStatsFileAdapter(SourceTransportAdapter):
    """Poll and parse an OAI ``nrMAC-stats.log`` file."""

    def __init__(self, source: Dict[str, Any]):
        self.source = source
        self._stop_event = threading.Event()
        self._last_signature: Optional[str] = None

    def run_once(
        self,
        on_open: Callable[[Any], None],
        on_message: Callable[[Any, str], None],
        on_error: Callable[[Any, Any], None],
        on_close: Callable[[Any, Any, Any], None],
    ) -> None:
        on_open(None)
        log_path = self.source["log_path"]
        poll_seconds = float(self.source.get("poll_seconds", 1.0) or 1.0)

        while not self._stop_event.is_set():
            try:
                with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                payload = parse_oai_mac_stats_text(text)
                if payload is not None:
                    signature = str(payload.get("oai_mac_stats"))
                    if signature != self._last_signature:
                        self._last_signature = signature
                        on_message(None, json.dumps(payload, ensure_ascii=False))
            except FileNotFoundError as exc:
                on_error(None, exc)
            except Exception as exc:
                on_error(None, exc)

            self._stop_event.wait(max(0.1, poll_seconds))

        on_close(None, None, "stopped")

    def stop(self) -> None:
        self._stop_event.set()


def build_transport_adapter(source: Dict[str, Any]) -> SourceTransportAdapter:
    """Build the transport adapter for *source*.

    ``websocket_json`` is the srsRAN fallback; ``oai_mac_stats`` is the
    OAI-first path.
    """
    transport = str(source.get("transport") or "websocket_json")
    if transport == "websocket_json":
        return WebSocketSourceAdapter(source)
    if transport == "oai_mac_stats":
        return OaiMacStatsFileAdapter(source)
    raise ValueError(f"Unsupported source transport: {transport}")
