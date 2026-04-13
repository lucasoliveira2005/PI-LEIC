#!/usr/bin/env python3
import json
import os
import sqlite3
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import websocket

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from metrics_identity import extract_cell_ue_entities

SOURCES_CONFIG = Path(
    os.environ.get("METRICS_SOURCES_CONFIG", SCRIPT_DIR / "../config/metrics_sources.json")
)
OUT = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))
RECONNECT_SECONDS = float(os.environ.get("METRICS_RECONNECT_SECONDS", "3"))


def parse_non_negative_int_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got: {raw}") from exc

    if value < 0:
        raise ValueError(f"{name} must be >= 0, got: {value}")

    return value


def parse_positive_int_env(name, default):
    value = parse_non_negative_int_env(name, default)
    if value <= 0:
        raise ValueError(f"{name} must be > 0, got: {value}")
    return value


def parse_non_negative_float_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a float, got: {raw}") from exc

    if value < 0:
        raise ValueError(f"{name} must be >= 0, got: {value}")

    return value


def parse_bool_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default

    return raw.strip().lower() not in {"0", "false", "no", "off"}


ROTATE_MAX_BYTES = parse_non_negative_int_env("METRICS_ROTATE_MAX_BYTES", 50 * 1024 * 1024)
ROTATE_MAX_FILES = parse_non_negative_int_env("METRICS_ROTATE_MAX_FILES", 5)
METRICS_SQLITE_ENABLED = parse_bool_env("METRICS_SQLITE_ENABLED", True)
METRICS_SQLITE_PATH = Path(os.environ.get("METRICS_SQLITE_PATH", "/tmp/pi-leic-metrics.sqlite"))
METRICS_SQLITE_TIMEOUT_SECONDS = parse_non_negative_float_env(
    "METRICS_SQLITE_TIMEOUT_SECONDS",
    5.0,
)
METRICS_SQLITE_RETRY_MAX_FAILURES = parse_positive_int_env(
    "METRICS_SQLITE_RETRY_MAX_FAILURES",
    5,
)
METRICS_SQLITE_RETRY_COOLDOWN_SECONDS = parse_non_negative_float_env(
    "METRICS_SQLITE_RETRY_COOLDOWN_SECONDS",
    10.0,
)


def load_sources():
    with SOURCES_CONFIG.open("r", encoding="utf-8") as f:
        sources = json.load(f)

    if not isinstance(sources, list) or not sources:
        raise ValueError(f"Expected a non-empty list in {SOURCES_CONFIG}")

    required_keys = {"source_id", "gnb_id", "ws_url"}
    for source in sources:
        missing = required_keys.difference(source)
        if missing:
            missing_str = ", ".join(sorted(missing))
            raise ValueError(f"Missing keys in source config {source}: {missing_str}")

    return sources


def metric_family(payload):
    if "cells" in payload:
        return "cells"
    if "rlc_metrics" in payload:
        return "rlc_metrics"
    if "du_low" in payload:
        return "du_low"
    if "du" in payload:
        return "du"

    for key in payload:
        if key != "timestamp":
            return key

    return "unknown"


def extract_context(payload):
    context = {}

    cells = payload.get("cells") or []
    if cells:
        # For cells payloads, authoritative UE/cell context lives inside raw_payload.
        # Avoid ambiguous top-level fields derived from the first entity only.
        return context

    rlc_metrics = payload.get("rlc_metrics")
    if isinstance(rlc_metrics, dict):
        if "ue_id" in rlc_metrics:
            context["ue"] = rlc_metrics["ue_id"]
        if "du_id" in rlc_metrics:
            context["cell_index"] = rlc_metrics["du_id"]

    du = payload.get("du") or {}
    mac_dl = (
        du.get("du_high", {})
        .get("mac", {})
        .get("dl", [])
    )
    if mac_dl and isinstance(mac_dl[0], dict) and "pci" in mac_dl[0]:
        context["pci"] = mac_dl[0]["pci"]

    return context


def enrich_event(source, payload):
    event = {
        "collector_timestamp": datetime.now(timezone.utc).isoformat(),
        "source_id": source["source_id"],
        "gnb_id": source["gnb_id"],
        "ws_url": source["ws_url"],
        "metric_family": metric_family(payload),
        "timestamp": payload.get("timestamp"),
        "raw_payload": payload,
    }
    event.update(extract_context(payload))
    return event


def summarize_event(event):
    payload = event["raw_payload"]
    family = event["metric_family"]
    source_id = event["source_id"]

    if family == "cells":
        entities = extract_cell_ue_entities(payload)
        if entities:
            sample = entities[0]
            sample_ue = sample.get("ue") or {}
            snr = sample_ue.get("pucch_snr_db", sample_ue.get("pusch_snr_db", 0))
            return (
                f"[{source_id}] cells "
                f"entities={len(entities)}"
                f" sample={sample.get('ue_identity', '-') }"
                f" dl={sample_ue.get('dl_brate', 0):.1f}"
                f" ul={sample_ue.get('ul_brate', 0):.1f}"
                f" snr={snr:.2f}"
            )

        return f"[{source_id}] cells entities=0"

    return f"[{source_id}] {family} timestamp={event.get('timestamp') or '-'}"


class SQLiteEventSink:
    def __init__(self, db_path, timeout_seconds=5.0):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(
            str(self.db_path),
            timeout=timeout_seconds,
            check_same_thread=False,
        )
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self._initialize_schema()

    def _initialize_schema(self):
        with self.conn:
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS metrics_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    collector_timestamp TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    gnb_id TEXT,
                    ws_url TEXT,
                    metric_family TEXT,
                    event_timestamp TEXT,
                    raw_json TEXT NOT NULL
                )
                """
            )
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS metrics_cell_entities (
                    event_id INTEGER NOT NULL,
                    source_id TEXT NOT NULL,
                    collector_timestamp TEXT NOT NULL,
                    event_timestamp TEXT,
                    cell_index INTEGER NOT NULL,
                    ue_index INTEGER NOT NULL,
                    ue_identity TEXT NOT NULL,
                    pci INTEGER,
                    dl_brate REAL,
                    ul_brate REAL,
                    signal_db REAL,
                    ue_json TEXT NOT NULL,
                    PRIMARY KEY (event_id, cell_index, ue_index),
                    FOREIGN KEY (event_id) REFERENCES metrics_events(id) ON DELETE CASCADE
                )
                """
            )
            self.conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_metrics_events_source_collector
                ON metrics_events(source_id, collector_timestamp DESC)
                """
            )
            self.conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_metrics_events_family_collector
                ON metrics_events(metric_family, collector_timestamp DESC)
                """
            )
            self.conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_metrics_cell_entities_latest
                ON metrics_cell_entities(source_id, collector_timestamp DESC, cell_index, ue_identity)
                """
            )

    def write_event(self, event):
        collector_timestamp = event.get("collector_timestamp") or datetime.now(timezone.utc).isoformat()
        metric_family = event.get("metric_family") or "unknown"
        raw_json = json.dumps(event, ensure_ascii=False)

        with self.conn:
            cursor = self.conn.execute(
                """
                INSERT INTO metrics_events (
                    collector_timestamp,
                    source_id,
                    gnb_id,
                    ws_url,
                    metric_family,
                    event_timestamp,
                    raw_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    collector_timestamp,
                    event.get("source_id"),
                    event.get("gnb_id"),
                    event.get("ws_url"),
                    metric_family,
                    event.get("timestamp"),
                    raw_json,
                ),
            )
            event_id = cursor.lastrowid

            if metric_family != "cells":
                return

            payload = event.get("raw_payload")
            if not isinstance(payload, dict):
                return

            entities = extract_cell_ue_entities(payload)
            for entity in entities:
                ue_metrics = entity.get("ue") or {}
                signal_db = ue_metrics.get("pucch_snr_db", ue_metrics.get("pusch_snr_db"))
                self.conn.execute(
                    """
                    INSERT OR REPLACE INTO metrics_cell_entities (
                        event_id,
                        source_id,
                        collector_timestamp,
                        event_timestamp,
                        cell_index,
                        ue_index,
                        ue_identity,
                        pci,
                        dl_brate,
                        ul_brate,
                        signal_db,
                        ue_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        event_id,
                        event.get("source_id"),
                        collector_timestamp,
                        event.get("timestamp"),
                        entity.get("cell_index", 0),
                        entity.get("ue_index", 0),
                        entity.get("ue_identity", "cell0-ue0"),
                        entity.get("pci"),
                        float(ue_metrics.get("dl_brate", 0) or 0),
                        float(ue_metrics.get("ul_brate", 0) or 0),
                        float(signal_db) if signal_db is not None else None,
                        json.dumps(ue_metrics, ensure_ascii=False),
                    ),
                )


class EventWriter:
    def __init__(
        self,
        output_path,
        rotate_max_bytes=0,
        rotate_max_files=0,
        sqlite_enabled=False,
        sqlite_path=None,
        sqlite_timeout_seconds=5.0,
        sqlite_retry_max_failures=5,
        sqlite_retry_cooldown_seconds=10.0,
    ):
        self.output_path = output_path
        self.rotate_max_bytes = max(0, rotate_max_bytes)
        self.rotate_max_files = max(0, rotate_max_files)
        self.lock = threading.Lock()
        self.sqlite_enabled = bool(sqlite_enabled and sqlite_path is not None)
        self.sqlite_path = Path(sqlite_path) if sqlite_path is not None else None
        self.sqlite_timeout_seconds = sqlite_timeout_seconds
        self.sqlite_retry_max_failures = max(1, int(sqlite_retry_max_failures))
        self.sqlite_retry_cooldown_seconds = max(0.0, float(sqlite_retry_cooldown_seconds))
        self.sqlite_consecutive_failures = 0
        self.sqlite_next_retry_monotonic = 0.0
        self.sqlite_sink = None

        if self.sqlite_enabled:
            self._attempt_sqlite_connect(log_on_failure=True)

    def _log_sqlite_failure_threshold(self):
        if self.sqlite_consecutive_failures == self.sqlite_retry_max_failures:
            print(
                "SQLite failure threshold reached; continuing JSONL writes while "
                "periodically retrying SQLite.",
                flush=True,
            )

    def _attempt_sqlite_connect(self, log_on_failure):
        if not self.sqlite_enabled or self.sqlite_path is None:
            return False

        try:
            self.sqlite_sink = SQLiteEventSink(
                self.sqlite_path,
                timeout_seconds=self.sqlite_timeout_seconds,
            )
            if self.sqlite_consecutive_failures > 0:
                print(
                    "SQLite sink recovered after "
                    f"{self.sqlite_consecutive_failures} consecutive failure(s).",
                    flush=True,
                )
            self.sqlite_consecutive_failures = 0
            self.sqlite_next_retry_monotonic = 0.0
            return True
        except Exception as exc:
            self.sqlite_sink = None
            self.sqlite_consecutive_failures += 1
            self.sqlite_next_retry_monotonic = (
                time.monotonic() + self.sqlite_retry_cooldown_seconds
            )

            if log_on_failure:
                print(
                    "SQLite sink unavailable "
                    f"(failure {self.sqlite_consecutive_failures}/"
                    f"{self.sqlite_retry_max_failures}); "
                    f"retrying in {self.sqlite_retry_cooldown_seconds:.1f}s: {exc}",
                    flush=True,
                )
                self._log_sqlite_failure_threshold()

            return False

    def _write_to_sqlite_with_recovery(self, event):
        if not self.sqlite_enabled:
            return

        if self.sqlite_sink is None:
            if time.monotonic() < self.sqlite_next_retry_monotonic:
                return
            if not self._attempt_sqlite_connect(log_on_failure=True):
                return

        try:
            self.sqlite_sink.write_event(event)
        except Exception as exc:
            self.sqlite_sink = None
            self.sqlite_consecutive_failures += 1
            self.sqlite_next_retry_monotonic = (
                time.monotonic() + self.sqlite_retry_cooldown_seconds
            )
            print(
                "SQLite sink write failed "
                f"(failure {self.sqlite_consecutive_failures}/"
                f"{self.sqlite_retry_max_failures}); "
                f"retrying in {self.sqlite_retry_cooldown_seconds:.1f}s: {exc}",
                flush=True,
            )
            self._log_sqlite_failure_threshold()

    def _rotated_path(self, index):
        return self.output_path.with_name(f"{self.output_path.name}.{index}")

    def _rotate_if_needed(self):
        if self.rotate_max_bytes <= 0 or self.rotate_max_files <= 0:
            return

        if not self.output_path.exists():
            return

        if self.output_path.stat().st_size < self.rotate_max_bytes:
            return

        oldest = self._rotated_path(self.rotate_max_files)
        if oldest.exists():
            oldest.unlink()

        for index in range(self.rotate_max_files - 1, 0, -1):
            src = self._rotated_path(index)
            dst = self._rotated_path(index + 1)
            if src.exists():
                src.replace(dst)

        self.output_path.replace(self._rotated_path(1))

    def write(self, event):
        line = json.dumps(event, ensure_ascii=False)
        with self.lock:
            self._rotate_if_needed()
            with self.output_path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
                f.flush()

            self._write_to_sqlite_with_recovery(event)


class MetricsSourceWorker:
    def __init__(self, source, writer):
        self.source = source
        self.writer = writer

    def on_open(self, ws):
        print(f"[{self.source['source_id']}] Connected to {self.source['ws_url']}", flush=True)
        ws.send(json.dumps({"cmd": "metrics_subscribe"}))
        print(f"[{self.source['source_id']}] Subscribed to metrics", flush=True)

    def on_message(self, _ws, message):
        try:
            payload = json.loads(message)
        except json.JSONDecodeError:
            print(f"[{self.source['source_id']}] Non-JSON message: {message}", flush=True)
            return

        if "cmd" in payload:
            print(f"[{self.source['source_id']}] Control message: {payload}", flush=True)
            return

        event = enrich_event(self.source, payload)
        self.writer.write(event)
        print(summarize_event(event), flush=True)

    def on_error(self, _ws, error):
        print(f"[{self.source['source_id']}] WebSocket error: {error}", flush=True)

    def on_close(self, _ws, close_status_code, close_msg):
        print(
            f"[{self.source['source_id']}] Closed: {close_status_code} {close_msg}",
            flush=True,
        )

    def run(self):
        while True:
            try:
                app = websocket.WebSocketApp(
                    self.source["ws_url"],
                    on_open=self.on_open,
                    on_message=self.on_message,
                    on_error=self.on_error,
                    on_close=self.on_close,
                )
                app.run_forever()
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                print(f"[{self.source['source_id']}] Unexpected error: {exc}", flush=True)

            print(
                f"[{self.source['source_id']}] Reconnecting in {RECONNECT_SECONDS} seconds...",
                flush=True,
            )
            time.sleep(RECONNECT_SECONDS)


def main():
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
    )

    print(f"Metrics collector ready. Sources: {SOURCES_CONFIG.resolve()}", flush=True)
    print(f"Writing enriched metrics to: {OUT.resolve()}", flush=True)
    if ROTATE_MAX_BYTES > 0 and ROTATE_MAX_FILES > 0:
        print(
            "Rotation enabled: "
            f"METRICS_ROTATE_MAX_BYTES={ROTATE_MAX_BYTES}, "
            f"METRICS_ROTATE_MAX_FILES={ROTATE_MAX_FILES}",
            flush=True,
        )
    else:
        print("Rotation disabled for metrics output.", flush=True)

    if METRICS_SQLITE_ENABLED:
        print(
            "SQLite cache enabled: "
            f"METRICS_SQLITE_PATH={METRICS_SQLITE_PATH} "
            f"(timeout={METRICS_SQLITE_TIMEOUT_SECONDS}s, "
            f"retry_max_failures={METRICS_SQLITE_RETRY_MAX_FAILURES}, "
            f"retry_cooldown={METRICS_SQLITE_RETRY_COOLDOWN_SECONDS}s)",
            flush=True,
        )
    else:
        print("SQLite cache disabled for metrics output.", flush=True)

    threads = []
    for source in sources:
        worker = MetricsSourceWorker(source, writer)
        thread = threading.Thread(target=worker.run, name=source["source_id"], daemon=True)
        thread.start()
        threads.append(thread)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nStopping metrics collector.", flush=True)


if __name__ == "__main__":
    main()
