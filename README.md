# PI-LEIC — AI Agent for Private 5G Network Management

**Project PE38 · L.EIC · Projeto Integrador 2025/26 · FEUP + FCUP**

PI-LEIC turns a single Linux host into a complete, reproducible **5G standalone (SA)
testbed** and layers on top of it an **observability stack** and a **local-LLM operator
agent** (RANPilot). It boots an Open5GS core, two gNBs and two UEs (radio simulated in
software), collects enriched per-UE/per-cell telemetry, stores it durably, serves it
through a REST API and live dashboards, and lets an operator **ask about the network in
natural language**.

Two radio backends are supported and selected with `RAN_BACKEND`:

| Backend | Simulated radio | Metrics ingestion |
| --- | --- | --- |
| **OpenAirInterface (OAI)** — default | RFsim | Collector polls each gNB's `nrMAC_stats.log` and parses the MAC scheduler lines |
| **srsRAN**  | ZMQ | Collector subscribes to the gNB JSON metrics server over **WebSocket**  |

The agent and the REST API are **backend-neutral**: the same code and the same
`network-observation.v1` schema work over either backend.

---

## Topology

```
          ┌─────────────────────────────┐
          │  Open5GS core (AMF/SMF/UPF) │
          │          127.0.0.5          │
          │  PLMN 99970 · TAC 1 · n78   │
          └──────────────┬──────────────┘
                         │ NGAP  |  PFCP  |  GTP-U
         ┌───────────────┴───────────────┐
         │                               │
 ┌───────▼───────┐               ┌───────▼───────┐
 │  gNB1 (OAI/   │               │  gNB2 (OAI/   │
 │  srsRAN)      │               │  srsRAN)      │
 └───────┬───────┘               └───────┬───────┘
         │  RFsim (OAI) / ZMQ (srsRAN) fake radio
 ┌───────▼───────┐               ┌───────▼───────┐
 │  UE1 netns    │               │  UE2 netns    │
 │  IMSI …0001   │               │  IMSI …0002   │
 └───────────────┘               └───────────────┘
                         │
       OAI: poll nrMAC_stats.log   |   srsRAN: ws://127.0.0.1:55551/2
                         ▼
              ┌──────────────────────────┐
              │   metrics_collector      │
              │  one worker per source   │
              │  enrich → dual-write     │
              └──────────┬───────────────┘
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
 metrics/gnb_metrics.jsonl     var/pi-leic-metrics.sqlite (WAL)
                         │   SQLite-first read, JSONL fallback
                         ▼
              ┌──────────────────────────┐
              │      metrics_api.py      │
              │     MetricsLogReader     │
              └─────────────────────┬────┘
                                    │
                            ┌───────▼──────────────────────┐
                            │   metrics_rest_api.py        │
                            │   FastAPI on :8000           │
                            │   /metrics /health           │
                            └───────────────┬──────────────┘
                                            │  (consumes REST only)
                                  ┌─────────▼──────────┐
                                  │  agent/ — RANPilot │
                                  │  Ollama LLM + Flask│
                                  │  web UI (Chat +    │
                                  │  Dashboard) :5000  │
                                  └────────────────────┘
```

The stack is supervised by `src/launch_stack.sh` with transient systemd units: root units
for the core/gNB/UE namespace work, user units for the Python collector, REST API and
dashboard. It is verified end-to-end by `src/validate_stage.sh`.

---

## Architecture

Three layers, each derivable from the layer below and optional for the one above:

| Layer | Role | Files |
| --- | --- | --- |
| **Data** | Ingest, enrich, persist | `collector/`, `metrics/*.jsonl`, SQLite |
| **Processing** | Read, shape, reason about data | `metrics_api.py`, `shared/liveness.py`, `shared/identity.py` |
| **Interface** | Expose data and actions | `metrics_rest_api.py`, `dashboard.py`, `agent/` |

### Ingestion transports

`build_transport_adapter()` (`collector/transport.py`) selects per source:

* **`oai_mac_stats`** — `OaiMacStatsFileAdapter` polls and parses an OAI `nrMAC_stats.log`
  file. Default for `RAN_BACKEND=oai`.
* **`websocket_json`** — `WebSocketSourceAdapter` subscribes to a srsRAN JSON metrics
  server. Used for `RAN_BACKEND=srsran`.

### Storage tiers

* **JSONL** is the source of truth. Append-only, schema-flexible, readable with
  `tail -f`, size-rotated (50 MiB), read newest-first.
* **SQLite (WAL)** is a derived index. Two tables: `metrics_events` (one row per enriched
  event) and `metrics_cell_entities` (per-UE denormalized for fast range queries). Bounded
  retention (`METRICS_SQLITE_RETENTION_MAX_ROWS`, default 200k). If SQLite is unavailable,
  every reader falls back to JSONL.

### Backend-neutral agent contract

`collector/network_observation.py` converts each raw event into the backend-neutral
**`network-observation.v1`** schema (groups: `radio_quality`, `throughput`, `reliability`,
`scheduler`, `traffic`, `metric_availability`). A hard `FORBIDDEN_AGENT_KEYS` barrier raises
`ValueError` if any infrastructure key (`ran_backend`, `transport`, `ws_url`, `log_path`,
`rfsim`, `port`, `process`, …) would leak into the agent-facing observation. The LLM never
sees implementation/transport details.

### Hard invariants

1. `MetricsLogReader` is SQLite-first with JSONL fallback. Dashboards, the REST API and the
   launcher health checks all depend on it.
2. The freshness contract (`shared/liveness.py`) is shared by the launcher, the validator
   and the REST API. The shell side (`launch_lib/metrics_contract.sh`) wraps the same logic.
3. JSONL writes are never skipped because SQLite failed. Retry + cooldown apply to SQLite only.
4. UE identity precedence is `ue > rnti > positional`. Dashboard dedup, REST entity matching
   and freshness signatures all depend on this order.
5. The agent consumes the **REST API only** — never the JSONL or SQLite files directly.
6. Collector/API/dashboard supervision is user-scoped. Root is used only for the
   core/gNB/UE/namespace work; never `sudo` for user-scoped services.

---

## Requirements

* Linux host with systemd user services (developed on Ubuntu 22.04+)
* **Open5GS** installed, reachable on `127.0.0.5`, `mongosh` available for provisioning
* A RAN backend on `PATH` (or exported):
  * **OAI**: `nr-softmodem` / `nr-uesoftmodem` (`GNB_BIN` / `UE_BIN`) — see `docs/oran_oai_setup.md`
  * **srsRAN**: `gnb` and `srsue`
* Python 3.10+
* **Ollama** (for the agent) with the `RANPilot` model created from `agent/Modelfile`
* `iperf3` for the end-to-end validator and for driving demo traffic

---

## Quick start

```bash
git clone <repo> PI-LEIC
cd PI-LEIC
python3 -m venv src/.venv
source src/.venv/bin/activate
pip install -r requirements.txt

python src/provision_subscribers.py --apply
```

### OAI backend (default)

See `docs/oran_oai_setup.md` for the full OAI build. Then:

```bash
export RAN_BACKEND=oai
export GNB_BIN="$HOME/oai/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem"
export UE_BIN="$HOME/oai/openairinterface5g/cmake_targets/ran_build/build/nr-uesoftmodem"
export METRICS_OUT="$PWD/metrics/oran/gnb_metrics.jsonl"
export METRICS_AGENT_OUT="$PWD/metrics/oran/agent_network_observations.jsonl"
export METRICS_SQLITE_PATH="$PWD/metrics/oran/pi-leic-metrics.sqlite"
bash src/launch_stack.sh
```

### srsRAN backend (fallback)

```bash
RAN_BACKEND=srsran bash src/launch_stack.sh
```

### Inspect

```bash
curl -s http://127.0.0.1:8000/health  | jq
curl -s http://127.0.0.1:8000/metrics | jq
curl -s 'http://127.0.0.1:8000/alerts?status=open' | jq
```

Stop cleanly: `bash src/launch_stack.sh --stop`.
Full validation (needs a real RAN + Open5GS): `bash src/validate_stage.sh`.

---

## The RANPilot agent

`agent/` is a local-LLM operator assistant. It calls the REST API (`/health`, `/metrics`,
`/alerts`), builds a **deterministic** technical summary in Python (numbers are computed,
not generated), then asks a **local Ollama model** to phrase and interpret it — an
anti-hallucination design where the LLM never fetches numbers itself.

```bash
# 1. Pull the base model and create the custom RANPilot model (once)
ollama pull llama3
ollama create RANPilot -f agent/Modelfile

# 2. Run the agent — opens the RANPilot web UI (Chat + Dashboard) at http://localhost:5000
python agent/agent.py
```

* The web UI ([agent/index.html](agent/index.html), served by [agent/server.py](agent/server.py)
  on Flask) has a **Chat** tab (ask in PT-PT, e.g. *"Como está a rede?"*) and a **Dashboard**
  tab (live Chart.js graphs polling the REST API every 2 s).
* Backend is selected with `RAN_BACKEND` (`oai` default / `srsran`); override the metrics API
  base with `METRICS_API_BASE` (default `http://localhost:8000`).

---

## REST API

Base URL `http://127.0.0.1:8000`. JSON everywhere.

| Endpoint | Purpose |
| --- | --- |
| `GET /health`        | Liveness, per-source freshness; always reads fresh, bypasses the snapshot cache |
| `GET /metrics`       | Latest `network-observation.v1` snapshot, or a raw time-window with `from`/`to`/`limit`/`offset`/`cell_id`/`source_id` |

---

## Data contract

### `network-observation.v1` (agent/`/metrics` snapshot)

```jsonc
{
  "schema_version": "network-observation.v1",
  "timestamp": "2026-05-29T10:26:42.6Z",
  "cells": [ { "cell_id": "oai-gnb1-cell-0", "pci": null, "control_channel_load": {…} } ],
  "ues":   [ {
    "ue_id": "rnti:ea1a", "cell_id": "oai-gnb1-cell-0", "sync_state": "in-sync",
    "radio_quality": { "rsrp_dbm": -43.0, "dl_snr_db": 21.3, "ul_snr_db": 17.6, … },
    "throughput":    { "dl_goodput_mbps": 0.0, "ul_goodput_mbps": 0.0 },
    "reliability":   { "dl_bler": 0.0, "ul_bler": 0.0, "dlsch_rounds": [151,0,0,0], … },
    "scheduler":     { "dl_mcs": 0, "ul_mcs": 0, "ul_nprb": 5 },
    "traffic":       { "lcid_bytes": [ … ] }
  } ]
}
```

Missing values stay `null` — **the collector never guesses a metric.** 

### UE identity precedence 

`shared.identity.build_ue_identity()` resolves a stable `ue_identity`:
`ue.ue` (operator label) → `rnti:<value>` → positional `cell{i}-ue{j}`.
RNTI changes on every RACH, so it is only stable within a single snapshot.

### Freshness modes

| Mode | Fresh when |
| --- | --- |
| `signature` | JSON-normalized entity snapshot differs from the baseline |
| `sequence`  | Sequence counter advanced past the baseline |
| `age`       | Sample timestamp is within `FRESHNESS_AGE_WINDOW_SECONDS` of now |
| `hybrid`    | Any of the above (default) |

---


## Project layout

```
config/                      RAN/UE configs, subscribers, metrics source registries
  oai/                       OAI gNB/UE RFsim configs (band n78)
  metrics_sources_oai.json   OAI source registry (oai_mac_stats transport) — default
  metrics_sources.json       srsRAN source registry (websocket_json transport)
D1/                          Original design document and UML diagrams
docs/                        OAI setup runbook, agent contract & briefing
metrics/, var/               Runtime output and persistent state (gitignored)
src/
  launch_stack.sh            main launcher       validate_stage.sh  end-to-end validator
  launch_lib/*.sh            launcher modules
  collector/                 ingestion package (config, transport, enrichment,
                             storage, worker, oai_mac_stats, network_observation)
  shared/                    identity, liveness, env_utils, structured_logging
  metrics_api.py             SQLite-first reader with JSONL fallback
  metrics_rest_api.py        FastAPI app           dashboard.py  Matplotlib live view
  api_models.py              Pydantic request/response models
  provision_subscribers.py   Open5GS MongoDB upsert
agent/                       RANPilot: agent.py (CLI + UI launcher), server.py (Flask),
                             index.html (web UI), Modelfile (Ollama model)
tests/                       Python unit tests + rootless shell tests
```

Shim files at `src/env_utils.py`, `src/metrics_identity.py`, `src/metrics_liveness.py`
and `src/metrics_collector.py` re-export from `src/shared/` and `src/collector/`; do not
delete — external callers rely on them.

---

## Tests and CI

Python unit tests (collector, readers, liveness, identity, REST API, OAI parser, network
observation, dashboard dedup):

```bash
source src/.venv/bin/activate
pip install -e .
python -m unittest discover -s tests -p "test_*.py" -v
```

Shell (rootless, no `sudo`):

```bash
for t in tests/test_launch_lib_*.sh \
         tests/test_launch_stack_dry_run_rootless.sh \
         tests/test_validate_stage_rootless.sh; do
  bash "$t"
done
```

Syntax-only: `bash -n src/launch_stack.sh && bash -n src/validate_stage.sh`

CI (`.github/workflows/ci.yml`) runs on every push and PR: shell syntax, rootless shell
tests, Python syntax, `ruff check` (E, F), the full unit suite, and an `api_smoke` job that
boots the REST API against a synthetic JSONL fixture and hits `/metrics`.