#!/usr/bin/env python3
import json
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import websocket

SCRIPT_DIR = Path(__file__).resolve().parent
SOURCES_CONFIG = Path(
    os.environ.get("METRICS_SOURCES_CONFIG", SCRIPT_DIR / "../config/metrics_sources.json")
)
OUT = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))
RECONNECT_SECONDS = float(os.environ.get("METRICS_RECONNECT_SECONDS", "3"))


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
        first_cell = cells[0]
        context["cell_index"] = 0

        cell_metrics = first_cell.get("cell_metrics") or {}
        if "pci" in cell_metrics:
            context["pci"] = cell_metrics["pci"]

        ue_list = first_cell.get("ue_list") or []
        if ue_list:
            first_ue = ue_list[0]
            if "ue" in first_ue:
                context["ue"] = first_ue["ue"]
            if "rnti" in first_ue:
                context["rnti"] = first_ue["rnti"]

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
        cells = payload.get("cells") or []
        if cells:
            ue_list = cells[0].get("ue_list") or []
            if ue_list:
                ue = ue_list[0]
                snr = ue.get("pucch_snr_db", ue.get("pusch_snr_db", 0))
                return (
                    f"[{source_id}] cells "
                    f"pci={event.get('pci', '-')}"
                    f" ue={event.get('ue', '-')}"
                    f" dl={ue.get('dl_brate', 0):.1f}"
                    f" ul={ue.get('ul_brate', 0):.1f}"
                    f" snr={snr:.2f}"
                )

    return f"[{source_id}] {family} timestamp={event.get('timestamp') or '-'}"


class EventWriter:
    def __init__(self, output_path):
        self.output_path = output_path
        self.lock = threading.Lock()

    def write(self, event):
        line = json.dumps(event, ensure_ascii=False)
        with self.lock:
            with self.output_path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
                f.flush()


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
    writer = EventWriter(OUT)

    print(f"Metrics collector ready. Sources: {SOURCES_CONFIG.resolve()}", flush=True)
    print(f"Writing enriched metrics to: {OUT.resolve()}", flush=True)

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
