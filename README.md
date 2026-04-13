# PI-LEIC

## Current Stage

This repository is now organized around the current multi-node lab stage:

- `1 Open5GS` core
- `2 gNBs`
- `2 UEs`
- `1` central metrics collector
- `1` dashboard reading enriched multi-source metrics

The main topology files for this stage are:

- `config/gnb_gnb1_zmq.yaml`
- `config/gnb_gnb2_zmq.yaml`
- `config/ue1_zmq.conf.txt`
- `config/ue2_zmq.conf.txt`
- `config/metrics_sources.json`
- `config/subscribers.json`

These older files are still kept as single-node reference/debug files, but they are no longer the main path:

- `config/gnb_zmq.yaml`
- `config/ue_zmq.conf.txt`

## Prerequisites

Before running the stack, make sure the machine has:

- Open5GS installed and running
- `mongosh` available locally
- `systemd-run` available locally
- `srsue` available on `PATH`
- `gnb` from srsRAN Project available on `PATH`, or exported through `GNB_BIN`
- a graphical terminal emulator such as `gnome-terminal`, `konsole`, `xterm`, or `x-terminal-emulator` only if you want the fallback `--mode terminals`

If `gnb` is not installed system-wide, export the binary path before launching:

```bash
export GNB_BIN=/path/to/srsRAN_Project/build/apps/gnb/gnb
```

## Python Setup

Use one supported Python flow for every local Python tool in this repository:

```bash
cd /path/to/PI-LEIC
python3 -m venv src/.venv
source src/.venv/bin/activate
python -m pip install -r requirements.txt
```

After that, run repo Python tools from the same environment:

```bash
python src/metrics_collector.py
python src/dashboard.py
python src/provision_subscribers.py
```

## Subscriber Provisioning

The versioned subscriber source of truth for this stage is:

- `config/subscribers.json`

Preview the planned Open5GS subscriber changes first:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
python src/provision_subscribers.py
```

Apply them when the preview looks correct:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
python src/provision_subscribers.py --apply
```

To provision only one subscriber:

```bash
python src/provision_subscribers.py --apply --only ue2
```

## Run The Full Stage

The recommended flow for this stage is:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
python src/provision_subscribers.py --apply
bash src/launch_stack.sh
```

Run the launcher as your regular user (no `sudo` before the command). It
requests sudo internally only for privileged operations and needs access to
your systemd user services.

`src/launch_stack.sh` is the main launcher for this stage. It:

- uses supervised mode by default
- prompts for sudo once up front
- cleans up stale PI-LEIC gNB, UE, and collector processes from older runs
- restarts the Open5GS core services
- launches `gNB1` and `gNB2` via `systemd-run`
- creates `ue1` and `ue2` namespaces automatically before launching the UEs
- launches `UE1` and `UE2` via `systemd-run`
- launches the central metrics collector as a user service
- optionally launches the dashboard
- waits dynamically for Open5GS core readiness (active units, startup log markers, live socket probes, and active endpoint probes) before starting attach-sensitive components
- runs readiness checks after the supervised stack has actually started
- waits for each UE namespace to gain tunnel IPv4 and a default route
- verifies that the required supervised units are actually active before reporting ready
- fails fast when explicit attach/PDU failure signals are detected in UE/core logs

When the dashboard is disabled or there is no display, `--status` only reports user
units that are actually loaded.

The default supervised mode is the recommended path for repeatable runs and automation.

If you want to inspect what it will do without opening terminals:

```bash
bash src/launch_stack.sh --dry-run
```

Useful supervised commands:

```bash
bash src/launch_stack.sh --status
bash src/launch_stack.sh --logs collector
bash src/launch_stack.sh --logs gnb1
bash src/launch_stack.sh --stop
```

If you still want the older GUI-terminal workflow for manual debugging:

```bash
bash src/launch_stack.sh --mode terminals
```

## Validation Run

Use this to replay the full milestone validation against fresh metrics from the current run only:

```bash
cd /path/to/PI-LEIC
bash src/validate_stage.sh
```

Run the validator as your regular user (no `sudo` before the command). It
requests sudo internally only for privileged operations and relies on
systemd user services for supervised orchestration.

It will:

- apply `config/subscribers.json`
- launch the full stack
- send traffic from `ue1` and `ue2` to `10.45.0.1`
- confirm fresh metrics for every configured source via the shared reader contract (`src/metrics_api.py`, SQLite-first with JSONL fallback)
- confirm fresh non-zero `dl_brate` and `ul_brate` for all observed UE entities in every configured source

This is the authoritative end-to-end validation flow. By default it launches the stack in supervised mode, enables dynamic core readiness checks before UE attach (including live socket and active endpoint probes), enables strict launch readiness checks for service and metrics health, fails fast on explicit attach/PDU failure signals with categorized cause summaries, disables the dashboard, defers UE data-path checks to this script, waits for each UE namespace to gain a usable route, and validates after real traffic has been generated. If a stale manual run is still holding ZMQ or NG-U ports, the launcher now cleans up the old PI-LEIC lab processes before starting the supervised units.

If you already have part of the stack running, you can skip steps:

```bash
bash src/validate_stage.sh --skip-provision --skip-launch
```

## Manual Run

Use this when debugging one component at a time.

1. Provision the subscribers:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
python src/provision_subscribers.py --apply
```

2. Start the core log terminal:

```bash
sudo tail -f /var/log/open5gs/amf.log
```

3. Start `gNB1`:

```bash
cd /path/to/PI-LEIC
sudo "${GNB_BIN:-gnb}" -c config/gnb_gnb1_zmq.yaml
```

4. Start `gNB2`:

```bash
cd /path/to/PI-LEIC
sudo "${GNB_BIN:-gnb}" -c config/gnb_gnb2_zmq.yaml
```

5. Create the UE namespaces:

```bash
sudo ip netns del ue1 2>/dev/null
sudo ip netns add ue1
sudo ip netns del ue2 2>/dev/null
sudo ip netns add ue2
```

6. Start `UE1`:

```bash
cd /path/to/PI-LEIC
sudo srsue config/ue1_zmq.conf.txt
```

7. Start `UE2`:

```bash
cd /path/to/PI-LEIC
sudo srsue config/ue2_zmq.conf.txt
```

8. Start the central metrics collector:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
export METRICS_SOURCES_CONFIG=config/metrics_sources.json
export METRICS_OUT=metrics/gnb_metrics.jsonl
python src/metrics_collector.py
```

9. Start the dashboard:

```bash
cd /path/to/PI-LEIC
source src/.venv/bin/activate
export METRICS_OUT=metrics/gnb_metrics.jsonl
export MPLCONFIGDIR=/tmp/pi-leic-matplotlib
python src/dashboard.py
```

## Metrics Output

The current multi-node flow writes enriched JSONL metrics to:

- `metrics/gnb_metrics.jsonl`

The collector source list is defined in:

- `config/metrics_sources.json`

The internal metrics access layer used by the dashboard is:

- `src/metrics_api.py`

The collector now supports built-in JSONL rotation/retention with environment variables:

- `METRICS_ROTATE_MAX_BYTES` (default `52428800`, 50 MiB)
- `METRICS_ROTATE_MAX_FILES` (default `5`)

The collector also supports a SQLite cache path used by dashboards and fast API
queries:

- `METRICS_SQLITE_ENABLED` (default `1`)
- `METRICS_SQLITE_PATH` (default `/tmp/pi-leic-metrics.sqlite`)
- `METRICS_SQLITE_TIMEOUT_SECONDS` (default `5`)
- `METRICS_SQLITE_RETRY_MAX_FAILURES` (default `5`)
- `METRICS_SQLITE_RETRY_COOLDOWN_SECONDS` (default `10`)

If SQLite writes fail transiently (for example temporary lock/contention),
the collector keeps writing JSONL and retries SQLite after a cooldown window.
It no longer permanently disables SQLite on the first write error.

When rotation is enabled, older files are kept as:

- `metrics/gnb_metrics.jsonl.1`
- `metrics/gnb_metrics.jsonl.2`
- etc., up to `METRICS_ROTATE_MAX_FILES`

By default, the dashboard/API path prefers the SQLite cache through
`src/metrics_api.py`, and falls back to JSONL scanning if SQLite is unavailable.
For JSONL fallback control:

- `METRICS_LOG_INCLUDE_ROTATED` (default `1`)
- `METRICS_LOG_MAX_ARCHIVES` (default `5`)

`MetricsLogReader.latest_cells_by_source()` now returns all observed UE entities from
all cells in the latest event per source, each with:

- `cell_index`
- `ue_index`
- `ue_identity` (derived from `ue`, then `rnti`, then positional fallback)
- `ue` (the UE metrics payload)
- optional `pci`

For `cells` events, top-level UE context fields (`ue`, `rnti`, `cell_index`,
`pci`) should not be treated as authoritative. Use entity lists or
`raw_payload.cells[*].ue_list[*]` as source of truth.

To confirm the metrics file is growing:

```bash
watch -n 1 'wc -l metrics/gnb_metrics.jsonl'
```

To test UE connectivity after attach:

```bash
sudo ip netns exec ue1 ping 10.45.0.1
sudo ip netns exec ue2 ping 10.45.0.1
```

## Tests And CI

Run local unit tests with:

```bash
python -m unittest discover -s tests -p "test_*.py" -v
```

The repository now includes a minimal CI workflow in `.github/workflows/ci.yml` that runs:

- shell syntax checks for launcher/validator scripts
- Python syntax checks for key scripts
- unit tests under `tests/`

## Useful Commands

Restart the core services:

```bash
sudo systemctl restart open5gs-amfd open5gs-smfd open5gs-upfd
```

Enable the Open5GS WebUI if you want a GUI fallback for manual inspection:

```bash
sudo systemctl enable open5gs-webui
sudo systemctl start open5gs-webui
```

Default WebUI credentials:

- username: `admin`
- password: `1423`
