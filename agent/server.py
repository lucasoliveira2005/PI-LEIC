import json
import os
import sys
from pathlib import Path
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
SOFTWARE_TYPE = os.environ.get("RAN_BACKEND", "srsran")

app = Flask(__name__, static_folder=str(AGENT_DIR))


def _metrics_api_get(path: str):
    try:
        r = http_requests.get(f"{METRICS_API_BASE}{path}", timeout=3)
        r.raise_for_status()
        return r.json()
    except Exception:
        return None


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
    if live is not None:
        return live
    try:
        return load_local_json(paths[name])
    except Exception:
        return {}


@app.route("/")
def index():
    return send_from_directory(str(AGENT_DIR), "index.html")


@app.route("/chat", methods=["POST"])
def chat():
    data = request.get_json(force=True)
    question = (data.get("question") or "").strip()
    software = data.get("software", SOFTWARE_TYPE)
    if not question:
        return jsonify({"error": "empty question"}), 400
    try:
        summary = build_network_summary(software)
        answer = ask_llm(summary, question)
        return jsonify({"answer": answer})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


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
