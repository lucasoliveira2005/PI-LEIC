# PI-LEIC

A multi-node 5G RAN monitoring and control platform for PI-LEIC. The repository boots a full 5G stack on a single Linux host (Open5GS
core, two srsRAN gNBs, two srsUEs in separate network namespaces), collects
enriched metrics from both gNBs, stores them durably, serves them through a
REST API and a live dashboard, and exposes a strict action contract ready to
be wired into a control pipeline.


---

## Topology

```
          ┌─────────────────────────────┐
          │  Open5GS core (AMF/SMF/UPF) │
          │          127.0.0.5          │
          └──────────────┬──────────────┘
                         │ NGAP  |  PFCP  |  GTP-U
         ┌───────────────┴───────────────┐
         │                               │
 ┌───────▼───────┐               ┌───────▼───────┐
 │  srsRAN gnb1  │               │  srsRAN gnb2  │
 │  PCI=1        │               │  PCI=2        │
 │  WS :55551    │               │  WS :55552    │
 └───────┬───────┘               └───────┬───────┘
         │  ZMQ fake-radio I/Q           │
 ┌───────▼───────┐               ┌───────▼───────┐
 │ srsue  (ue1)  │               │ srsue  (ue2)  │
 │ netns=ue1     │               │ netns=ue2     │
 └───────────────┘               └───────────────┘

         ws://127.0.0.1:55551 , ws://127.0.0.1:55552
                         │
                         ▼
              ┌──────────────────────────┐
              │   metrics_collector.py   │
              │  one worker per source   │
              │  enrich → dual-write     │
              └──────────┬───────────────┘
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
 metrics/gnb_metrics.jsonl     /tmp/pi-leic-metrics.sqlite
                         │
                         │   SQLite-first read, JSONL fallback
                         ▼
              ┌──────────────────────────┐
              │      metrics_api.py      │
              │     MetricsLogReader     │
              └─────┬───────────────┬────┘
                    │               │
        ┌───────────▼─┐           ┌─▼─────────────────────────┐
        │ dashboard.py│           │   metrics_rest_api.py     │
        │ Matplotlib  │           │   FastAPI on :8000        │
        └─────────────┘           │   /metrics  /metrics_prom │
                                  │   /alerts   /health       │
                                  │   /query    /actions      │
                                  └───────────────────────────┘
```

The topology is supervised by `src/launch_stack.sh` with transient systemd
units: root units for gNB/UE namespace work, and user units for the Python
collector, REST API, and dashboard. It is verified end-to-end by
`src/validate_stage.sh`.

---

## Architecture

Three layers, each one derivable from the layer below; each one optional for
the one above:

| Layer | Role | Files |
| --- | --- | --- |
| **Data** | Ingest, enrich, persist | `collector/`, `metrics/*.jsonl`, SQLite |
| **Processing** | Read, shape, reason about data | `metrics_api.py`, `shared/liveness.py`, `shared/identity.py` |
| **Interface** | Expose data and actions | `metrics_rest_api.py`, `dashboard.py` |

### Storage tiers

* **JSONL** is the source of truth. Append-only, schema-flexible (so the gNB
  metric families `cells`, `rlc_metrics`, `du`, `du_low` can evolve without
  migrations), human-readable with `tail -f` and `jq`, rotatable, archived
  newest-first on read.
* **SQLite (WAL mode)** is a derived index. Two tables: `metrics_events` (one
  row per enriched event) and `metrics_cell_entities` (per-UE denormalized for
  fast range queries). Retention is bounded (`METRICS_SQLITE_RETENTION_MAX_ROWS`,
  default 200k). If SQLite is unavailable, every reader falls back to JSONL.
* **Prometheus exposition (`/metrics_prom`)** is a stateless projection built
  on top of the same snapshot cache used by `/metrics`. Grafana reads it.

### Hard invariants

1. `MetricsLogReader` is SQLite-first with JSONL fallback. Both dashboards and
   the REST API depend on it. In the future, this read boundary is where
   InfluxDB or the O-RAN SC-RIC shared data layer can be wired in.
2. The freshness contract (`shared/liveness.py`) is shared by the launcher,
   the validator, and the REST API. The shell side (`launch_lib/metrics_contract.sh`)
   wraps the same Python helpers.
3. JSONL writes are never skipped because SQLite failed. The collector applies
   retry + cooldown logic to SQLite only.
4. UE identity precedence is `ue > rnti > positional`. Dashboard deduplication,
   REST entity matching, and freshness signatures all depend on this order.
5. `/metrics_prom` is read-only. It must not mutate `api_alert_state`, because
   Prometheus scrapes every few seconds and any mutation would corrupt
   `first_seen_at` / `cleared_at` transitions.
6. Collector/API/dashboard supervision is user-scoped. The launcher uses root
   only for Open5GS, gNB, UE namespace, and privileged network operations; it
   never uses `sudo` for user-scoped service management.

---

## Requirements

* Linux host with systemd user services available (developed on Ubuntu 22.04+)
* Open5GS installed, its services reachable on `127.0.0.5`, and `mongosh`
  available for subscriber provisioning
* srsRAN Project `gnb` binary on `PATH`, or exported as `GNB_BIN=/path/to/gnb`
* srsUE on `PATH`
* Python 3.10 or newer
* `iperf3` for the end-to-end validator
* A graphical terminal emulator (`gnome-terminal`, `konsole`, `xterm`) only if
  you want the legacy `--mode terminals`

---

## Quick start

```bash
git clone <repo> PI-LEIC
cd PI-LEIC
python3 -m venv src/.venv
source src/.venv/bin/activate
pip install -r requirements.txt

python src/provision_subscribers.py --apply
bash src/launch_stack.sh
```

In a second terminal:

```bash
curl -s http://127.0.0.1:8000/health  | jq
curl -s http://127.0.0.1:8000/metrics | jq
curl -s 'http://127.0.0.1:8000/alerts?status=open' | jq
curl -s http://127.0.0.1:8000/metrics_prom
```

Stop cleanly: `bash src/launch_stack.sh --stop`.
Full validation (needs real Open5GS and srsRAN): `bash src/validate_stage.sh`.

---

## Project layout

```
config/                      gNB/UE configs, subscribers, metrics source registry
config/grafana/              importable Grafana dashboard + Prometheus scrape stub
D1/                          Design document and UML diagrams
metrics/                     Runtime JSONL output (gitignored)
var/                         Persistent runtime state: audit DB, freshness baseline (gitignored)
src/
  launch_stack.sh            main launcher
  validate_stage.sh          end-to-end validator
  launch_lib/*.sh            shell modules used by the launcher
  collector/                 metrics ingestion package
    config.py                env-var globals
    enrichment.py            event enrichment and contract fields
    transport.py             WebSocketSourceAdapter
    storage.py               JSONL rotation + SQLite dual-write
    worker.py                per-source worker thread, watchdog, main()
  shared/                    utilities
    identity.py              UE identity precedence (ue > rnti > positional)
    liveness.py              freshness contract (signature/sequence/age/hybrid)
    env_utils.py             env var parsing helpers
  api_models.py              Pydantic request/response models
  metrics_api.py             SQLite-first reader with JSONL fallback
  metrics_rest_api.py        FastAPI app (REST + Prometheus scrape)
  dashboard.py               Matplotlib live dashboard
  provision_subscribers.py   Open5GS MongoDB upsert
tests/                       Python unit tests and rootless shell tests
agent/                       Ollama-backed agent prototype (CLI)
```

Shim files at `src/env_utils.py`, `src/metrics_identity.py`,
`src/metrics_liveness.py`, and `src/metrics_collector.py` re-export from
`src/shared/` and `src/collector/`; do not delete, external callers rely on them.

---

## Running the stack

`src/launch_stack.sh` runs the Python services as transient systemd user units
and the radio/core pieces that need privileges as transient root units. Before
starting the gNBs it gates on: required units `active`, core-readiness log
markers, SMF-to-AMF association, PFCP and GTP-U sockets bound, and active
endpoint probes. Always run as your regular user, not via `sudo`; the launcher
escalates only where it must.

```bash
bash src/launch_stack.sh                  # supervised (default)
bash src/launch_stack.sh --status
bash src/launch_stack.sh --logs collector # or: api | gnb1 | gnb2 | ue1 | ue2
bash src/launch_stack.sh --stop
bash src/launch_stack.sh --dry-run        # print actions, touch nothing
bash src/launch_stack.sh --mode terminals # legacy GUI-terminal fan-out
```

`src/validate_stage.sh` provisions subscribers, launches the stack, runs
concurrent `iperf3` from both UE namespaces, and checks that every configured
source reports fresh non-zero DL/UL through the shared reader contract. The
freshness baseline is persisted under `var/freshness_baseline.json`, so a
crash between baseline capture and validation is recoverable on the next run.
See `STAGE_OVERVIEW.md` §6 and §12 for the manual single-component flow.

---

## REST API

Base URL `http://127.0.0.1:8000`. JSON responses everywhere except
`/metrics_prom`, which returns Prometheus text exposition.

| Endpoint | Purpose |
| --- | --- |
| `GET /health`        | Liveness, per-source freshness; always reads fresh, bypasses the snapshot cache |
| `GET /capabilities`  | Feature flags, ingestion vs target transport, ruleset, freshness policy |
| `GET /metrics`       | Latest snapshot, or a time window with `from` / `to` / `cell_id` / `source_id` filters |
| `GET /metrics_prom`  | Prometheus gauges per source and per UE; also `alerts_open` counts and `api_uptime_seconds`. Read-only |
| `GET /alerts?status=open\|all` | Rule-based alerts with provenance (`rule.id`, `rule.parameters`, `rule.evidence`); lifecycle persisted in audit DB |
| `POST /query`        | Operator question, currently a deterministic stub (`answered_stub`, `llm_not_integrated`) |
| `POST /actions`      | Strict `ActionIntent` audit-only submission |

Audit storage lives at `var/pi-leic-api-audit.sqlite` by default (persistent
across reboot):

* `api_audit_log`: one row per `/query` and `/actions` response
* `api_alert_state`: alert lifecycle (`first_seen_at`, `last_seen_at`, `cleared_at`)

### Action contract

`POST /actions` requires a complete `ActionIntent`. `proposed_value` must
satisfy `bounds.min_value <= proposed_value <= bounds.max_value`; out-of-bounds
submissions are rejected by Pydantic at parse time.

```json
{
  "request": "reduce cell power by 2 dB",
  "approve": true,
  "intent": {
    "target": "cell:gnb1:0",
    "parameter": "tx_power_dbm",
    "unit": "dBm",
    "proposed_value": 18.0,
    "current_value": 20.0,
    "bounds": { "min_value": 10.0, "max_value": 23.0 },
    "reason": "mitigate observed interference",
    "safety_checks": ["verify_cell_online"],
    "dry_run": true
  }
}
```

* `approve=false` → `status=pending_approval`, audit row written.
* `approve=true`  → `status=approved_not_executed`, audit row written. Runtime
  parameter mutation is deliberately disabled in this stage.

### Prometheus scrape

```yaml
scrape_configs:
  - job_name: pi-leic-api
    scrape_interval: 5s
    scrape_timeout: 3s
    metrics_path: /metrics_prom
    static_configs:
      - targets: ["127.0.0.1:8000"]
```

Connect Grafana to the same Prometheus instance, then import
`config/grafana/pi-leic-overview.json`. The dashboard expects a Prometheus
datasource and renders per-source freshness, per-UE throughput and SNR, open
alerts by type, sample age, and sequence progression. A ready-to-copy scrape
config also lives at `config/grafana/prometheus-scrape.yml`.

### Dashboard (Matplotlib)

```bash
python src/dashboard.py
```

Local window showing a 50-sample rolling history per `(source_id, ue_identity)`
pair. Headless operation is not supported; use the Prometheus exporter and
Grafana for browser-reachable viewing.

---

## Data contract

### Enriched event

Each line in `metrics/gnb_metrics.jsonl` (and each row in `metrics_events`) is:

```jsonc
{
  "collector_timestamp": "2026-04-16T14:03:22.117Z",
  "source_id":          "gnb1",
  "gnb_id":             "gnb1",
  "source_endpoint":    "ws://127.0.0.1:55551",
  "metric_family":      "cells",         // cells | rlc_metrics | du_low | du | unknown
  "event_type":         "metric",        // metric | alarm | state
  "schema_version":     "1.0",
  "timestamp":          1713268999.412,
  "raw_payload":        { /* verbatim gNB JSON */ },
  "cell_id":            1,
  "ue_id":              "rnti:4601",
  "throughput_mbps":    12.8754,
  "bler_pct":           0.42
}
```

`prb_usage_pct`, `latency_ms`, and `rsrp_dbm` are not populated yet because
srsRAN's WebSocket metrics JSON does not expose them directly. See
`STAGE_OVERVIEW.md` Gap 2 for the tracked follow-up.

### UE identity precedence (hard invariant)

`shared.identity.extract_cell_ue_entities()` resolves a stable `ue_identity`
in this order:

1. `ue.ue` (operator-assigned label)
2. `ue.rnti` (formatted `rnti:<value>`)
3. positional fallback `cell{i}-ue{j}`

### Freshness modes

| Mode | Fresh when |
| --- | --- |
| `signature` | JSON-normalized entity snapshot differs from the baseline |
| `sequence`  | Sequence counter advanced past the baseline |
| `age`       | Sample timestamp is within `FRESHNESS_AGE_WINDOW_SECONDS` of now |
| `hybrid`    | Any of the above (default) |

---

## Configuration reference

Only the knobs you are most likely to change. `STAGE_OVERVIEW.md` §4 has the
complete list.

### Freshness

| Variable | Default | Effect |
| --- | --- | --- |
| `FRESHNESS_CHECK_MODE` | `hybrid` | `signature`, `sequence`, `age`, or `hybrid` |
| `FRESHNESS_AGE_WINDOW_SECONDS` | `15` | Upper bound on acceptable sample age |
| `FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS` | `2` | Host clock drift tolerance |
| `FRESHNESS_BASELINE_PATH` | `var/freshness_baseline.json` | Persistent validator baseline |

### Collector

| Variable | Default | Effect |
| --- | --- | --- |
| `METRICS_SOURCES_CONFIG` | `config/metrics_sources.json` | Source registry path |
| `METRICS_OUT` | `metrics/gnb_metrics.jsonl` | JSONL output path |
| `METRICS_ROTATE_MAX_BYTES` | `52428800` (50 MiB) | Rotate at this size |
| `METRICS_ROTATE_MAX_FILES` | `5` | Archive files kept |
| `METRICS_SQLITE_ENABLED` | `1` | Toggle SQLite dual-write |
| `METRICS_SQLITE_PATH` | `/tmp/pi-leic-metrics.sqlite` | SQLite WAL path |
| `METRICS_SQLITE_TIMEOUT_SECONDS` | `5` | SQLite connection timeout |
| `METRICS_SQLITE_RETRY_MAX_FAILURES` | `5` | Consecutive failures before cooldown |
| `METRICS_SQLITE_RETRY_COOLDOWN_SECONDS` | `10` | Cooldown on sustained failures |
| `METRICS_SQLITE_RETENTION_MAX_AGE_DAYS` | `0` (disabled) | Optional age-based pruning |
| `METRICS_SQLITE_RETENTION_MAX_ROWS` | `200000` | Prune oldest rows beyond this count |
| `METRICS_SQLITE_RETENTION_INTERVAL_EVENTS` | `500` | Pruning check cadence |
| `METRICS_SQLITE_RETENTION_VACUUM` | `0` | Run `VACUUM` after retention pruning |
| `METRICS_RECONNECT_SECONDS` | `3` | Delay before reconnecting a source |
| `METRICS_WS_PING_INTERVAL_SECONDS` | `15` | Set `0` to disable WebSocket keepalive |
| `METRICS_WS_PING_TIMEOUT_SECONDS` | `5` | WebSocket ping timeout, clamped to interval |

Collector ingestion is not env-selectable in this stage:
`WebSocketSourceAdapter` is the only active backend. The planned target is an
E2SM-KPM adapter beside it; the old ZMQ-as-metrics-transport direction was
retired. The ZMQ in the gNB/UE config files is only the RF-plane fake-radio
link.

### REST API and alerts

| Variable | Default | Effect |
| --- | --- | --- |
| `API_HOST` | `0.0.0.0` | Bind address |
| `API_PORT` | `8000` | Listen port |
| `API_AUDIT_DB_ENABLED` | `1` | Persist `/query` and `/actions` audit events |
| `API_AUDIT_DB_PATH` | `var/pi-leic-api-audit.sqlite` | Audit DB path (persistent) |
| `ALERT_STALE_AFTER_SECONDS` | `30` (capped at 300) | Threshold for `stale-source` |
| `ALERT_MIN_DL_BRATE` | `-1.0` (disabled) | Fire `low-throughput` when DL at or below this |
| `ALERT_MIN_UL_BRATE` | `-1.0` (disabled) | Fire `low-throughput` when UL at or below this |
| `ALERT_RULESET_VERSION` | `rules-v1` | Ruleset identifier advertised by `/capabilities` |
| `QUERY_BACKEND_MODE` | `heuristic-stub` | `heuristic-stub` → `llm-local` → `llm-hosted` |
| `METRICS_SNAPSHOT_TTL_SECONDS` | `5` (capped at 60) | Snapshot cache TTL for `/metrics` and `/alerts` |
| `METRICS_WINDOW_MAX_ITEMS` | `10000` | Max items returned by `/metrics` time-window queries |

### Launcher

| Variable | Default | Effect |
| --- | --- | --- |
| `API_ENABLED` | `1` | Start the REST API user service |
| `DASHBOARD_ENABLED` | `1` | Start `dashboard.py` when a display is available |
| `HEALTHCHECK_STRICT` | `0` | Fail-fast on any post-launch health check miss |
| `CORE_READINESS_TIMEOUT_SECONDS` | `45` | Upper bound on core-readiness wait |
| `UNIT_PREFIX` | `pi-leic` | systemd transient unit prefix |
| `DRY_RUN` | `0` | Print actions without executing privileged commands |

---

## Tests and CI

Python (91 unit tests covering collector, readers, liveness, identity, REST
API, and dashboard dedup):

```bash
source src/.venv/bin/activate
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

Syntax-only:

```bash
bash -n src/launch_stack.sh
bash -n src/validate_stage.sh
```

CI (`.github/workflows/ci.yml`) has two jobs on every push and pull request:

1. **test**: shell syntax, rootless shell behavior tests, Python syntax,
   `ruff check` (E, F), and the full unit test suite.
2. **api_smoke**: boots the REST API against a synthetic JSONL fixture, hits
   `/metrics`, `/alerts`, `/metrics_prom`, and verifies that repeated
   Prometheus scrapes do not mutate the alert lifecycle.

The full end-to-end validator (`validate_stage.sh`) needs real Open5GS and
srsRAN on the host and is therefore not run in CI.
