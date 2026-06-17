import os
import sys
import json
from pathlib import Path
from datetime import datetime, timezone
from flask import Flask, request, jsonify, send_from_directory
import requests as http_requests

sys.path.insert(0, str(Path(__file__).parent))
from agent import (
    build_network_summary,
    ask_llm,
    load_local_json,
    HEALTH_JSON_PATH,
    METRICS_JSON_PATH,
    ALERTS_JSON_PATH,
)

AGENT_DIR = Path(__file__).parent
REPO_ROOT = AGENT_DIR.parent
METRICS_API_BASE = os.environ.get("METRICS_API_BASE", "http://localhost:8000")
ORAN_AGENT_OBSERVATION_PATHS = [
    Path(os.environ.get("METRICS_AGENT_OUT", "")),
    REPO_ROOT / "metrics/oran/agent_network_observations.jsonl",
    REPO_ROOT / "metrics/agent_network_observations.jsonl",
]


def _normalize_backend(value: str) -> str:
    backend = (value or "oai").strip().lower()
    if backend in {"oai", "oran", "openairinterface"}:
        return "oai"
    if backend == "srsran":
        return "srsran"
    return "oai"


SOFTWARE_TYPE = _normalize_backend(os.environ.get("RAN_BACKEND", "oai"))

app = Flask(__name__, static_folder=str(AGENT_DIR))


def _metrics_api_get(path: str):
    try:
        r = http_requests.get(f"{METRICS_API_BASE}{path}", timeout=3)
        r.raise_for_status()
        return r.json()
    except Exception:
        return None


def _parse_epoch(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def _latest_jsonl(paths):
    for path in paths:
        if not path or not path.exists():
            continue
        try:
            with path.open("rb") as handle:
                handle.seek(0, os.SEEK_END)
                pos = handle.tell()
                chunk = b""
                while pos > 0:
                    step = min(8192, pos)
                    pos -= step
                    handle.seek(pos)
                    chunk = handle.read(step) + chunk
                    lines = [line for line in chunk.splitlines() if line.strip()]
                    if lines:
                        return json.loads(lines[-1].decode("utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
    return None


def _metrics_timestamp(payload):
    if not isinstance(payload, dict):
        return None
    return _parse_epoch(payload.get("timestamp") or payload.get("collector_timestamp"))


def _freshest_metrics_payload(*payloads):
    candidates = [payload for payload in payloads if isinstance(payload, dict) and payload]
    if not candidates:
        return {}
    return max(candidates, key=lambda payload: _metrics_timestamp(payload) or 0)


def _load_data(name: str):
    paths = {
        "health": HEALTH_JSON_PATH,
        "metrics": METRICS_JSON_PATH,
        "alerts": ALERTS_JSON_PATH,
    }
    api_paths = {
        "health": "/health",
        "metrics": "/metrics",
        "alerts": "/alerts",
    }
    live = _metrics_api_get(api_paths[name])
    if name == "metrics":
        local_observation = _latest_jsonl(ORAN_AGENT_OBSERVATION_PATHS)
        return _freshest_metrics_payload(live, local_observation)
    if live is not None:
        return live
    try:
        return load_local_json(paths[name])
    except Exception:
        if name == "health":
            metrics = _latest_jsonl(ORAN_AGENT_OBSERVATION_PATHS) or {}
            ue_count = len(metrics.get("ues") or [])
            cell_count = len(metrics.get("cells") or [])
            return {
                "status": "ok" if ue_count or cell_count else "unknown",
                "snapshot": {
                    "sources": cell_count,
                    "entities": ue_count,
                    "timestamp": metrics.get("timestamp"),
                },
            }
        return {}


@app.route("/")
def index():
    return send_from_directory(str(AGENT_DIR), "index.html")


@app.route("/chat", methods=["POST"])
def chat():
    data = request.get_json(force=True)
    question = (data.get("question") or "").strip()
    if not question:
        return jsonify({"error": "empty question"}), 400
    try:
        summary = build_network_summary(SOFTWARE_TYPE)
        answer = ask_llm(summary, question)
        return jsonify({"answer": answer, "backend": SOFTWARE_TYPE})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.route("/api/config")
def api_config():
    return jsonify(
        {
            "backend": SOFTWARE_TYPE,
            "backend_label": "OAI / ORAN" if SOFTWARE_TYPE == "oai" else "srsRAN",
            "metrics_api_base": METRICS_API_BASE,
        }
    )


@app.route("/api/health")
def api_health():
    return jsonify(_load_data("health"))


@app.route("/api/metrics")
def api_metrics():
    return jsonify(_load_data("metrics"))


@app.route("/api/alerts")
def api_alerts():
    return jsonify(_load_data("alerts"))


if __name__ == "__main__":
    port = int(os.environ.get("AGENT_UI_PORT", 5000))
    print(f"RANPilot UI → http://localhost:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
