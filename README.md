# PI-LEIC

PI-LEIC is a proof-of-concept 5G RAN monitoring and control platform for the FEUP lab.



## One-sentence summary

This project launches a small Open5GS + srsRAN lab, collects metrics from two gNBs, stores them in JSONL and SQLite, and exposes monitoring and control-oriented endpoints through a local API.

## Problem / motivation

This proof of concept exists to give the lab a practical way to observe a multi-gNB 5G setup and to expose a controlled interface for future monitoring and control workflows.

The current implementation also acts as a stepping stone toward the architecture described in [D1/DesenhoSolução.md](D1/DesenhoSolução.md), where the long-term direction moves from WebSocket metric ingestion to E2-based integration.

## What the POC does

At the current stage, the project does the following:

- Provisions subscribers for the Open5GS lab with [src/provision_subscribers.py](src/provision_subscribers.py).
- Launches the multi-node stack with [src/launch_stack.sh](src/launch_stack.sh).
- Collects gNB metrics from the WebSocket sources listed in [config/metrics_sources.json](config/metrics_sources.json).
- Enriches and stores events in both [metrics/gnb_metrics.jsonl](metrics/gnb_metrics.jsonl) and SQLite.
- Serves health, metrics, alerts, capabilities, and Prometheus-style output through [src/metrics_rest_api.py](src/metrics_rest_api.py).
- Validates the end-to-end setup with [src/validate_stage.sh](src/validate_stage.sh).

## Features

The repository currently includes these implemented features:

- Multi-gNB metric ingestion for `gnb1` and `gnb2`.
- Dual-write storage to JSONL and SQLite.
- SQLite-first reads with JSONL fallback.
- Freshness evaluation shared between Python and shell validation logic.
- REST endpoints for `/metrics`, `/alerts`, `/health`, `/capabilities`, `/metrics_prom`, `/query`, and `/actions`.
- Rule-based alerting for stale sources and low throughput conditions.
- Rootless shell tests and Python unit tests in [tests/](tests/).

## Architecture or project structure

The repository is organized around a small set of runtime layers:

- [config/](config/) stores lab and source configuration.
- [src/collector/](src/collector/) handles transport, enrichment, storage, and worker execution.
- [src/shared/](src/shared/) contains shared identity, liveness, environment, and logging helpers.
- [src/metrics_api.py](src/metrics_api.py) provides the read path over stored metrics.
- [src/metrics_rest_api.py](src/metrics_rest_api.py) exposes the HTTP API.
- [src/launch_stack.sh](src/launch_stack.sh) orchestrates the runtime stack.
- [src/validate_stage.sh](src/validate_stage.sh) validates the deployed stage.
- [agent/](agent/) contains the prototype agent layer.
- [tests/](tests/) contains shell and Python test coverage.
- [vulture/](vulture/) contains working notes, architecture guidance, and roadmap material used during development.

## Requirements

This project assumes a prepared Linux lab environment, not just a Python environment.

- Linux with systemd user services available.
- Python 3.10 or newer.
- Open5GS installed and reachable on `127.0.0.5`.
- `mongosh` available for subscriber provisioning.
- srsRAN `gnb` available on `PATH` or through `GNB_BIN`.
- `srsue` available on `PATH` or through `UE_BIN`.
- `iperf3` available for traffic validation.
- An optional terminal emulator if you want to use `--mode terminals`.

Python package dependencies are declared in [pyproject.toml](pyproject.toml). Optional development linting dependencies are listed in [requirements-dev.txt](requirements-dev.txt).

## Installation

Use these steps to prepare the Python environment:

1. Clone the repository.
2. Create a virtual environment:

   ```bash
   python3 -m venv src/.venv
   ```

3. Activate the virtual environment:

   ```bash
   source src/.venv/bin/activate
   ```

4. Install the package in editable mode:

   ```bash
   python -m pip install -e .
   ```

## How to run it

Use these steps to provision the lab and start the stack:

1. Apply subscriber provisioning:

   ```bash
   python src/provision_subscribers.py --apply
   ```

2. Launch the stack:

   ```bash
   bash src/launch_stack.sh
   ```

3. Open the API locally at `http://127.0.0.1:8000`.

4. Stop the stack when you are done:

   ```bash
   bash src/launch_stack.sh --stop
   ```

If you want an end-to-end validation run, use:

```bash
bash src/validate_stage.sh
```

## Usage example

After the stack is running, these commands are the quickest way to inspect it:

```bash
curl -s http://127.0.0.1:8000/health | jq
curl -s http://127.0.0.1:8000/metrics | jq
curl -s 'http://127.0.0.1:8000/alerts?status=open' | jq
curl -s http://127.0.0.1:8000/metrics_prom
```

Use [src/launch_stack.sh](src/launch_stack.sh) and [src/validate_stage.sh](src/validate_stage.sh) with `--help` to inspect the available runtime flags.

## Screenshots or demo link placeholder

Add evaluation material here when it is ready:

- Screenshot of the running stack.
- Screenshot of API output or monitoring view.
- Demo video or repository-linked presentation.

## Limitations

This repository is still a proof of concept, and several parts are intentionally incomplete:

- The active ingestion path is WebSocket JSON metrics, not E2AP/E2SM-KPM.
- The gNB configuration does not yet enable the E2 agent.
- `POST /query` is still a stub response path.
- `POST /actions` records approved actions in the audit trail but does not execute RAN changes.
- [agent/agent.py](agent/agent.py) still reads JSONL directly instead of using the REST API.
- The SQLite metrics database defaults to `/tmp/pi-leic-metrics.sqlite`.
- [src/dashboard.py](src/dashboard.py) is deprecated.
- Full validation depends on a real Open5GS + srsRAN lab environment.

## Future work

The current roadmap in [vulture/05 Roadmap/RIC Transition Plan.md](vulture/05%20Roadmap/RIC%20Transition%20Plan.md) points to the next steps.

- Enable the srsRAN E2 agent and add an `E2KpmSourceAdapter`.
- Route the prototype agent through the API query path.
- Extend QoS-related metrics such as `prb_usage_pct` when upstream data is available.
- Move audit persistence away from `/tmp`.
- Add a Grafana dashboard for the Prometheus exposition.
- Add more CI coverage for no-RF smoke scenarios.

## Authors / maintainers

The repository history currently shows these contributors:

- Filipe Camacho
- Lucas Oliveira

## License

No license file is currently present in the repository.

## References or acknowledgement

The project is grounded in the repository design and stage documents below:

- [D1/DesenhoSolução.md](D1/DesenhoSolução.md)
- [PROJECT_GUIDE.md](PROJECT_GUIDE.md)
- [STAGE_OVERVIEW.md](STAGE_OVERVIEW.md)

The proof of concept is built around Open5GS, srsRAN, and the longer-term O-RAN SC Near-RT RIC direction described in the project notes.
