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
- `src/metrics_exporter.py`

## Prerequisites

Before running the stack, make sure the machine has:

- Open5GS installed and running
- `mongosh` available locally
- `srsue` available on `PATH`
- `gnb` from srsRAN Project available on `PATH`, or exported through `GNB_BIN`
- a graphical terminal emulator such as `gnome-terminal`, `konsole`, `xterm`, or `x-terminal-emulator`

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

`src/launch_stack.sh` is the main launcher for this stage. It:

- restarts and tails the Open5GS core logs
- launches `gNB1`
- launches `gNB2`
- creates `ue1` and `ue2` namespaces automatically
- launches `UE1`
- launches `UE2`
- launches the central metrics collector
- launches the dashboard
- runs a best-effort post-launch smoke check

That smoke check runs immediately after the terminals open, so in interactive runs it may warn while those terminals are still waiting for sudo input. Treat it as an early hint, not as the final verdict.

If you want to inspect what it will do without opening terminals:

```bash
bash src/launch_stack.sh --dry-run
```

## Validation Run

Use this to replay the full milestone validation against fresh metrics from the current run only:

```bash
cd /path/to/PI-LEIC
bash src/validate_stage.sh
```

It will:

- apply `config/subscribers.json`
- launch the full stack
- send traffic from `ue1` and `ue2` to `10.45.0.1`
- confirm fresh `source_id` entries for every configured source in `metrics/gnb_metrics.jsonl`
- confirm fresh non-zero `dl_brate` and `ul_brate` for every configured source

This is the authoritative end-to-end validation flow. By default it disables the launcher's early smoke check and validates after real traffic has been generated.

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

To confirm the metrics file is growing:

```bash
watch -n 1 'wc -l metrics/gnb_metrics.jsonl'
```

To test UE connectivity after attach:

```bash
sudo ip netns exec ue1 ping 10.45.0.1
sudo ip netns exec ue2 ping 10.45.0.1
```

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
