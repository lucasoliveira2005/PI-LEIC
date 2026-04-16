"""Source worker threads, watchdog, and the collector main() entry point."""

from __future__ import annotations

import json
import signal
import threading
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from .config import (
    METRICS_SCHEMA_VERSION,
    METRICS_SILENCE_THRESHOLD_SECONDS,
    METRICS_SQLITE_ENABLED,
    METRICS_SQLITE_PATH,
    METRICS_SQLITE_RETENTION_INTERVAL_EVENTS,
    METRICS_SQLITE_RETENTION_MAX_AGE_DAYS,
    METRICS_SQLITE_RETENTION_MAX_ROWS,
    METRICS_SQLITE_RETENTION_VACUUM,
    METRICS_SQLITE_RETRY_COOLDOWN_SECONDS,
    METRICS_SQLITE_RETRY_MAX_FAILURES,
    METRICS_SQLITE_TIMEOUT_SECONDS,
    METRICS_TRANSPORT_BACKEND,
    METRICS_WS_PING_INTERVAL_SECONDS,
    METRICS_WS_PING_TIMEOUT_SECONDS,
    OUT,
    RECONNECT_SECONDS,
    ROTATE_MAX_BYTES,
    ROTATE_MAX_FILES,
    SOURCES_CONFIG,
    _WATCHDOG_POLL_SECONDS,
)
from .enrichment import enrich_event, load_sources, source_endpoint, summarize_event
from .storage import EventWriter
from .transport import build_transport_adapter


class MetricsSourceWorker:
    """Transport-agnostic worker that subscribes to one metrics source and writes events."""

    def __init__(
        self,
        source: Dict[str, Any],
        writer: EventWriter,
        stop_event: Optional[threading.Event] = None,
    ):
        self.source = source
        self.writer = writer
        self.transport_adapter = build_transport_adapter(source)
        # Shared stop event; if not provided, each worker owns its own (useful in tests).
        self.stop_event: threading.Event = (
            stop_event if stop_event is not None else threading.Event()
        )
        # Set to the monotonic clock value on every received message; used by the watchdog.
        self.last_message_monotonic: Optional[float] = None
        # True after the first watchdog alert is emitted for the current silence window;
        # reset to False on the next received message (rate-limits log spam).
        self._silence_alert_sent: bool = False

    def stop(self) -> None:
        """Signal this worker to stop and interrupt any blocking transport call."""
        self.stop_event.set()
        self.transport_adapter.stop()

    def on_open(self, ws: Any) -> None:
        print(
            f"[{self.source['source_id']}] Connected to {source_endpoint(self.source)} "
            f"via {METRICS_TRANSPORT_BACKEND}",
            flush=True,
        )

        if METRICS_TRANSPORT_BACKEND == "websocket":
            ws.send(json.dumps({"cmd": "metrics_subscribe"}))
            print(f"[{self.source['source_id']}] Subscribed to metrics", flush=True)

    def on_message(self, _ws: Any, message: str) -> None:
        try:
            payload = json.loads(message)
        except json.JSONDecodeError:
            print(f"[{self.source['source_id']}] Non-JSON message: {message}", flush=True)
            return

        if not isinstance(payload, dict):
            # Reject non-dict JSON (list, null, scalar) — enrich_event expects a dict.
            print(
                f"[{self.source['source_id']}] Unexpected payload type "
                f"{type(payload).__name__}: {message[:120]}",
                flush=True,
            )
            return

        if "cmd" in payload:
            print(f"[{self.source['source_id']}] Control message: {payload}", flush=True)
            return

        self.last_message_monotonic = time.monotonic()
        self._silence_alert_sent = False
        event = enrich_event(self.source, payload)
        self.writer.write(event)
        print(summarize_event(event), flush=True)

    def on_error(self, _ws: Any, error: Any) -> None:
        print(f"[{self.source['source_id']}] WebSocket error: {error}", flush=True)

    def on_close(self, _ws: Any, close_status_code: Any, close_msg: Any) -> None:
        print(
            f"[{self.source['source_id']}] Closed: {close_status_code} {close_msg}",
            flush=True,
        )

    def run(self) -> None:
        while not self.stop_event.is_set():
            try:
                self.transport_adapter.run_once(
                    self.on_open,
                    self.on_message,
                    self.on_error,
                    self.on_close,
                )
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                print(f"[{self.source['source_id']}] Unexpected error: {exc}", flush=True)

            if self.stop_event.is_set():
                break

            print(
                f"[{self.source['source_id']}] Reconnecting in {RECONNECT_SECONDS} seconds...",
                flush=True,
            )
            # Event.wait() returns immediately when stop_event is set, allowing fast shutdown
            # during the reconnect backoff window.
            self.stop_event.wait(RECONNECT_SECONDS)


def _watchdog_loop(workers: List[MetricsSourceWorker], stop_event: threading.Event) -> None:
    """Periodically check each worker for source silence and emit a diagnostic event.

    A source is considered silent when no message has been received for longer than
    METRICS_SILENCE_THRESHOLD_SECONDS.  One warning is printed and one synthetic
    ``metric_family=state`` event is written to JSONL per silence window; the alert
    resets automatically when the next real message arrives.
    """
    if METRICS_SILENCE_THRESHOLD_SECONDS <= 0:
        return

    # stop_event.wait() returns True when the event is set (shutdown), False on timeout.
    while not stop_event.wait(_WATCHDOG_POLL_SECONDS):
        now = time.monotonic()
        for worker in workers:
            last = worker.last_message_monotonic
            if last is None:
                # Source has not sent any message yet; connection may still be opening.
                continue
            silence = now - last
            if silence <= METRICS_SILENCE_THRESHOLD_SECONDS:
                # Back inside the window — reset the alert flag so we re-alert next time.
                worker._silence_alert_sent = False
                continue
            if worker._silence_alert_sent:
                continue
            worker._silence_alert_sent = True
            source_id = worker.source["source_id"]
            print(
                f"[{source_id}] WATCHDOG: silent for {silence:.0f}s "
                f"(threshold={METRICS_SILENCE_THRESHOLD_SECONDS:.0f}s)",
                flush=True,
            )
            try:
                now_iso = datetime.now(timezone.utc).isoformat()
                silent_event = {
                    "collector_timestamp": now_iso,
                    "source_id": source_id,
                    "gnb_id": worker.source.get("gnb_id", source_id),
                    "source_endpoint": source_endpoint(worker.source),
                    "metric_family": "state",
                    "event_type": "state",
                    "schema_version": METRICS_SCHEMA_VERSION,
                    "timestamp": now_iso,
                    "raw_payload": {
                        "status": "silent",
                        "silence_seconds": round(silence, 1),
                    },
                    "status": "silent",
                }
                worker.writer.write(silent_event)
            except Exception as exc:
                print(
                    f"[{source_id}] WATCHDOG: failed to write silent event: {exc}",
                    flush=True,
                )


def main() -> None:
    if METRICS_TRANSPORT_BACKEND == "zmq":
        raise RuntimeError(
            "ZMQ transport is not yet implemented. "
            "Set METRICS_TRANSPORT_BACKEND=websocket (the default)."
        )

    sources = load_sources()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    writer = EventWriter(
        OUT,
        rotate_max_bytes=ROTATE_MAX_BYTES,
        rotate_max_files=ROTATE_MAX_FILES,
        sqlite_enabled=METRICS_SQLITE_ENABLED,
        sqlite_path=METRICS_SQLITE_PATH,
        sqlite_timeout_seconds=METRICS_SQLITE_TIMEOUT_SECONDS,
        sqlite_retry_max_failures=METRICS_SQLITE_RETRY_MAX_FAILURES,
        sqlite_retry_cooldown_seconds=METRICS_SQLITE_RETRY_COOLDOWN_SECONDS,
        sqlite_retention_max_age_days=METRICS_SQLITE_RETENTION_MAX_AGE_DAYS,
        sqlite_retention_max_rows=METRICS_SQLITE_RETENTION_MAX_ROWS,
        sqlite_retention_interval_events=METRICS_SQLITE_RETENTION_INTERVAL_EVENTS,
        sqlite_retention_vacuum=METRICS_SQLITE_RETENTION_VACUUM,
    )

    print(f"Metrics collector ready. Sources: {SOURCES_CONFIG.resolve()}", flush=True)
    print(f"Writing enriched metrics to: {OUT.resolve()}", flush=True)
    if ROTATE_MAX_BYTES > 0 and ROTATE_MAX_FILES > 0:
        print(
            f"Rotation enabled: METRICS_ROTATE_MAX_BYTES={ROTATE_MAX_BYTES}, "
            f"METRICS_ROTATE_MAX_FILES={ROTATE_MAX_FILES}",
            flush=True,
        )
    else:
        print("Rotation disabled for metrics output.", flush=True)

    if METRICS_SQLITE_ENABLED:
        print(
            f"SQLite cache enabled: METRICS_SQLITE_PATH={METRICS_SQLITE_PATH} "
            f"(timeout={METRICS_SQLITE_TIMEOUT_SECONDS}s, "
            f"retry_max_failures={METRICS_SQLITE_RETRY_MAX_FAILURES}, "
            f"retry_cooldown={METRICS_SQLITE_RETRY_COOLDOWN_SECONDS}s, "
            f"retention_max_age_days={METRICS_SQLITE_RETENTION_MAX_AGE_DAYS}, "
            f"retention_max_rows={METRICS_SQLITE_RETENTION_MAX_ROWS}, "
            f"retention_interval_events={METRICS_SQLITE_RETENTION_INTERVAL_EVENTS}, "
            f"retention_vacuum={1 if METRICS_SQLITE_RETENTION_VACUUM else 0})",
            flush=True,
        )
    else:
        print("SQLite cache disabled for metrics output.", flush=True)

    print(f"Transport backend: METRICS_TRANSPORT_BACKEND={METRICS_TRANSPORT_BACKEND}", flush=True)

    if METRICS_TRANSPORT_BACKEND == "websocket" and METRICS_WS_PING_INTERVAL_SECONDS > 0:
        print(
            f"WebSocket keepalive enabled: ping_interval={METRICS_WS_PING_INTERVAL_SECONDS}s, "
            f"ping_timeout={METRICS_WS_PING_TIMEOUT_SECONDS}s",
            flush=True,
        )
    elif METRICS_TRANSPORT_BACKEND == "websocket":
        print("WebSocket keepalive disabled.", flush=True)

    stop_event = threading.Event()
    workers: List[MetricsSourceWorker] = []

    def _handle_sigterm(_signum: Any, _frame: Any) -> None:
        print("\nReceived SIGTERM. Stopping metrics collector gracefully.", flush=True)
        stop_event.set()
        for w in workers:
            w.stop()

    signal.signal(signal.SIGTERM, _handle_sigterm)

    threads = []
    for source in sources:
        worker = MetricsSourceWorker(source, writer, stop_event=stop_event)
        thread = threading.Thread(target=worker.run, name=source["source_id"], daemon=True)
        thread.start()
        threads.append(thread)
        workers.append(worker)

    watchdog_thread = threading.Thread(
        target=_watchdog_loop,
        args=(workers, stop_event),
        name="watchdog",
        daemon=True,
    )
    watchdog_thread.start()

    try:
        # Main thread idles until stop_event is set (by SIGTERM handler) or
        # KeyboardInterrupt (Ctrl-C).  Event.wait(1) wakes immediately on set.
        while not stop_event.is_set():
            stop_event.wait(1.0)
    except KeyboardInterrupt:
        print("\nStopping metrics collector.", flush=True)
        stop_event.set()
        for w in workers:
            w.stop()

    # Give in-flight writes a moment to complete before the process exits.
    for thread in threads:
        thread.join(timeout=5.0)
