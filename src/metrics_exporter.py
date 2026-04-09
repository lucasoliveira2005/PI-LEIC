"""Legacy single-source metrics exporter kept for debugging.

The main multi-gNB workflow now uses metrics_collector.py with
config/metrics_sources.json.
"""

import json
import os
import time
from pathlib import Path

import websocket

WS_URL = os.environ.get("METRICS_WS_URL", "ws://127.0.0.1:55555")
SCRIPT_DIR = Path(__file__).resolve().parent
OUT = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))
RECONNECT_SECONDS = float(os.environ.get("METRICS_RECONNECT_SECONDS", "3"))


def on_open(ws):
    print(f"Connected to {WS_URL}", flush=True)
    ws.send(json.dumps({"cmd": "metrics_subscribe"}))
    print("Subscribed to metrics", flush=True)


def on_message(_ws, message):
    try:
        obj = json.loads(message)
        if "cmd" in obj:
            print("Control message:", obj, flush=True)
            return

        line = json.dumps(obj, ensure_ascii=False)
        print(line, flush=True)

        with OUT.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
            f.flush()
    except json.JSONDecodeError:
        print("Non-JSON message:", message, flush=True)


def on_error(_ws, error):
    print("WebSocket error:", error, flush=True)


def on_close(_ws, close_status_code, close_msg):
    print("Closed:", close_status_code, close_msg, flush=True)


def build_app():
    return websocket.WebSocketApp(
        WS_URL,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    print(f"Metrics exporter ready. Target: {WS_URL}", flush=True)
    print(f"Writing metrics to: {OUT.resolve()}", flush=True)

    while True:
        try:
            ws = build_app()
            ws.run_forever()
        except KeyboardInterrupt:
            print("\nStopping metrics exporter.", flush=True)
            break
        except Exception as exc:
            print(f"Unexpected error: {exc}", flush=True)

        print(f"Reconnecting in {RECONNECT_SECONDS} seconds...", flush=True)
        time.sleep(RECONNECT_SECONDS)


if __name__ == "__main__":
    main()
