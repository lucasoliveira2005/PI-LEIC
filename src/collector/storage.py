"""Durable event storage: JSONL rotation (EventWriter) and SQLite sink (SQLiteEventSink)."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

from shared.identity import extract_cell_ue_entities
from shared.structured_logging import emit_structured_log


_LOG_SERVICE = "metrics_collector"


class SQLiteEventSink:
    """Persist normalized metrics events and per-entity cells rows in SQLite."""

    def __init__(
        self,
        db_path: Any,
        timeout_seconds: float = 5.0,
        retention_max_age_days: float = 0.0,
        retention_max_rows: int = 0,
        retention_interval_events: int = 500,
        retention_vacuum: bool = False,
    ):
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
        self.retention_max_age_days = max(0.0, float(retention_max_age_days))
        self.retention_max_rows = max(0, int(retention_max_rows))
        self.retention_interval_events = max(1, int(retention_interval_events))
        self.retention_vacuum = bool(retention_vacuum)
        self.events_since_retention = 0
        self._retention_lock = threading.Lock()
        self._initialize_schema()

    def _initialize_schema(self) -> None:
        with self.conn:
            self.conn.execute(
                """
                CREATE TABLE IF NOT EXISTS metrics_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    collector_timestamp TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    gnb_id TEXT,
                    source_endpoint TEXT,
                    metric_family TEXT,
                    event_type TEXT,
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

            # Forward migrations for DBs created before these columns were added.
            for column_def in (
                "ALTER TABLE metrics_events ADD COLUMN event_type TEXT",
                "ALTER TABLE metrics_events ADD COLUMN source_endpoint TEXT",
            ):
                try:
                    self.conn.execute(column_def)
                except sqlite3.OperationalError:
                    pass  # Column already exists.

    def write_event(self, event: dict) -> None:
        collector_timestamp = (
            event.get("collector_timestamp") or datetime.now(timezone.utc).isoformat()
        )
        metric_family = event.get("metric_family") or "unknown"
        raw_json = json.dumps(event, ensure_ascii=False)

        with self.conn:
            cursor = self.conn.execute(
                """
                INSERT INTO metrics_events (
                    collector_timestamp,
                    source_id,
                    gnb_id,
                    source_endpoint,
                    metric_family,
                    event_type,
                    event_timestamp,
                    raw_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    collector_timestamp,
                    event.get("source_id"),
                    event.get("gnb_id"),
                    event.get("source_endpoint"),
                    metric_family,
                    event.get("event_type"),
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

        self._maybe_apply_retention()

    def _maybe_apply_retention(self) -> None:
        with self._retention_lock:
            self.events_since_retention += 1
            if self.events_since_retention < self.retention_interval_events:
                return
            self.events_since_retention = 0

        deleted_rows = self._apply_retention_policies()
        if deleted_rows > 0:
            emit_structured_log(
                "sqlite.retention_pruned",
                f"SQLite retention pruned {deleted_rows} event row(s).",
                service=_LOG_SERVICE,
                deleted_rows=deleted_rows,
                sqlite_path=self.db_path,
            )

    def _apply_retention_policies(self) -> int:
        if self.retention_max_age_days <= 0 and self.retention_max_rows <= 0:
            return 0

        deleted_rows = 0

        with self.conn:
            before_changes = self.conn.total_changes

            if self.retention_max_age_days > 0:
                threshold_timestamp = (
                    datetime.now(timezone.utc) - timedelta(days=self.retention_max_age_days)
                ).isoformat()
                self.conn.execute(
                    "DELETE FROM metrics_events WHERE collector_timestamp < ?",
                    (threshold_timestamp,),
                )

            if self.retention_max_rows > 0:
                current_rows = self.conn.execute(
                    "SELECT COUNT(*) FROM metrics_events"
                ).fetchone()[0]
                overflow_rows = current_rows - self.retention_max_rows
                if overflow_rows > 0:
                    self.conn.execute(
                        """
                        DELETE FROM metrics_events
                        WHERE id IN (
                            SELECT id FROM metrics_events
                            ORDER BY collector_timestamp ASC, id ASC
                            LIMIT ?
                        )
                        """,
                        (int(overflow_rows),),
                    )

            self.conn.execute("ANALYZE")
            deleted_rows = self.conn.total_changes - before_changes

        if deleted_rows > 0 and self.retention_vacuum:
            try:
                self.conn.execute("VACUUM")
            except sqlite3.Error:
                pass

        return max(0, int(deleted_rows))


class EventWriter:
    """Thread-safe writer that appends JSONL and best-effort SQLite mirrors."""

    def __init__(
        self,
        output_path: Any,
        rotate_max_bytes: int = 0,
        rotate_max_files: int = 0,
        sqlite_enabled: bool = False,
        sqlite_path: Optional[Any] = None,
        sqlite_timeout_seconds: float = 5.0,
        sqlite_retry_max_failures: int = 5,
        sqlite_retry_cooldown_seconds: float = 10.0,
        sqlite_retention_max_age_days: float = 0.0,
        sqlite_retention_max_rows: int = 0,
        sqlite_retention_interval_events: int = 500,
        sqlite_retention_vacuum: bool = False,
    ):
        self.output_path = Path(output_path)
        self.rotate_max_bytes = max(0, rotate_max_bytes)
        self.rotate_max_files = max(0, rotate_max_files)
        self.lock = threading.Lock()
        self.sqlite_enabled = bool(sqlite_enabled and sqlite_path is not None)
        self.sqlite_path = Path(sqlite_path) if sqlite_path is not None else None
        self.sqlite_timeout_seconds = sqlite_timeout_seconds
        self.sqlite_retry_max_failures = max(1, int(sqlite_retry_max_failures))
        self.sqlite_retry_cooldown_seconds = max(0.0, float(sqlite_retry_cooldown_seconds))
        self.sqlite_retention_max_age_days = max(0.0, float(sqlite_retention_max_age_days))
        self.sqlite_retention_max_rows = max(0, int(sqlite_retention_max_rows))
        self.sqlite_retention_interval_events = max(1, int(sqlite_retention_interval_events))
        self.sqlite_retention_vacuum = bool(sqlite_retention_vacuum)
        self.sqlite_consecutive_failures = 0
        self.sqlite_next_retry_monotonic = 0.0
        self.sqlite_sink: Optional[SQLiteEventSink] = None

        if self.sqlite_enabled:
            self._attempt_sqlite_connect(log_on_failure=True)

    def _log_sqlite_failure_threshold(self) -> None:
        if self.sqlite_consecutive_failures == self.sqlite_retry_max_failures:
            emit_structured_log(
                "sqlite.failure_threshold_reached",
                "SQLite failure threshold reached; continuing JSONL writes while "
                "periodically retrying SQLite.",
                level="warning",
                service=_LOG_SERVICE,
                sqlite_path=self.sqlite_path,
                consecutive_failures=self.sqlite_consecutive_failures,
                retry_max_failures=self.sqlite_retry_max_failures,
            )

    def _attempt_sqlite_connect(self, log_on_failure: bool) -> bool:
        if not self.sqlite_enabled or self.sqlite_path is None:
            return False

        try:
            self.sqlite_sink = SQLiteEventSink(
                self.sqlite_path,
                timeout_seconds=self.sqlite_timeout_seconds,
                retention_max_age_days=self.sqlite_retention_max_age_days,
                retention_max_rows=self.sqlite_retention_max_rows,
                retention_interval_events=self.sqlite_retention_interval_events,
                retention_vacuum=self.sqlite_retention_vacuum,
            )
            if self.sqlite_consecutive_failures > 0:
                emit_structured_log(
                    "sqlite.recovered",
                    f"SQLite sink recovered after {self.sqlite_consecutive_failures} "
                    "consecutive failure(s).",
                    service=_LOG_SERVICE,
                    sqlite_path=self.sqlite_path,
                    consecutive_failures=self.sqlite_consecutive_failures,
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
                emit_structured_log(
                    "sqlite.unavailable",
                    f"SQLite sink unavailable "
                    f"(failure {self.sqlite_consecutive_failures}/"
                    f"{self.sqlite_retry_max_failures}); "
                    f"retrying in {self.sqlite_retry_cooldown_seconds:.1f}s: {exc}",
                    level="warning",
                    service=_LOG_SERVICE,
                    sqlite_path=self.sqlite_path,
                    consecutive_failures=self.sqlite_consecutive_failures,
                    retry_max_failures=self.sqlite_retry_max_failures,
                    retry_cooldown_seconds=self.sqlite_retry_cooldown_seconds,
                    error=str(exc),
                )
                self._log_sqlite_failure_threshold()

            return False

    def _write_to_sqlite_with_recovery(self, event: dict) -> None:
        if not self.sqlite_enabled:
            return

        if self.sqlite_sink is None:
            if time.monotonic() < self.sqlite_next_retry_monotonic:
                return
            if not self._attempt_sqlite_connect(log_on_failure=True):
                return

        try:
            self.sqlite_sink.write_event(event)  # type: ignore[union-attr]
        except Exception as exc:
            self.sqlite_sink = None
            self.sqlite_consecutive_failures += 1
            self.sqlite_next_retry_monotonic = (
                time.monotonic() + self.sqlite_retry_cooldown_seconds
            )
            emit_structured_log(
                "sqlite.write_failed",
                f"SQLite sink write failed "
                f"(failure {self.sqlite_consecutive_failures}/"
                f"{self.sqlite_retry_max_failures}); "
                f"retrying in {self.sqlite_retry_cooldown_seconds:.1f}s: {exc}",
                level="warning",
                service=_LOG_SERVICE,
                sqlite_path=self.sqlite_path,
                consecutive_failures=self.sqlite_consecutive_failures,
                retry_max_failures=self.sqlite_retry_max_failures,
                retry_cooldown_seconds=self.sqlite_retry_cooldown_seconds,
                error=str(exc),
            )
            self._log_sqlite_failure_threshold()

    def _rotated_path(self, index: int) -> Path:
        return self.output_path.with_name(f"{self.output_path.name}.{index}")

    def _rotate_if_needed(self) -> None:
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

    def write(self, event: dict) -> None:
        line = json.dumps(event, ensure_ascii=False)
        with self.lock:
            self._rotate_if_needed()
            with self.output_path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
                f.flush()

            self._write_to_sqlite_with_recovery(event)
