#!/usr/bin/env python3
"""REST interface for metrics and operator workflows in the network stack.

Sections
--------
Configuration       — env-var globals and snapshot-cache setup
Models              — Pydantic request/response types (imported from api_models)
Helpers             — metadata builders, cache, reader factory
Audit DB            — SQLite audit log schema and append
Alert Detection     — rule evaluation (_compute_current_alert_candidates)
Alert Lifecycle     — state transitions (_sync_alert_lifecycle, _load_alert_lifecycle_view)
Route Handlers      — GET /metrics, /alerts, /health, /capabilities; POST /query, /actions
Entry Point         — uvicorn runner (if __name__ == "__main__")
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import threading
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Query

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from api_models import ActionRequest, QueryRequest  # noqa: E402
from env_utils import (  # noqa: E402
    parse_bool_env,
    parse_float_env,
    parse_non_negative_float_env,
    parse_non_negative_int_env,
)
from metrics_api import MetricsLogReader, parse_timestamp_to_epoch  # noqa: E402
from metrics_liveness import settings_from_env  # noqa: E402

# ── Section: Configuration ─────────────────────────────────────────────────────

LOG_FILE = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))
LOG_INCLUDE_ROTATED = parse_bool_env("METRICS_LOG_INCLUDE_ROTATED", True)
LOG_MAX_ARCHIVES = parse_non_negative_int_env("METRICS_LOG_MAX_ARCHIVES", 5)
SQLITE_ENABLED = parse_bool_env("METRICS_SQLITE_ENABLED", True)
SQLITE_PATH = Path(os.environ.get("METRICS_SQLITE_PATH", "/tmp/pi-leic-metrics.sqlite"))

ALERT_STALE_AFTER_SECONDS = parse_non_negative_float_env("ALERT_STALE_AFTER_SECONDS", 30.0)
# -1.0 = disabled sentinel; use parse_float_env to allow negative values.
ALERT_MIN_DL_BRATE = parse_float_env("ALERT_MIN_DL_BRATE", -1.0)
ALERT_MIN_UL_BRATE = parse_float_env("ALERT_MIN_UL_BRATE", -1.0)
ALERT_RULESET_VERSION = os.environ.get("ALERT_RULESET_VERSION", "rules-v1")
API_SCHEMA_VERSION = os.environ.get("API_SCHEMA_VERSION", "1.0")
AUDIT_DB_ENABLED = parse_bool_env("API_AUDIT_DB_ENABLED", True)
AUDIT_DB_PATH = Path(os.environ.get("API_AUDIT_DB_PATH", "/tmp/pi-leic-api-audit.sqlite"))
AUDIT_DB_TIMEOUT_SECONDS = parse_non_negative_float_env("API_AUDIT_DB_TIMEOUT_SECONDS", 5.0)
API_HOST = os.environ.get("API_HOST", "0.0.0.0")
API_PORT = parse_non_negative_int_env("API_PORT", 8000) or 8000
QUERY_BACKEND_MODE = os.environ.get("QUERY_BACKEND_MODE", "heuristic-stub").strip() or "heuristic-stub"
LLM_INTEGRATED = False
ACTION_EXECUTION_MODE = "audit-only-stub"
ACTION_MUTATION_PIPELINE_ENABLED = False
INGESTION_TRANSPORT = os.environ.get("METRICS_INGESTION_TRANSPORT", "websocket").strip().lower() or "websocket"
D1_TARGET_TRANSPORT = os.environ.get("D1_TARGET_TRANSPORT", "zmq").strip().lower() or "zmq"
_AUDIT_SCHEMA_READY = False
_AUDIT_DB_LOCK = threading.Lock()
_SERVICE_START_MONOTONIC = time.monotonic()

# ---------------------------------------------------------------------------
# Snapshot cache — avoids re-reading SQLite/JSONL on every HTTP request.
# Both latest_cells_by_source() and latest_sample_epoch_by_source() are
# fetched together and cached for METRICS_SNAPSHOT_TTL_SECONDS seconds.
# Window queries (time-range) are never cached; they are always fresh reads.
# TTL is capped at _SNAPSHOT_TTL_MAX_SECONDS so a misconfigured value (e.g.
# METRICS_SNAPSHOT_TTL_SECONDS=99999) cannot serve indefinitely stale data
# after a source disappears.
# ---------------------------------------------------------------------------
_SNAPSHOT_TTL_MAX_SECONDS = 60.0
METRICS_SNAPSHOT_TTL_SECONDS = min(
    parse_non_negative_float_env("METRICS_SNAPSHOT_TTL_SECONDS", 5.0),
    _SNAPSHOT_TTL_MAX_SECONDS,
)
_SNAPSHOT_CACHE_LOCK = threading.Lock()
_snapshot_cache: Optional[Dict[str, Any]] = None  # {"snapshot": …, "sample_epochs": …, "expires_at": …}


@asynccontextmanager
async def _lifespan(app_: FastAPI):  # noqa: ARG001
    _ensure_audit_schema()
    yield


app = FastAPI(
    title="PI-LEIC Metrics API",
    version="1.0.0",
    description="Network-team REST interface for metrics, alerts, natural-language queries, and actions.",
    lifespan=_lifespan,
)


# ── Section: Helpers ──────────────────────────────────────────────────────────


def _new_request_id() -> str:
    return uuid.uuid4().hex


def _transport_metadata() -> Dict[str, str]:
    parity = "aligned" if INGESTION_TRANSPORT == D1_TARGET_TRANSPORT else "deferred"
    return {
        "ingestion": INGESTION_TRANSPORT,
        "d1_target": D1_TARGET_TRANSPORT,
        "parity": parity,
    }


def _capability_metadata() -> Dict[str, Any]:
    return {
        "query_backend_mode": QUERY_BACKEND_MODE,
        "llm_integrated": LLM_INTEGRATED,
        "action_execution_mode": ACTION_EXECUTION_MODE,
        "action_mutation_pipeline_enabled": ACTION_MUTATION_PIPELINE_ENABLED,
    }


def _freshness_metadata() -> Dict[str, Any]:
    settings = settings_from_env()
    return {
        "mode": settings.mode,
        "age_window_seconds": settings.age_window_seconds,
        "clock_skew_tolerance_seconds": settings.clock_skew_tolerance_seconds,
    }


def _storage_metadata() -> Dict[str, Any]:
    sqlite_available = SQLITE_ENABLED and SQLITE_PATH.exists()
    return {
        "active_mode": "sqlite" if sqlite_available else "jsonl",
        "sqlite_enabled": SQLITE_ENABLED,
        "sqlite_path": str(SQLITE_PATH),
        "sqlite_available": sqlite_available,
        "jsonl_path": str(LOG_FILE),
        "include_rotated": LOG_INCLUDE_ROTATED,
        "max_archives": LOG_MAX_ARCHIVES,
    }


def _reader() -> MetricsLogReader:
    return MetricsLogReader(
        LOG_FILE,
        include_rotated=LOG_INCLUDE_ROTATED,
        max_archives=LOG_MAX_ARCHIVES,
        sqlite_path=SQLITE_PATH if SQLITE_ENABLED else None,
        prefer_sqlite=SQLITE_ENABLED,
    )


def _cached_snapshot() -> tuple:
    """Return (latest_cells_by_source, latest_sample_epoch_by_source), served from
    a TTL cache to avoid hitting SQLite/JSONL on every request.

    Two concurrent requests may both trigger a fresh read if the cache expires
    simultaneously — that is intentional; a strict lock-per-read would serialise
    all traffic handlers for the duration of a DB query.
    """
    global _snapshot_cache
    now = time.monotonic()

    with _SNAPSHOT_CACHE_LOCK:
        if (
            _snapshot_cache is not None
            and METRICS_SNAPSHOT_TTL_SECONDS > 0
            and now < _snapshot_cache["expires_at"]
        ):
            return _snapshot_cache["snapshot"], _snapshot_cache["sample_epochs"]

    # Read outside the lock so concurrent requests don't serialise on I/O.
    reader = _reader()
    snapshot = reader.latest_cells_by_source()
    sample_epochs = reader.latest_sample_epoch_by_source()

    with _SNAPSHOT_CACHE_LOCK:
        _snapshot_cache = {
            "snapshot": snapshot,
            "sample_epochs": sample_epochs,
            "expires_at": now + METRICS_SNAPSHOT_TTL_SECONDS,
        }

    return snapshot, sample_epochs


def _sample_epoch(source_entry: Dict[str, Any]) -> Optional[float]:
    epoch = parse_timestamp_to_epoch(source_entry.get("timestamp"))
    if epoch is None:
        epoch = parse_timestamp_to_epoch(source_entry.get("collector_timestamp"))
    return epoch


def _parse_query_epoch(value: Optional[str], field_name: str) -> Optional[float]:
    if value is None:
        return None

    epoch = parse_timestamp_to_epoch(value)
    if epoch is None:
        raise HTTPException(status_code=400, detail=f"Invalid {field_name} timestamp: {value}")

    return epoch


def _entity_matches_cell(entity: Dict[str, Any], cell_id: str) -> bool:
    pci = entity.get("pci")
    if pci is not None and str(pci) == cell_id:
        return True

    cell_index = entity.get("cell_index")
    return cell_index is not None and str(cell_index) == cell_id


def _snapshot_summary(snapshot: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    source_count = len(snapshot)
    entity_count = 0
    for source_entry in snapshot.values():
        entities = source_entry.get("entities") or []
        entity_count += len(entities)

    return {
        "sources": source_count,
        "entities": entity_count,
    }


# ── Section: Audit DB ─────────────────────────────────────────────────────────


def _ensure_audit_schema() -> None:
    global _AUDIT_SCHEMA_READY
    if _AUDIT_SCHEMA_READY or not AUDIT_DB_ENABLED:
        return

    AUDIT_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(str(AUDIT_DB_PATH), timeout=AUDIT_DB_TIMEOUT_SECONDS) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS api_audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                event_type TEXT NOT NULL,
                payload_json TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_api_audit_log_created_at
            ON api_audit_log(created_at DESC)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS api_alert_state (
                alert_key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                entity TEXT,
                alert_type TEXT NOT NULL,
                severity TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                message TEXT NOT NULL,
                status TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                cleared_at TEXT,
                ack_by TEXT,
                context_json TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_api_alert_state_status_last_seen
            ON api_alert_state(status, last_seen_at DESC)
            """
        )

    _AUDIT_SCHEMA_READY = True


def _append_audit_event(event_type: str, payload: Dict[str, Any]) -> Optional[str]:
    if not AUDIT_DB_ENABLED:
        return None

    try:
        with _AUDIT_DB_LOCK:
            with sqlite3.connect(str(AUDIT_DB_PATH), timeout=AUDIT_DB_TIMEOUT_SECONDS) as conn:
                conn.execute(
                    """
                    INSERT INTO api_audit_log (created_at, event_type, payload_json)
                    VALUES (?, ?, ?)
                    """,
                    (
                        datetime.now(timezone.utc).isoformat(),
                        event_type,
                        json.dumps(payload, sort_keys=True, ensure_ascii=False),
                    ),
                )
    except sqlite3.Error as exc:
        return f"audit persistence failed: {exc}"

    return None


def _alert_key(alert: Dict[str, Any]) -> str:
    source_id = str(alert.get("source_id", "unknown-source"))
    alert_type = str(alert.get("type", "unknown-type"))
    entity = str(alert.get("entity", "-"))
    rule = alert.get("rule") if isinstance(alert.get("rule"), dict) else {}
    rule_id = str(rule.get("id", "unknown-rule"))
    return "\x1f".join([source_id, alert_type, entity, rule_id])


# ── Section: Alert Detection ──────────────────────────────────────────────────


def _compute_current_alert_candidates(
    snapshot: Dict[str, Dict[str, Any]],
    sample_epochs: Dict[str, Optional[float]],
    now_epoch: float,
) -> List[Dict[str, Any]]:
    candidates: List[Dict[str, Any]] = []

    for source_id, source_entry in snapshot.items():
        source_epoch = sample_epochs.get(source_id)
        if source_epoch is None or (now_epoch - source_epoch) > ALERT_STALE_AFTER_SECONDS:
            candidates.append(
                {
                    "source_id": source_id,
                    "status": "open",
                    "severity": "high",
                    "type": "stale-source",
                    "message": f"No fresh sample within {ALERT_STALE_AFTER_SECONDS:.0f}s.",
                    "rule": {
                        "id": "stale_source_age_window_v1",
                        "ruleset": ALERT_RULESET_VERSION,
                        "parameters": {
                            "stale_after_seconds": ALERT_STALE_AFTER_SECONDS,
                        },
                        "evidence": {
                            "sample_epoch": source_epoch,
                            "now_epoch": now_epoch,
                        },
                    },
                }
            )

        for entity in source_entry.get("entities") or []:
            ue_metrics = entity.get("ue") or {}
            if not isinstance(ue_metrics, dict):
                continue

            dl = float(ue_metrics.get("dl_brate", 0) or 0)
            ul = float(ue_metrics.get("ul_brate", 0) or 0)
            # -1.0 is the disabled sentinel; skip the check when a threshold is disabled.
            dl_breach = ALERT_MIN_DL_BRATE >= 0 and dl <= ALERT_MIN_DL_BRATE
            ul_breach = ALERT_MIN_UL_BRATE >= 0 and ul <= ALERT_MIN_UL_BRATE
            if dl_breach or ul_breach:
                candidates.append(
                    {
                        "source_id": source_id,
                        "status": "open",
                        "severity": "medium",
                        "type": "low-throughput",
                        "entity": entity.get("ue_identity"),
                        "message": "DL/UL throughput below configured thresholds.",
                        "rule": {
                            "id": "low_throughput_threshold_v1",
                            "ruleset": ALERT_RULESET_VERSION,
                            "parameters": {
                                "min_dl_brate": ALERT_MIN_DL_BRATE,
                                "min_ul_brate": ALERT_MIN_UL_BRATE,
                            },
                            "evidence": {
                                "observed_dl_brate": dl,
                                "observed_ul_brate": ul,
                            },
                        },
                    }
                )

    return candidates


# ── Section: Alert Lifecycle ──────────────────────────────────────────────────


def _sync_alert_lifecycle(candidates: List[Dict[str, Any]], observed_at: str) -> Optional[str]:
    if not AUDIT_DB_ENABLED:
        return None

    try:
        with _AUDIT_DB_LOCK:
            with sqlite3.connect(str(AUDIT_DB_PATH), timeout=AUDIT_DB_TIMEOUT_SECONDS) as conn:
                existing_rows = conn.execute(
                    """
                    SELECT alert_key, status
                    FROM api_alert_state
                    """
                ).fetchall()
                existing_status = {row[0]: row[1] for row in existing_rows}

                seen_keys = set()
                for alert in candidates:
                    alert_key = _alert_key(alert)
                    seen_keys.add(alert_key)

                    rule = alert.get("rule") if isinstance(alert.get("rule"), dict) else {}
                    rule_id = str(rule.get("id", "unknown-rule"))
                    entity = str(alert.get("entity")) if alert.get("entity") is not None else None
                    context_json = json.dumps(alert, sort_keys=True, ensure_ascii=False)

                    if alert_key in existing_status:
                        conn.execute(
                            """
                            UPDATE api_alert_state
                            SET
                                source_id = ?,
                                entity = ?,
                                alert_type = ?,
                                severity = ?,
                                rule_id = ?,
                                message = ?,
                                status = 'open',
                                last_seen_at = ?,
                                cleared_at = NULL,
                                context_json = ?
                            WHERE alert_key = ?
                            """,
                            (
                                str(alert.get("source_id", "unknown-source")),
                                entity,
                                str(alert.get("type", "unknown-type")),
                                str(alert.get("severity", "unknown")),
                                rule_id,
                                str(alert.get("message", "")),
                                observed_at,
                                context_json,
                                alert_key,
                            ),
                        )
                    else:
                        conn.execute(
                            """
                            INSERT INTO api_alert_state (
                                alert_key,
                                source_id,
                                entity,
                                alert_type,
                                severity,
                                rule_id,
                                message,
                                status,
                                first_seen_at,
                                last_seen_at,
                                cleared_at,
                                ack_by,
                                context_json
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, NULL, NULL, ?)
                            """,
                            (
                                alert_key,
                                str(alert.get("source_id", "unknown-source")),
                                entity,
                                str(alert.get("type", "unknown-type")),
                                str(alert.get("severity", "unknown")),
                                rule_id,
                                str(alert.get("message", "")),
                                observed_at,
                                observed_at,
                                context_json,
                            ),
                        )

                for alert_key, status in existing_status.items():
                    if status != "open":
                        continue
                    if alert_key in seen_keys:
                        continue

                    conn.execute(
                        """
                        UPDATE api_alert_state
                        SET status = 'cleared', last_seen_at = ?, cleared_at = ?
                        WHERE alert_key = ?
                        """,
                        (observed_at, observed_at, alert_key),
                    )
    except sqlite3.Error as exc:
        return f"alert lifecycle persistence failed: {exc}"

    return None


def _load_alert_lifecycle_view(status_filter: str) -> List[Dict[str, Any]]:
    if not AUDIT_DB_ENABLED:
        return []

    query = """
        SELECT
            alert_key,
            status,
            first_seen_at,
            last_seen_at,
            cleared_at,
            ack_by,
            context_json
        FROM api_alert_state
    """
    params: tuple[Any, ...] = ()
    if status_filter == "open":
        query += " WHERE status = ?"
        params = ("open",)

    query += " ORDER BY last_seen_at DESC, alert_key ASC"

    with _AUDIT_DB_LOCK:
        with sqlite3.connect(str(AUDIT_DB_PATH), timeout=AUDIT_DB_TIMEOUT_SECONDS) as conn:
            rows = conn.execute(query, params).fetchall()

    items: List[Dict[str, Any]] = []
    for alert_key_value, status, first_seen_at, last_seen_at, cleared_at, ack_by, context_json in rows:
        try:
            context_payload = json.loads(context_json) if context_json else {}
        except json.JSONDecodeError:
            context_payload = {}

        if not isinstance(context_payload, dict):
            context_payload = {}

        context_payload["alert_key"] = alert_key_value
        context_payload["status"] = status
        context_payload["first_seen_at"] = first_seen_at
        context_payload["last_seen_at"] = last_seen_at
        context_payload["cleared_at"] = cleared_at
        context_payload["ack_by"] = ack_by
        items.append(context_payload)

    return items


def _window_metrics(
    reader: MetricsLogReader,
    lower_epoch: Optional[float],
    upper_epoch: Optional[float],
    cell_id: Optional[str],
    source_id_filter: Optional[str],
) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []

    for entry in reader.window_cells_events(lower_epoch=lower_epoch, upper_epoch=upper_epoch):
        source_id = str(entry.get("source_id", "single"))
        if source_id_filter is not None and source_id != source_id_filter:
            continue

        entities = entry.get("entities") or []
        if cell_id is not None:
            entities = [entity for entity in entities if _entity_matches_cell(entity, cell_id)]
            if not entities:
                continue

        items.append(
            {
                "source_id": source_id,
                "timestamp": entry.get("timestamp"),
                "collector_timestamp": entry.get("collector_timestamp"),
                "metric_family": entry.get("metric_family"),
                "event_type": entry.get("event_type"),
                "entities": entities,
            }
        )

    return items


# ── Section: Route Handlers ───────────────────────────────────────────────────


@app.get("/metrics")
def get_metrics(
    cell_id: Optional[str] = Query(default=None, description="Filter by PCI or cell index."),
    source_id: Optional[str] = Query(default=None, description="Filter by source identifier (e.g. gnb1)."),
    from_ts: Optional[str] = Query(default=None, alias="from", description="ISO-8601 start timestamp."),
    to_ts: Optional[str] = Query(default=None, alias="to", description="ISO-8601 end timestamp."),
) -> Dict[str, Any]:
    lower_epoch = _parse_query_epoch(from_ts, "from")
    upper_epoch = _parse_query_epoch(to_ts, "to")

    if lower_epoch is not None and upper_epoch is not None and lower_epoch > upper_epoch:
        raise HTTPException(status_code=400, detail="'from' must be <= 'to'.")

    if lower_epoch is not None or upper_epoch is not None:
        reader = _reader()
        items = _window_metrics(reader, lower_epoch, upper_epoch, cell_id, source_id)
        return {
            "schema_version": API_SCHEMA_VERSION,
            "mode": "time-window",
            "transport": _transport_metadata(),
            "count": len(items),
            "items": items,
        }

    snapshot, _ = _cached_snapshot()
    items: List[Dict[str, Any]] = []

    for sid, source_entry in snapshot.items():
        if source_id is not None and sid != source_id:
            continue

        entities = source_entry.get("entities") or []
        if cell_id is not None:
            entities = [entity for entity in entities if _entity_matches_cell(entity, cell_id)]
            if not entities:
                continue

        items.append(
            {
                "source_id": sid,
                "timestamp": source_entry.get("timestamp"),
                "collector_timestamp": source_entry.get("collector_timestamp"),
                "sequence": source_entry.get("sequence"),
                "entities": entities,
            }
        )

    return {
        "schema_version": API_SCHEMA_VERSION,
        "mode": "latest-snapshot",
        "transport": _transport_metadata(),
        "count": len(items),
        "items": items,
    }


@app.get("/alerts")
def get_alerts(status: str = Query(default="open", description="Alert status filter (open|all).")) -> Dict[str, Any]:
    status_normalized = status.strip().lower()
    if status_normalized not in {"open", "all"}:
        raise HTTPException(status_code=400, detail="status must be 'open' or 'all'.")

    snapshot, sample_epochs = _cached_snapshot()
    now_epoch = time.time()
    candidates = _compute_current_alert_candidates(snapshot, sample_epochs, now_epoch)
    lifecycle_warning = _sync_alert_lifecycle(candidates, datetime.now(timezone.utc).isoformat())

    if AUDIT_DB_ENABLED:
        try:
            alerts = _load_alert_lifecycle_view(status_normalized)
        except sqlite3.Error as exc:
            alerts = candidates
            if status_normalized == "open":
                alerts = [alert for alert in alerts if alert.get("status") == "open"]
            if lifecycle_warning:
                lifecycle_warning = f"{lifecycle_warning}; lifecycle read failed: {exc}"
            else:
                lifecycle_warning = f"lifecycle read failed: {exc}"
    else:
        alerts = candidates
        if status_normalized == "open":
            alerts = [alert for alert in alerts if alert.get("status") == "open"]

    response = {
        "schema_version": API_SCHEMA_VERSION,
        "mode": "rule-thresholds",
        "ruleset": ALERT_RULESET_VERSION,
        "transport": _transport_metadata(),
        "count": len(alerts),
        "items": alerts,
    }

    if lifecycle_warning:
        response["lifecycle_warning"] = lifecycle_warning

    return response


@app.get("/health")
def get_health() -> Dict[str, Any]:
    now = datetime.now(timezone.utc)
    now_epoch = now.timestamp()
    snapshot_summary: Dict[str, Any] = {"sources": 0, "entities": 0}
    per_source: Dict[str, Any] = {}
    reader_warning: Optional[str] = None

    try:
        snapshot, sample_epochs = _cached_snapshot()
        snapshot_summary = _snapshot_summary(snapshot)

        for sid, source_entry in snapshot.items():
            entity_count = len(source_entry.get("entities") or [])
            sample_epoch = sample_epochs.get(sid)
            age = (now_epoch - sample_epoch) if sample_epoch is not None else None
            per_source[sid] = {
                "entities": entity_count,
                "last_sample_age_seconds": round(age, 3) if age is not None else None,
                "fresh": (age is not None and age <= ALERT_STALE_AFTER_SECONDS),
            }
    except Exception as exc:  # noqa: BLE001
        reader_warning = f"snapshot read failed: {exc}"

    response = {
        "schema_version": API_SCHEMA_VERSION,
        "service": "metrics-rest-api",
        "status": "ok" if reader_warning is None else "degraded",
        "time_reference": now.isoformat(),
        "uptime_seconds": max(0.0, time.monotonic() - _SERVICE_START_MONOTONIC),
        "snapshot": snapshot_summary,
        "sources": per_source,
        "storage": _storage_metadata(),
        "transport": _transport_metadata(),
        "freshness_policy": _freshness_metadata(),
        "capabilities": _capability_metadata(),
    }

    if reader_warning:
        response["warning"] = reader_warning

    return response


@app.get("/capabilities")
def get_capabilities() -> Dict[str, Any]:
    return {
        "schema_version": API_SCHEMA_VERSION,
        "service": "metrics-rest-api",
        "capabilities": _capability_metadata(),
        "transport": _transport_metadata(),
        "storage": _storage_metadata(),
        "freshness_policy": _freshness_metadata(),
        "alerts": {
            "mode": "rule-thresholds",
            "ruleset": ALERT_RULESET_VERSION,
            "stale_after_seconds": ALERT_STALE_AFTER_SECONDS,
            "min_dl_brate": ALERT_MIN_DL_BRATE,  # -1.0 = disabled
            "min_ul_brate": ALERT_MIN_UL_BRATE,  # -1.0 = disabled
        },
    }


@app.post("/query")
def post_query(payload: QueryRequest) -> Dict[str, Any]:
    request_id = _new_request_id()
    snapshot, _ = _cached_snapshot()
    summary = _snapshot_summary(snapshot)
    question = payload.question.strip()
    question_lower = question.lower()

    if "lat" in question_lower:
        answer = (
            "Latency-specific KPI is not currently exported as a dedicated field in all samples; "
            "latest per-source entities are available for contextual inspection."
        )
    else:
        answer = (
            f"Latest snapshot covers {summary['sources']} source(s) and "
            f"{summary['entities']} UE entity sample(s)."
        )

    response = {
        "schema_version": API_SCHEMA_VERSION,
        "request_id": request_id,
        "status": "answered_stub",
        "mode": QUERY_BACKEND_MODE,
        "reason_code": "llm_not_integrated",
        "question": question,
        "answer": answer,
        "time_reference": datetime.now(timezone.utc).isoformat(),
        "context": summary,
        "capabilities": _capability_metadata(),
        "transport": _transport_metadata(),
    }

    audit_warning = _append_audit_event("query", response)
    if audit_warning:
        response["audit_warning"] = audit_warning

    return response


@app.post("/actions")
def post_actions(payload: ActionRequest) -> Dict[str, Any]:
    request_id = _new_request_id()
    intent_payload = payload.intent.model_dump()
    audit_event = {
        "schema_version": API_SCHEMA_VERSION,
        "event_type": "state",
        "request_id": request_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "request": payload.request,
        "intent": intent_payload,
        "intent_checks": {
            "safety_checks_count": len(intent_payload.get("safety_checks") or []),
            "dry_run": bool(intent_payload.get("dry_run")),
            "within_bounds": True,
        },
    }

    if not payload.approve:
        response = {
            "schema_version": API_SCHEMA_VERSION,
            "request_id": request_id,
            "status": "pending_approval",
            "executed": False,
            "mode": ACTION_EXECUTION_MODE,
            "reason_code": "approval_required",
            "message": "Action accepted as proposal and awaits explicit approval.",
            "intent": intent_payload,
            "capabilities": _capability_metadata(),
            "transport": _transport_metadata(),
            "audit": audit_event,
        }
        audit_warning = _append_audit_event("action", response)
        if audit_warning:
            response["audit_warning"] = audit_warning
        return response

    # Network control execution is intentionally conservative here.
    response = {
        "schema_version": API_SCHEMA_VERSION,
        "request_id": request_id,
        "status": "approved_not_executed",
        "executed": False,
        "mode": ACTION_EXECUTION_MODE,
        "reason_code": "mutation_pipeline_disabled",
        "message": "Approved request recorded; runtime parameter mutation pipeline is not enabled.",
        "intent": intent_payload,
        "capabilities": _capability_metadata(),
        "transport": _transport_metadata(),
        "audit": audit_event,
    }

    audit_warning = _append_audit_event("action", response)
    if audit_warning:
        response["audit_warning"] = audit_warning

    return response


# ── Section: Entry Point ──────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=API_HOST, port=API_PORT, reload=False)