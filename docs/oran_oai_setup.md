# OAI/ORAN Setup Runbook

```bash
sudo sed -i 's|http://pt.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null
sudo sed -i 's|http://pt.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list.d/*.list 2>/dev/null
sudo sed -i 's|http://pt.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list.d/*.sources 2>/dev/null
sudo apt-get update
```


## 1. Host Assumptions

- Ubuntu Linux host with `sudo` access.
- Open5GS is installed and reachable on `127.0.0.5` for NGAP/SCTP.
- The repo Python services are installed with `requirements.txt`.
- Kernel networking allows namespaces, TUN interfaces, SCTP, PFCP, and GTP-U.
- The default lab PLMN is `99970`, TAC is `1`, SST is `1`, and DNN/APN is `internet`.

## 2. Install OpenAirInterface


```bash
mkdir -p ~/oai
cd ~/oai
git clone https://gitlab.eurecom.fr/oai/openairinterface5g.git
cd openairinterface5g
git rev-parse HEAD
```

```bash
cd ~/oai/openairinterface5g/cmake_targets
./build_oai -I --install-optional-packages
```

Build the gNB and nrUE RFsim binaries:

```bash
sudo apt-get install autoconf automake libtool
cd ~/oai/openairinterface5g/cmake_targets
./build_oai --gNB --nrUE --ninja --cmake-opt "-DAUTO_DOWNLOAD_ASN1C=ON"
```

> **`--cmake-opt "-DAUTO_DOWNLOAD_ASN1C=ON"`** — CMake requires `asn1c` at configure time. If the system package is missing (e.g. because the `-I` step above failed due to mirror connectivity), this flag tells CMake to download and build a compatible version of `asn1c` from source automatically during the configure step. Note: `-D` flags must be passed via `--cmake-opt`, not directly to `build_oai`. Pass it every time to be safe; it is a no-op when the system package is already present.

Expected binaries:

```bash
~/oai/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem
~/oai/openairinterface5g/cmake_targets/ran_build/build/nr-uesoftmodem
```

## 3. Prepare Open5GS

Provision the existing subscribers before launching:

```bash
python3 src/provision_subscribers.py
```

Confirm the OAI gNB config aligns with Open5GS:

- AMF: `127.0.0.5`
- PLMN: `99970`
- TAC: `1`
- SST: `1`
- DNN/APN: `internet`

The default OAI gNB config is `config/oai/gnb.sa.band78.rfsim.conf`.

RAN_BACKEND=oai GNB_BIN="$HOME/oai/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem" UE_BIN="$HOME/oai/openairinterface5g/cmake_targets/ran_build/build/nr-uesoftmodem" bash src/launch_stack.sh --stop

## 4. Run OAI Backend

From the repo root:

Run this block verbatim from the repo root (paste all lines at once):

```bash
unset METRICS_SOURCES_CONFIG
mkdir -p metrics/oran
OAI_DIR="$HOME/oai/openairinterface5g"
export GNB_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
export UE_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"
export RAN_BACKEND=oai
export METRICS_OUT="$PWD/metrics/oran/gnb_metrics.jsonl"
export METRICS_AGENT_OUT="$PWD/metrics/oran/agent_network_observations.jsonl"
export METRICS_SQLITE_PATH="$PWD/metrics/oran/pi-leic-metrics.sqlite"
export OAI_UE_EXTRA_ARGS="--rfsim -O $PWD/config/oai/ue.conf -r 106 --numerology 1 --band 78 -C 3319680000 --ssb 516"
bash src/launch_stack.sh --mode supervised
```

Fallback to the previous srsRAN stack:

```bash
RAN_BACKEND=srsran bash src/launch_stack.sh --mode supervised
```

## 5. OAI API Test

### Check the OAI binaries

```bash
export OAI_DIR="$HOME/oai/openairinterface5g"
export GNB_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
export UE_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"

test -x "$GNB_BIN" && "$GNB_BIN" --help >/dev/null 2>&1 || echo "Check GNB_BIN=$GNB_BIN"
test -x "$UE_BIN" && "$UE_BIN" --help >/dev/null 2>&1 || echo "Check UE_BIN=$UE_BIN"
```

### Start the OAI-backed stack

Use a clean shell so old `METRICS_SOURCES_CONFIG` values do not leak in:

```bash
unset METRICS_SOURCES_CONFIG
export RAN_BACKEND=oai
export DASHBOARD_ENABLED=0
export API_HOST=127.0.0.1
export API_PORT=18080
export OAI_DIR="$HOME/oai/openairinterface5g"
export GNB_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
export UE_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"

bash src/launch_stack.sh --mode supervised
```

If you only want to inspect what will be started:

```bash
unset METRICS_SOURCES_CONFIG
RAN_BACKEND=oai DASHBOARD_ENABLED=0 bash src/launch_stack.sh --dry-run
```

Stop the stack:

```bash
RAN_BACKEND=oai bash src/launch_stack.sh --stop
```

### Confirm OAI is producing MAC stats

OAI writes the file as a **relative path** (`nrMAC_stats.log`, with an underscore) in each gNB's current working directory. Under this launcher the files are:

```bash
metrics/oran/gnb.sa.band78.rfsim/nrMAC_stats.log
metrics/oran/gnb2.sa.band78.rfsim/nrMAC_stats.log
```

### Call the API

```bash
curl -s 'http://127.0.0.1:18080/metrics*
```
