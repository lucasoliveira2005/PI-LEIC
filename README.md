# PI-LEIC

A multi-node 5G RAN monitoring and control platform for a university lab at
FEUP. The repository boots a full 5G stack on a single Linux host (Open5GS
core, two srsRAN gNBs, two srsUEs in separate network namespaces), collects
enriched metrics from both gNBs, stores them durably, serves them through a
REST API and a live dashboard, and exposes a strict action contract ready to
be wired into a control pipeline.

Current branch: `feat/multi-gnb-stage`. Design reference: `D1/DesenhoSolução.md`
(Portuguese). Stage onboarding walkthrough: `STAGE_OVERVIEW.md`.

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

The entire topology is supervised by `src/launch_stack.sh` (transient systemd
user units) and verified end-to-end by `src/validate_stage.sh`.

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

Three layers, each one redundantly derivable from the one above. A failure in
any single tier degrades the platform; it never takes it down.

* **JSONL** — `metrics/gnb_metrics.jsonl`. Append-only, schema-flexible (the
  gNB metric families `cells`, `rlc_metrics`, `du`, `du_low` can evolve without
  migrations because `raw_payload` passes through verbatim). Human-readable
  with `tail -f` and `jq`. Rotates at `METRICS_ROTATE_MAX_BYTES` (50 MiB),
  keeps `METRICS_ROTATE_MAX_FILES` (5) archives, and the reader merges archives
  newest-first on read. This is the **durable log of record**.
* **SQLite (WAL mode)** — `/tmp/pi-leic-metrics.sqlite`. Derived index with
  two tables: `metrics_events` (one row per enriched event, fast family and
  source lookups) and `metrics_cell_entities` (per-UE denormalized rows keyed
  by `(source_id, collector_timestamp, cell_index, ue_identity)` for cheap
  time-window queries). Retention is bounded
  (`METRICS_SQLITE_RETENTION_MAX_ROWS` default 200 000; periodic pruning every
  500 events). Dual-write has retry + cooldown: the collector never blocks a
  JSONL write because SQLite is temporarily unhappy.
* **Audit DB** — `var/pi-leic-api-audit.sqlite` (persistent across reboot,
  distinct from the ephemeral metrics cache). Holds `api_audit_log` (one row
  per `/query` and `/actions` response) and `api_alert_state` (alert
  lifecycle: `first_seen_at`, `last_seen_at`, `cleared_at`, `status`). This is
  the operator-facing audit trail and never goes through the metrics dual-write
  pipeline.
* **Prometheus exposition (`/metrics_prom`)** — a stateless projection of the
  snapshot cache already used by `/metrics`. Scraped by Prometheus, read by
  Grafana. See the dedicated section below.

### Why this storage model stays under SC-RIC (do not delete)

The long-term target is integration with the **O-RAN Software Community
Near-RT RIC** (see `CLAUDE.md → Target direction` for the phased plan). It is
tempting to assume that once the collector is receiving E2SM-KPM indications
from the RIC, the local JSONL / SQLite tier is redundant because SC-RIC ships
its own canonical stores (InfluxDB for time-series, SDL/Redis for shared xApp
state). That assumption is wrong. Each tier has a job the RIC stores cannot
absorb:

* **JSONL is transport-agnostic replay.** The `raw_payload` field is the
  verbatim JSON off the wire — today a srsRAN WebSocket metrics frame,
  tomorrow a KPM indication serialized as JSON. Because JSONL keeps the
  original payload, an old metrics file produced under the WebSocket backend
  still replays cleanly through a future KPM-aware collector. This is how we
  tune alert rules, reproduce incidents, and regression-test the enrichment
  pipeline offline without RF.
* **JSONL is the last-ditch fallback.** `MetricsLogReader` is SQLite-first
  with JSONL fallback today; in Phase 4 it becomes InfluxDB-first → SQLite →
  JSONL. If the RIC pod is restarting, if the Prometheus scraper misfires, if
  a k8s network partition isolates the operator console from the RIC cluster,
  the REST API, dashboard, launcher health checks, and validator freshness
  contract all continue to serve from local files. The rApp / agent tier
  stays available when the RIC tier is not.
* **SQLite is the query engine next to the reader.** The REST API is a Python
  process; round-tripping every `/metrics?from=...&to=...` query across the
  network to InfluxDB would make the operator console latency-bound on the
  RIC. Keeping SQLite as the local mirror collapses most reads back into
  microseconds and is how the snapshot cache stays useful.
* **The audit DB is ours to own.** SC-RIC's SDL is designed for short-lived
  xApp coordination state, not for operator audit trails. Who approved which
  `ActionIntent`, when a given alert first fired, when it cleared — those
  records belong to the platform and must survive RIC upgrades, pod crashes,
  and cluster migrations. Phase 5 (Control xApp for E2SM-RC) explicitly
  preserves this: the audit row is written before the xApp is asked to emit
  a control message.
* **Phase 4 is additive, not substitutive.** The storage migration adds
  InfluxDB as a **third backend** in front of SQLite, not as a replacement.
  The dispatcher remains `primary → local mirror → durable log` so that the
  operator workflow never strictly depends on the availability of a store
  that lives inside the RIC cluster.

Deleting the local tier — or skipping it in the name of "we have a RIC
eventually" — would break: the dashboard, every REST endpoint, the launcher's
core-readiness gate, the validator's freshness contract, offline replay, the
rApp decoupling that lets the agent team iterate without standing up SC-RIC,
and the audit trail that makes `/actions` accountable. Each of those is
explicitly listed as a hard invariant in `CLAUDE.md`.

### Hard invariants (do not regress)

1. `MetricsLogReader` is SQLite-first with JSONL fallback. Both dashboards and
   the REST API depend on this preference.
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
6. Transient systemd units run rootless. The launcher never uses `sudo` for
   user-scoped service management.

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
  you want the legacy `--mode terminals` fan-out

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
D1/                          Design document (Portuguese) and UML diagrams
metrics/                     Runtime JSONL output (gitignored)
var/                         Persistent runtime state: audit DB, freshness baseline (gitignored)
src/
  launch_stack.sh            main launcher
  validate_stage.sh          end-to-end validator
  launch_lib/*.sh            shell modules used by the launcher
  collector/                 metrics ingestion package
    config.py                env-var globals
    enrichment.py            event enrichment and contract fields
    transport.py             WebSocketSourceAdapter (E2SM KPM adapter lands in Phase 1)
    storage.py               JSONL rotation + SQLite dual-write
    worker.py                per-source worker thread, watchdog, main()
  shared/                    cross-cutting utilities
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

`src/launch_stack.sh` runs each component as a transient systemd user unit.
Before starting the gNBs it gates on: required units `active`, core-readiness
log markers, SMF-to-AMF association, PFCP and GTP-U sockets bound, and active
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
| `GET /capabilities`  | Feature flags (`llm_integrated`, `action_mutation_pipeline_enabled`, `query_backend_mode`, `action_execution_mode`); transport descriptor (`current` / `target` / `target_platform`); storage, freshness policy, alert ruleset |
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

### Prometheus and Grafana — what they do here, and why

`GET /metrics_prom` exposes the platform's live state in the **Prometheus text
exposition format**. Prometheus pulls (scrapes) this endpoint on a fixed
interval, stores each sample as a labelled time series, and serves a query
language (**PromQL**) over that history. Grafana is a browser-based
visualization frontend that runs PromQL against Prometheus and renders
dashboards. Together they replace the desktop-only `dashboard.py` with a
multi-operator, retention-friendly observability stack.

**Why pull and not push.** The collector's JSONL and SQLite tiers are a
write-through log + index of individual events. Prometheus is not a log; it is
a *gauge store* — it samples the current value of each metric at scrape time
and stores the time series. The two are complementary: JSONL / SQLite answers
"what happened between 14:03:00 and 14:03:15 on gnb1?", Prometheus answers
"what is the rolling 1-minute average DL throughput across all UEs on gnb1?".
Keeping the exporter read-only and stateless is an explicit invariant (see
`tests/test_metrics_rest_api.py::test_metrics_prom_does_not_mutate_alert_lifecycle`) —
if scraping mutated the alert lifecycle table, Prometheus' 5-second cadence
would flood `first_seen_at` / `cleared_at` transitions.

**What the exposition contains** (rendered by
`_render_prometheus_exposition` in `src/metrics_rest_api.py`):

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `gnb_source_fresh` | gauge | `source_id` | `1` if the latest sample is within `ALERT_STALE_AFTER_SECONDS`, else `0`. Same rule as the `stale-source` alert. |
| `gnb_source_last_sample_age_seconds` | gauge | `source_id` | Age in seconds of the most recent sample per source. Drives freshness panels and SLO burn-rate math. |
| `gnb_source_sequence` | gauge | `source_id` | Monotonic counter of cells-family events per source. Zero increase over a window is a silent source. |
| `gnb_source_entities` | gauge | `source_id` | Number of UE entities in the most recent snapshot. |
| `gnb_ue_dl_brate_bps` | gauge | `source_id`, `cell_index`, `pci`, `ue_identity` | Latest downlink bitrate per UE (bits/s). |
| `gnb_ue_ul_brate_bps` | gauge | `source_id`, `cell_index`, `pci`, `ue_identity` | Latest uplink bitrate per UE (bits/s). |
| `gnb_ue_throughput_mbps` | gauge | same as above | `(dl_brate + ul_brate) / 1e6`, matching the D1 contract field. |
| `gnb_ue_pusch_snr_db` | gauge | same as above | Latest PUSCH SNR per UE, when the source reports it. |
| `gnb_alerts_open` | gauge | `type` | Current open alert count by type (`stale-source`, `low-throughput`), computed from the same snapshot — pure function, no DB mutation. |
| `gnb_api_uptime_seconds` | gauge | — | Seconds since the REST API process started. |

**Scrape configuration.** A ready-to-copy file lives at
`config/grafana/prometheus-scrape.yml`:

```yaml
scrape_configs:
  - job_name: pi-leic-api
    metrics_path: /metrics_prom
    static_configs:
      - targets: ["127.0.0.1:8000"]
    scrape_interval: 5s
    scrape_timeout: 3s
```

Drop it under your Prometheus `scrape_configs`, reload Prometheus, and the
series start flowing. The 5 s cadence deliberately matches
`METRICS_SNAPSHOT_TTL_SECONDS` default; a faster cadence just pays the I/O
cost without seeing fresher data.

**Grafana dashboard.** `config/grafana/pi-leic-overview.json` is an importable
dashboard (Grafana → Dashboards → Import → upload JSON). It binds to a
Prometheus datasource variable (`${DS_PROMETHEUS}`) and a per-source template
variable (`$source_id`) populated by
`label_values(gnb_source_fresh, source_id)`. Panels include source freshness
(stat, STALE=red / FRESH=green), UE entities per source, last-sample age,
sequence progression, per-UE DL / UL throughput, PUSCH SNR, and open alerts
by type. All metric references come straight from the exposition table above,
so the dashboard stays in sync with the exporter as long as metric names
remain stable.

**How this fits the SC-RIC target.** Prometheus is the de-facto metrics
surface for O-RAN SMO / FCAPS stacks, and SC-RIC components expose their own
Prometheus endpoints for operational visibility. Keeping our operator-facing
dashboard on Prometheus + Grafana means that when Phase 1 boots a FlexRIC
container and Phase 2 adds the E2SM-KPM adapter, the existing Grafana board
continues to work unchanged for our metrics, and it can be extended
side-by-side with panels that scrape the RIC's own Prometheus exporter. No
dashboard code is throwaway.

### Dashboard (Matplotlib, deprecated)

```bash
python src/dashboard.py
```

Local window showing a 50-sample rolling history per `(source_id, ue_identity)`
pair. Retained only as a dev-time live view while the Grafana dashboard matures
to cover the same demo flow — see the DEPRECATED note at the top of
`src/dashboard.py`. Do not add new panels or features here; build them in
Grafana instead. Headless operation is not supported.

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
| `METRICS_SQLITE_RETRY_MAX_FAILURES` | `5` | Consecutive failures before cooldown |
| `METRICS_SQLITE_RETRY_COOLDOWN_SECONDS` | `10` | Cooldown on sustained failures |
| `METRICS_SQLITE_RETENTION_MAX_ROWS` | `200000` | Prune oldest rows beyond this count |
| `METRICS_WS_PING_INTERVAL_SECONDS` | `15` | Set `0` to disable WebSocket keepalive |

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

### Launcher

| Variable | Default | Effect |
| --- | --- | --- |
| `API_ENABLED` | `1` | Start the REST API user service |
| `DASHBOARD_ENABLED` | `0` | Start `dashboard.py` |
| `HEALTHCHECK_STRICT` | `0` | Fail-fast on any post-launch health check miss |
| `CORE_READINESS_TIMEOUT_SECONDS` | `45` | Upper bound on core-readiness wait |
| `UNIT_PREFIX` | `pi-leic` | systemd transient unit prefix |
| `DRY_RUN` | `0` | Print actions without executing privileged commands |

---

## Tests and CI

Python (85 unit tests covering collector, readers, liveness, identity, REST
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

CI (`.github/workflows/ci.yml`) has three jobs on every push:

1. **test**: shell syntax, rootless shell behavior tests, Python syntax,
   `ruff check` (E, F), and the full unit test suite.
2. **api_smoke**: boots the REST API against a synthetic JSONL fixture, hits
   `/metrics`, `/alerts`, `/metrics_prom`, and verifies that repeated
   Prometheus scrapes do not mutate the alert lifecycle.

The full end-to-end validator (`validate_stage.sh`) needs real Open5GS and
srsRAN on the host and is therefore not run in CI.
