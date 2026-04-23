import json
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException
from pydantic import ValidationError

from api_models import ActionRequest, QueryRequest
import metrics_rest_api


class _DirectResponse:
    def __init__(self, status_code, payload=None, text=None, headers=None):
        self.status_code = status_code
        self._payload = payload
        self.text = text or ""
        self.headers = headers or {}

    def json(self):
        return self._payload


class _DirectClient:
    """Small route harness that avoids Starlette TestClient threadpool hangs.

    The CI api_smoke job still starts the FastAPI app and calls it over HTTP;
    these unit tests focus on route behavior and persistence side effects.
    """

    def get(self, path, params=None):
        params = params or {}
        try:
            if path == "/metrics":
                payload = metrics_rest_api.get_metrics(
                    cell_id=params.get("cell_id"),
                    source_id=params.get("source_id"),
                    from_ts=params.get("from"),
                    to_ts=params.get("to"),
                    limit=int(params["limit"]) if params.get("limit") is not None else None,
                    offset=int(params.get("offset", 0)),
                )
                return _DirectResponse(200, payload=payload)
            if path == "/alerts":
                return _DirectResponse(
                    200,
                    payload=metrics_rest_api.get_alerts(status=params.get("status", "open")),
                )
            if path == "/health":
                return _DirectResponse(200, payload=metrics_rest_api.get_health())
            if path == "/capabilities":
                return _DirectResponse(200, payload=metrics_rest_api.get_capabilities())
            if path == "/metrics_prom":
                response = metrics_rest_api.get_metrics_prom()
                return _DirectResponse(
                    response.status_code,
                    text=response.body.decode("utf-8"),
                    headers={"content-type": response.media_type or ""},
                )
        except HTTPException as exc:
            return _DirectResponse(exc.status_code, payload={"detail": exc.detail})

        return _DirectResponse(404, payload={"detail": "not found"})

    def post(self, path, json=None):
        body = json or {}
        try:
            if path == "/query":
                return _DirectResponse(
                    200,
                    payload=metrics_rest_api.post_query(QueryRequest.model_validate(body)),
                )
            if path == "/actions":
                return _DirectResponse(
                    200,
                    payload=metrics_rest_api.post_actions(ActionRequest.model_validate(body)),
                )
        except ValidationError as exc:
            return _DirectResponse(422, payload={"detail": exc.errors()})

        return _DirectResponse(404, payload={"detail": "not found"})


class MetricsRestApiTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)

        self.metrics_file = Path(self.temp_dir.name) / "metrics.jsonl"
        self.audit_db = Path(self.temp_dir.name) / "api-audit.sqlite"

        self._originals = {
            "LOG_FILE": metrics_rest_api.LOG_FILE,
            "LOG_INCLUDE_ROTATED": metrics_rest_api.LOG_INCLUDE_ROTATED,
            "LOG_MAX_ARCHIVES": metrics_rest_api.LOG_MAX_ARCHIVES,
            "SQLITE_ENABLED": metrics_rest_api.SQLITE_ENABLED,
            "SQLITE_PATH": metrics_rest_api.SQLITE_PATH,
            "ALERT_STALE_AFTER_SECONDS": metrics_rest_api.ALERT_STALE_AFTER_SECONDS,
            "ALERT_MIN_DL_BRATE": metrics_rest_api.ALERT_MIN_DL_BRATE,
            "ALERT_MIN_UL_BRATE": metrics_rest_api.ALERT_MIN_UL_BRATE,
            "AUDIT_DB_ENABLED": metrics_rest_api.AUDIT_DB_ENABLED,
            "AUDIT_DB_PATH": metrics_rest_api.AUDIT_DB_PATH,
            "AUDIT_DB_TIMEOUT_SECONDS": metrics_rest_api.AUDIT_DB_TIMEOUT_SECONDS,
            "_AUDIT_SCHEMA_READY": metrics_rest_api._AUDIT_SCHEMA_READY,
            "_snapshot_cache": metrics_rest_api._snapshot_cache,
            "METRICS_SNAPSHOT_TTL_SECONDS": metrics_rest_api.METRICS_SNAPSHOT_TTL_SECONDS,
        }

        metrics_rest_api.LOG_FILE = self.metrics_file
        metrics_rest_api.LOG_INCLUDE_ROTATED = False
        metrics_rest_api.LOG_MAX_ARCHIVES = 0
        metrics_rest_api.SQLITE_ENABLED = False
        metrics_rest_api.SQLITE_PATH = Path(self.temp_dir.name) / "metrics.sqlite"
        metrics_rest_api.ALERT_STALE_AFTER_SECONDS = 30.0
        metrics_rest_api.ALERT_MIN_DL_BRATE = -1.0
        metrics_rest_api.ALERT_MIN_UL_BRATE = -1.0
        metrics_rest_api.AUDIT_DB_ENABLED = True
        metrics_rest_api.AUDIT_DB_PATH = self.audit_db
        metrics_rest_api.AUDIT_DB_TIMEOUT_SECONDS = 1.0
        metrics_rest_api._AUDIT_SCHEMA_READY = False
        # Flush any cached snapshot from a previous test so each test reads fresh data.
        # Set TTL=0 so the cache is always bypassed during tests — each _write_events()
        # call must be visible immediately to the next request.
        metrics_rest_api._snapshot_cache = None
        metrics_rest_api.METRICS_SNAPSHOT_TTL_SECONDS = 0.0
        # Lifespan is not triggered by TestClient directly; prime the schema here.
        metrics_rest_api._ensure_audit_schema()

        self.client = _DirectClient()

    def tearDown(self):
        for key, value in self._originals.items():
            setattr(metrics_rest_api, key, value)

    @staticmethod
    def _cells_event(source_id, timestamp, dl_brate=1000.0, ul_brate=500.0, pci=10, ue="ue1"):
        return {
            "source_id": source_id,
            "metric_family": "cells",
            "event_type": "metric",
            "schema_version": "1.0",
            "timestamp": timestamp,
            "collector_timestamp": timestamp,
            "raw_payload": {
                "timestamp": timestamp,
                "cells": [
                    {
                        "cell_metrics": {"pci": pci},
                        "ue_list": [
                            {
                                "ue": ue,
                                "dl_brate": dl_brate,
                                "ul_brate": ul_brate,
                            }
                        ],
                    }
                ],
            },
        }

    def _write_events(self, events):
        with self.metrics_file.open("w", encoding="utf-8") as handle:
            for event in events:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")

    @staticmethod
    def _action_payload(approve):
        return {
            "request": "reduce cell power by 2 dB",
            "approve": approve,
            "intent": {
                "target": "cell:gnb1:0",
                "parameter": "tx_power_dbm",
                "unit": "dBm",
                "proposed_value": 18.0,
                "current_value": 20.0,
                "bounds": {
                    "min_value": 10.0,
                    "max_value": 23.0,
                },
                "reason": "Mitigate observed interference while staying in safe bounds.",
                "safety_checks": [
                    "verify_cell_online",
                    "verify_neighbor_headroom",
                ],
                "dry_run": True,
            },
        }

    def test_get_metrics_returns_latest_snapshot_mode(self):
        self._write_events(
            [
                self._cells_event("gnb1", "2026-04-14T10:00:00+00:00", dl_brate=100),
                self._cells_event("gnb1", "2026-04-14T10:01:00+00:00", dl_brate=200),
                self._cells_event("gnb2", "2026-04-14T10:02:00+00:00", dl_brate=300),
            ]
        )

        response = self.client.get("/metrics")
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        self.assertEqual(payload["mode"], "latest-snapshot")
        self.assertEqual(payload["transport"]["current"], "websocket")
        self.assertEqual(payload["transport"]["target"], "e2ap-kpm")
        self.assertEqual(payload["transport"]["target_platform"], "o-ran-sc-ric")
        self.assertEqual(payload["count"], 2)

    def test_get_metrics_with_time_window_returns_event_window(self):
        self._write_events(
            [
                self._cells_event("gnb1", "2026-04-14T10:00:00+00:00", dl_brate=100, pci=10),
                self._cells_event("gnb1", "2026-04-14T10:02:00+00:00", dl_brate=200, pci=11),
                self._cells_event("gnb2", "2026-04-14T10:03:00+00:00", dl_brate=300, pci=11),
            ]
        )

        response = self.client.get(
            "/metrics",
            params={
                "from": "2026-04-14T10:01:00+00:00",
                "to": "2026-04-14T10:03:00+00:00",
                "cell_id": "11",
            },
        )
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        self.assertEqual(payload["mode"], "time-window")
        self.assertEqual(payload["transport"]["current"], "websocket")
        self.assertEqual(payload["transport"]["target"], "e2ap-kpm")
        self.assertEqual(payload["count"], 2)

    def test_get_alerts_reports_stale_sources(self):
        self._write_events(
            [
                self._cells_event("gnb1", "2000-01-01T00:00:00+00:00"),
            ]
        )

        response = self.client.get("/alerts", params={"status": "open"})
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        self.assertEqual(payload["mode"], "rule-thresholds")
        self.assertEqual(payload["ruleset"], "rules-v1")
        self.assertGreaterEqual(payload["count"], 1)
        stale_items = [item for item in payload["items"] if item.get("type") == "stale-source"]
        self.assertTrue(stale_items)
        stale_rule = stale_items[0].get("rule") or {}
        self.assertEqual(stale_rule.get("id"), "stale_source_age_window_v1")

    def test_get_alerts_low_throughput_includes_rule_details(self):
        now = datetime.now(timezone.utc).isoformat()
        metrics_rest_api.ALERT_MIN_DL_BRATE = 500.0
        metrics_rest_api.ALERT_MIN_UL_BRATE = 500.0
        self._write_events(
            [
                self._cells_event("gnb1", now, dl_brate=100.0, ul_brate=50.0),
            ]
        )

        response = self.client.get("/alerts", params={"status": "open"})
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        low_items = [item for item in payload["items"] if item.get("type") == "low-throughput"]
        self.assertTrue(low_items)
        low_rule = low_items[0].get("rule") or {}
        self.assertEqual(low_rule.get("id"), "low_throughput_threshold_v1")
        self.assertEqual(low_rule.get("parameters", {}).get("min_dl_brate"), 500.0)
        self.assertEqual(low_rule.get("parameters", {}).get("min_ul_brate"), 500.0)

    def test_get_alerts_low_throughput_disabled_when_sentinel(self):
        """With -1.0 sentinel, no low-throughput alert fires regardless of brate."""
        now = datetime.now(timezone.utc).isoformat()
        metrics_rest_api.ALERT_MIN_DL_BRATE = -1.0
        metrics_rest_api.ALERT_MIN_UL_BRATE = -1.0
        self._write_events(
            [
                self._cells_event("gnb1", now, dl_brate=0.0, ul_brate=0.0),
            ]
        )

        response = self.client.get("/alerts", params={"status": "open"})
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        low_items = [item for item in payload["items"] if item.get("type") == "low-throughput"]
        self.assertEqual(low_items, [], "Expected no low-throughput alerts when thresholds are -1.0")

    def test_get_alerts_lifecycle_marks_cleared_after_recovery(self):
        stale_ts = "2000-01-01T00:00:00+00:00"
        self._write_events([self._cells_event("gnb1", stale_ts, dl_brate=1000.0, ul_brate=1000.0)])

        first_response = self.client.get("/alerts", params={"status": "open"})
        self.assertEqual(first_response.status_code, 200)
        self.assertTrue(first_response.json()["items"])

        fresh_ts = datetime.now(timezone.utc).isoformat()
        self._write_events([self._cells_event("gnb1", fresh_ts, dl_brate=1000.0, ul_brate=1000.0)])

        second_response = self.client.get("/alerts", params={"status": "all"})
        self.assertEqual(second_response.status_code, 200)

        stale_records = [
            item for item in second_response.json()["items"] if item.get("type") == "stale-source"
        ]
        self.assertTrue(stale_records)
        self.assertEqual(stale_records[0].get("status"), "cleared")
        self.assertIsNotNone(stale_records[0].get("cleared_at"))

    def test_post_query_persists_audit_event(self):
        self._write_events([self._cells_event("gnb1", "2026-04-14T10:00:00+00:00")])

        response = self.client.post("/query", json={"question": "How many UEs are visible?"})
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["status"], "answered_stub")
        self.assertEqual(payload["reason_code"], "llm_not_integrated")
        self.assertIn("request_id", payload)
        self.assertEqual(payload["mode"], "heuristic-stub")

        with sqlite3.connect(self.audit_db) as conn:
            count = conn.execute(
                "SELECT COUNT(*) FROM api_audit_log WHERE event_type = 'query'"
            ).fetchone()[0]

        self.assertEqual(count, 1)

    def test_post_actions_returns_expected_states_and_persists_audit(self):
        pending = self.client.post(
            "/actions",
            json=self._action_payload(False),
        )
        self.assertEqual(pending.status_code, 200)
        self.assertEqual(pending.json()["status"], "pending_approval")
        self.assertEqual(pending.json()["mode"], "audit-only-stub")
        self.assertEqual(pending.json()["reason_code"], "approval_required")
        self.assertIn("intent", pending.json())

        approved = self.client.post(
            "/actions",
            json=self._action_payload(True),
        )
        self.assertEqual(approved.status_code, 200)
        self.assertEqual(approved.json()["status"], "approved_not_executed")
        self.assertEqual(approved.json()["mode"], "audit-only-stub")
        self.assertEqual(approved.json()["reason_code"], "mutation_pipeline_disabled")
        self.assertIn("request_id", approved.json())
        self.assertIn("intent", approved.json())

        with sqlite3.connect(self.audit_db) as conn:
            count = conn.execute(
                "SELECT COUNT(*) FROM api_audit_log WHERE event_type = 'action'"
            ).fetchone()[0]

        self.assertEqual(count, 2)

    def test_health_and_capabilities_endpoints_expose_operational_state(self):
        self._write_events([self._cells_event("gnb1", datetime.now(timezone.utc).isoformat())])

        health = self.client.get("/health")
        self.assertEqual(health.status_code, 200)
        health_payload = health.json()
        self.assertEqual(health_payload["service"], "metrics-rest-api")
        self.assertIn(health_payload["status"], {"ok", "degraded"})
        self.assertIn("storage", health_payload)
        self.assertIn("freshness_policy", health_payload)

        capabilities = self.client.get("/capabilities")
        self.assertEqual(capabilities.status_code, 200)
        capabilities_payload = capabilities.json()
        self.assertEqual(
            capabilities_payload["capabilities"]["action_execution_mode"],
            "audit-only-stub",
        )
        self.assertFalse(capabilities_payload["capabilities"]["action_mutation_pipeline_enabled"])

    def test_health_exposes_per_source_breakdown(self):
        now = datetime.now(timezone.utc).isoformat()
        self._write_events(
            [
                self._cells_event("gnb1", now, dl_brate=1000.0),
                self._cells_event("gnb2", now, dl_brate=2000.0),
            ]
        )

        health = self.client.get("/health")
        self.assertEqual(health.status_code, 200)

        payload = health.json()
        sources = payload.get("sources", {})
        self.assertIn("gnb1", sources)
        self.assertIn("gnb2", sources)
        for sid in ("gnb1", "gnb2"):
            entry = sources[sid]
            self.assertIn("entities", entry)
            self.assertGreaterEqual(entry["entities"], 1)
            self.assertIn("last_sample_age_seconds", entry)
            self.assertIn("fresh", entry)
            self.assertIsInstance(entry["fresh"], bool)

    def test_get_metrics_source_id_filter(self):
        now = datetime.now(timezone.utc).isoformat()
        self._write_events(
            [
                self._cells_event("gnb1", now, dl_brate=100.0),
                self._cells_event("gnb2", now, dl_brate=200.0),
            ]
        )

        response = self.client.get("/metrics", params={"source_id": "gnb1"})
        self.assertEqual(response.status_code, 200)

        payload = response.json()
        self.assertEqual(payload["count"], 1)
        self.assertEqual(payload["items"][0]["source_id"], "gnb1")

    def test_metrics_prom_exposes_gauges_per_source_and_ue(self):
        now = datetime.now(timezone.utc).isoformat()
        self._write_events(
            [
                self._cells_event("gnb1", now, dl_brate=1000.0, ul_brate=500.0, pci=1, ue="ue1"),
                self._cells_event("gnb2", now, dl_brate=2000.0, ul_brate=1000.0, pci=2, ue="ue2"),
            ]
        )

        response = self.client.get("/metrics_prom")
        self.assertEqual(response.status_code, 200)
        content_type = response.headers.get("content-type", "")
        self.assertTrue(content_type.startswith("text/plain"))
        self.assertIn("version=0.0.4", content_type)

        body = response.text
        self.assertIn("# HELP gnb_source_fresh", body)
        self.assertIn("# TYPE gnb_source_fresh gauge", body)
        self.assertIn('gnb_source_fresh{source_id="gnb1"} 1.0', body)
        self.assertIn('gnb_source_fresh{source_id="gnb2"} 1.0', body)

        self.assertIn("# HELP gnb_ue_dl_brate_bps", body)
        self.assertIn('source_id="gnb1"', body)
        self.assertIn('ue_identity="ue:ue1"', body)
        self.assertIn('pci="1"', body)
        self.assertIn("gnb_ue_throughput_mbps", body)

    def test_metrics_prom_reports_stale_alert_when_sample_is_old(self):
        stale_ts = "2020-01-01T00:00:00+00:00"
        self._write_events([self._cells_event("gnb1", stale_ts)])

        response = self.client.get("/metrics_prom")
        self.assertEqual(response.status_code, 200)

        body = response.text
        self.assertIn('gnb_source_fresh{source_id="gnb1"} 0.0', body)
        self.assertIn('gnb_alerts_open{type="stale-source"} 1.0', body)

    def test_metrics_prom_does_not_mutate_alert_lifecycle(self):
        # Prometheus scrapes should be read-only: they must not create or
        # transition rows in api_alert_state (which would corrupt first_seen_at
        # and cleared_at under a real scrape cadence).
        stale_ts = "2020-01-01T00:00:00+00:00"
        self._write_events([self._cells_event("gnb1", stale_ts)])

        with sqlite3.connect(str(metrics_rest_api.AUDIT_DB_PATH)) as conn:
            before = conn.execute("SELECT COUNT(*) FROM api_alert_state").fetchone()[0]

        for _ in range(3):
            response = self.client.get("/metrics_prom")
            self.assertEqual(response.status_code, 200)

        with sqlite3.connect(str(metrics_rest_api.AUDIT_DB_PATH)) as conn:
            after = conn.execute("SELECT COUNT(*) FROM api_alert_state").fetchone()[0]

        self.assertEqual(before, after)

    def test_get_metrics_window_pagination(self):
        self._write_events(
            [
                self._cells_event("gnb1", "2026-04-14T10:00:00+00:00", dl_brate=100),
                self._cells_event("gnb1", "2026-04-14T10:01:00+00:00", dl_brate=200),
                self._cells_event("gnb1", "2026-04-14T10:02:00+00:00", dl_brate=300),
                self._cells_event("gnb1", "2026-04-14T10:03:00+00:00", dl_brate=400),
            ]
        )

        response = self.client.get(
            "/metrics",
            params={
                "from": "2026-04-14T09:00:00+00:00",
                "to": "2026-04-14T11:00:00+00:00",
                "limit": "2",
                "offset": "0",
            },
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["mode"], "time-window")
        self.assertEqual(payload["total"], 4)
        self.assertEqual(payload["count"], 2)
        self.assertEqual(payload["offset"], 0)
        self.assertTrue(payload.get("has_more"))

        page2 = self.client.get(
            "/metrics",
            params={
                "from": "2026-04-14T09:00:00+00:00",
                "to": "2026-04-14T11:00:00+00:00",
                "limit": "2",
                "offset": "2",
            },
        )
        payload2 = page2.json()
        self.assertEqual(payload2["total"], 4)
        self.assertEqual(payload2["count"], 2)
        self.assertEqual(payload2["offset"], 2)
        self.assertNotIn("has_more", payload2)

    def test_post_actions_approve_true_without_intent_returns_422(self):
        response = self.client.post(
            "/actions",
            json={"request": "do something", "approve": True},
        )
        self.assertEqual(response.status_code, 422)

    def test_post_actions_approve_false_without_intent_returns_pending(self):
        response = self.client.post(
            "/actions",
            json={"request": "do something", "approve": False},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "pending_approval")


if __name__ == "__main__":
    unittest.main()
