import json
import os
import time
import requests
from pathlib import Path

# ============================================================
# CONFIG
# ============================================================

HEALTH_JSON_PATH = "metrics/health.json"
METRICS_JSON_PATH = "metrics/metrics.json"
ALERTS_JSON_PATH = "metrics/alerts.json"

ORAN_METRICS_JSON_PATH = "metrics/oran_metrics.json"

OLLAMA_URL = "http://localhost:11434/api/generate"

# Nome do teu modelo no Ollama
MODEL_NAME = "RANPilot"

# ============================================================
# LOAD JSON
# ============================================================

def load_local_json(filepath: str) -> dict:
    path = Path(filepath)

    if not path.exists():
        raise FileNotFoundError(f"File not found: {filepath}")

    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

# ============================================================
# LOAD JSON API
# ============================================================

def load_api_json(url: str) -> dict:
    try:
        response = requests.get(url)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as exc:
        raise RuntimeError(f"Erro na requisição: {exc}") from exc
    except ValueError as exc:
        raise ValueError("Resposta não contém JSON válido.") from exc
    
# ============================================================
# PARSE SRSRAN DATA
# ============================================================

def parse_health(data: dict) -> str:

    lines = []

    # --------------------------------------------------------
    # GENERAL STATUS
    # --------------------------------------------------------

    status = data.get("status", "unknown")

    if status == "ok":
        lines.append("Network status: healthy")
    else:
        lines.append(f"Network status: {status}")

    lines.append("")

    # --------------------------------------------------------
    # SNAPSHOT
    # --------------------------------------------------------

    snapshot = data.get("snapshot", {})

    sources_count = snapshot.get("sources", 0)
    entities_count = snapshot.get("entities", 0)

    lines.append(f"Connected gNBs: {sources_count}")
    lines.append(f"Total entities: {entities_count}")

    # --------------------------------------------------------
    # SOURCES
    # --------------------------------------------------------

    sources = data.get("sources", {})

    fresh_sources = 0

    for source_name, source_data in sources.items():

        if source_data.get("fresh", False):
            fresh_sources += 1

    if fresh_sources == len(sources):
        lines.append("Fresh sources: all")
    else:
        lines.append(f"Fresh sources: {fresh_sources}/{len(sources)}")

    lines.append("")

    # --------------------------------------------------------
    # PER SOURCE DETAILS
    # --------------------------------------------------------

    for source_name, source_data in sources.items():

        entities = source_data.get("entities", 0)
        age = source_data.get("last_sample_age_seconds", "unknown")
        fresh = source_data.get("fresh", False)

        lines.append(f"{source_name}:")
        lines.append(f"- entities: {entities}")
        lines.append(f"- last metric age: {age}s")
        lines.append(f"- fresh: {fresh}")
        lines.append("")

    return "\n".join(lines)

def parse_metrics(data: dict) -> str:

    lines = []

    # --------------------------------------------------------
    # CELL PROFILE & AGGREGATIONS
    # --------------------------------------------------------

    items = data.get("items", [])
    cells_data = {}

    for item in items:
        source_id = item.get("source_id", "unknown")
        entities = item.get("entities", [])

        for entity in entities:
            cell_idx = entity.get("cell_index", 0)
            pci = entity.get("pci", "unknown")
            ue_data = entity.get("ue", {})

            cell_key = (source_id, cell_idx)

            if cell_key not in cells_data:
                cells_data[cell_key] = {
                    "pci": pci,
                    "dl_throughput": 0.0,
                    "ul_throughput": 0.0,
                    "ues": []
                }

            dl_brate = ue_data.get("dl_brate", 0.0)
            ul_brate = ue_data.get("ul_brate", 0.0)

            cells_data[cell_key]["dl_throughput"] += dl_brate
            cells_data[cell_key]["ul_throughput"] += ul_brate
            cells_data[cell_key]["ues"].append(entity)

    lines.append("Cell Throughput:")
    for (src_id, c_idx), c_info in cells_data.items():
        lines.append(f"- {src_id} (Cell {c_idx}, PCI {c_info['pci']}):")
        lines.append(f"  * cell_dl_throughput: {c_info['dl_throughput']} Mbps")
        lines.append(f"  * cell_ul_throughput: {c_info['ul_throughput']} Mbps")
    lines.append("")

    # --------------------------------------------------------
    # PER USER EQUIPMENT (UE) METRICS
    # --------------------------------------------------------

    lines.append("Métricas detalhadas do equipamento do utilizador:")

    for (src_id, c_idx), c_info in cells_data.items():
        for entity in c_info["ues"]:
            ue_id = entity.get("ue_identity", "unknown")
            rnti = entity.get("ue", {}).get("rnti", "unknown")
            ue_stats = entity.get("ue", {})

            dl_brate = ue_stats.get("dl_brate", 0.0)
            ul_brate = ue_stats.get("ul_brate", 0.0)
            rsrp = ue_stats.get("pusch_rsrp_db", 0.0)
            snr = ue_stats.get("pucch_snr_db", 0.0)
            cqi = ue_stats.get("cqi", 0)

            dl_ok = ue_stats.get("dl_nof_ok", 0)
            dl_nok = ue_stats.get("dl_nof_nok", 0)
            total_blocks = dl_ok + dl_nok
            bler = (dl_nok / total_blocks) if total_blocks > 0 else 0.0

            ta = ue_stats.get("ta_ns", 0.0)
            dl_mcs = ue_stats.get("dl_mcs", 0)
            ul_mcs = ue_stats.get("ul_mcs", 0)

            lines.append(f"- {ue_id} via {src_id} (RNTI: {rnti}):")
            lines.append(f"  * Throughput: DL {dl_brate} Mbps / UL {ul_brate} Mbps")
            lines.append("  * Radio Frequency Metrics:")
            lines.append(f"    + RSRP: {rsrp} dBm")
            lines.append(f"    + SINR: {snr} dB")
            lines.append(f"    + CQI: {cqi}")
            lines.append("  * Efficiency & Radio Link Health:")
            lines.append(f"    + BLER: {bler:.2%}")
            lines.append(f"    + TA: {ta} ns")
            lines.append(f"    + MCS: DL {dl_mcs} / UL {ul_mcs}")
            lines.append("")

    return "\n".join(lines)


def parse_alarms(data: dict) -> str:

    lines = []

    # --------------------------------------------------------
    # ALARMS OVERVIEW
    # --------------------------------------------------------
    
    count = data.get("count", 0)

    # --------------------------------------------------------
    # DETAILED ALARM ITEMS
    # --------------------------------------------------------
    
    items = data.get("items", [])

    if count > 0 and items:

        lines.append(f"Active Network Alarms [{count}]:")
        
        for item in items:
            source_id = item.get("source_id", "unknown")
            #timestamp = item.get("timestamp", "unknown")
            ue_id = item.get("ue_identity", "N/A")
            rule_id = item.get("rule_id", "unknown")
            metric = item.get("metric", "unknown")
            value = item.get("value", 0.0)
            threshold = item.get("threshold", 0.0)
            status = item.get("status", "unknown")
            severity = item.get("severity", "unknown")

            # Mapeamento técnico correto da unidade para a LLM
            unit = "dBm" if "rsrp" in metric.lower() else "dB" if "snr" in metric.lower() or "rsrq" in metric.lower() else ""

            lines.append(f"- [{severity.upper()}] {rule_id} on {source_id}:")
            lines.append(f"  * Status: {status}")
            #lines.append(f"  * Timestamp: {timestamp}")
            lines.append(f"  * Affected UE: {ue_id}")
            lines.append(f"  * Trigger Metric: {metric}")
            lines.append(f"  * Measured Value: {value} {unit} (Threshold: {threshold} {unit})")
            lines.append("")
    else:
        lines.append("Active Network Alarms: None (Status clean)")
        lines.append("")

    return "\n".join(lines)

# ============================================================
# PARSE ORAN DATA
# ============================================================

def parse_oran_metrics(data: dict) -> str:

    lines = []

    # --------------------------------------------------------
    # METRICS SUMMARY OVERVIEW
    # --------------------------------------------------------
    version = data.get("schema_version", "unknown")
    timestamp = data.get("timestamp", "unknown")
    
    lines.append(f"Metrics schema: {version}")
    lines.append(f"Observation timestamp: {timestamp}")
    lines.append("")

    # --------------------------------------------------------
    # CELL & CONTROL CHANNEL PERFORMANCE
    # --------------------------------------------------------
    cells = data.get("cells", [])
    lines.append("Cell Infrastructure & Control Plane Load:")
    
    for cell in cells:
        cell_id = cell.get("cell_id", "unknown")
        pci = cell.get("pci")
        pci_str = f"PCI {pci}" if pci is not None else "PCI Not Allocated/Null"
        
        c_channel = cell.get("control_channel_load", {})
        cce_dl = c_channel.get("cce_fail_dl", 0)
        cce_ul = c_channel.get("cce_fail_ul", 0)
        
        lines.append(f"- {cell_id} ({pci_str}):")
        lines.append(f"  * Control Channel Failures: PDCCH (DL CCE) {cce_dl} / PUCCH (UL CCE) {cce_ul}")
    lines.append("")

    # --------------------------------------------------------
    # NETWORK AGGREGATE THROUGHPUT
    # --------------------------------------------------------
    ues = data.get("ues", [])
    total_dl_throughput = sum(ue.get("throughput", {}).get("dl_goodput_mbps", 0.0) for ue in ues)
    total_ul_throughput = sum(ue.get("throughput", {}).get("ul_goodput_mbps", 0.0) for ue in ues)

    lines.append("Network Aggregate Throughput:")
    lines.append(f"- Total Network DL Throughput: {total_dl_throughput:.2f} Mbps")
    lines.append(f"- Total Network UL Throughput: {total_ul_throughput:.2f} Mbps")
    lines.append("")

    # --------------------------------------------------------
    # PER USER EQUIPMENT (UE) DETAILED METRICS
    # --------------------------------------------------------
    lines.append("User Equipment Detailed Metrics:")
    
    for ue in ues:
        ue_id = ue.get("ue_id", "unknown")
        cell_id = ue.get("cell_id", "unknown")
        sync = ue.get("sync_state", "unknown")
        
        # Radio Quality
        rq = ue.get("radio_quality", {})
        cqi = rq.get("cqi")
        cqi_str = str(cqi) if cqi is not None else "Null"
        ri = rq.get("rank_indicator")
        ri_str = f"MIMO Rank {ri}" if ri is not None else "Rank Null"
        rsrp = rq.get("rsrp_dbm", 0.0)
        dl_snr = rq.get("dl_snr_db", 0.0)
        ul_snr = rq.get("ul_snr_db", 0.0)
        phr = rq.get("power_headroom_db", 0.0)
        
        # Throughput
        tp = ue.get("throughput", {})
        dl_tp = tp.get("dl_goodput_mbps", 0.0)
        ul_tp = tp.get("ul_goodput_mbps", 0.0)
        
        # Reliability & HARQ
        rel = ue.get("reliability", {})
        dl_bler = rel.get("dl_bler", 0.0)
        ul_bler = rel.get("ul_bler", 0.0)
        dl_rounds = rel.get("dlsch_rounds", [0, 0, 0, 0])
        ul_rounds = rel.get("ulsch_rounds", [0, 0, 0, 0])
        pucch_dtx = rel.get("pucch_dtx", 0)
        ulsch_dtx = rel.get("ulsch_dtx", 0)
        
        # Scheduler
        sched = ue.get("scheduler", {})
        dl_mcs = sched.get("dl_mcs", 0)
        ul_mcs = sched.get("ul_mcs", 0)

        lines.append(f"- {ue_id} attached to {cell_id} [Sync: {sync}]:")
        lines.append(f"  * Throughput (Goodput): DL {dl_tp} Mbps / UL {ul_tp} Mbps")
        lines.append("  * RF & Link Quality:")
        lines.append(f"    + SS-RSRP: {rsrp} dBm")
        lines.append(f"    + SNR: DL {dl_snr} dB / UL {ul_snr} dB")
        lines.append(f"    + CQI: {cqi_str} | Spatial Multiplexing: {ri_str}")
        lines.append(f"    + Power Headroom (PHR): {phr} dB")
        lines.append("  * Efficiency & HARQ Rounds:")
        lines.append(f"    + Block Error Rate (BLER): DL {dl_bler:.2%} / UL {ul_bler:.2%}")
        lines.append(f"    + DLSCH HARQ (Rounds 1-4): {dl_rounds}")
        lines.append(f"    + ULSCH HARQ (Rounds 1-4): {ul_rounds}")
        lines.append(f"    + Discontinuous Transmission (DTX): PUCCH {pucch_dtx} / ULSCH {ulsch_dtx}")
        lines.append("  * Scheduler Allocations:")
        lines.append(f"    + Modulation Coding Scheme (MCS): DL {dl_mcs} / UL {ul_mcs}")
        lines.append("")

    return "\n".join(lines)

# ============================================================
# BUILD NETWORK SUMMARY
# ============================================================

def build_srsRAN_network_summary() -> str:

    # --------------------------------------------------------
    # LOAD LOCAL METRICS FOR TESTING
    # --------------------------------------------------------

    health = load_local_json(HEALTH_JSON_PATH)
    metrics = load_local_json(METRICS_JSON_PATH)
    alerts = load_local_json(ALERTS_JSON_PATH)

    # --------------------------------------------------------
    # LOAD METRICS FROM API 
    # --------------------------------------------------------

    # health = load_api_json("http://localhost:8000/health")
    # metrics = load_api_json("http://localhost:8000/metrics")
    # alerts = load_api_json("http://localhost:8000/alerts")

    # --------------------------------------------------------
    # PARSE DATA INTO SUMMARY
    # --------------------------------------------------------

    health_summary = parse_health(health)
    metrics_summary = parse_metrics(metrics)
    alerts_summary = parse_alarms(alerts)

    final_summary = f"{health_summary}\n\n{metrics_summary}\n\n{alerts_summary}"

    return final_summary

def build_ORAN_network_summary() -> str:

    # --------------------------------------------------------
    # LOAD LOCAL METRICS FOR TESTING
    # --------------------------------------------------------

    metrics = load_local_json(ORAN_METRICS_JSON_PATH)

    # --------------------------------------------------------
    # LOAD METRICS FROM API 
    # --------------------------------------------------------

      #TODO: definir URLs corretas para o ORAN

    # --------------------------------------------------------
    # PARSE DATA INTO SUMMARY
    # --------------------------------------------------------

    metrics_summary = parse_oran_metrics(metrics)

    final_summary = f"{metrics_summary}\n"

    return final_summary

# ============================================================
# OLLAMA CALL
# ============================================================


def build_network_summary(software: str) -> str:

    match software:
        case "oran":
            return build_ORAN_network_summary()

        case "srsran":
            return build_srsRAN_network_summary()

        case _:
            raise ValueError(f"Unsupported software type: {software}")



#transformar isto numa função que recebe apenas a pergunta.
def ask_llm(summary: str, question: str) -> str:

    prompt = f"""

Segue abaixo o resumo atual da rede:

{summary}

Question:
{question}
"""

    payload = {
        "model": MODEL_NAME,
        "prompt": prompt,
        "stream": False
    }

    response = requests.post(OLLAMA_URL, json=payload)

    response.raise_for_status()

    data = response.json()

    return data.get("response", "").strip()


# ============================================================
# MAIN
# ============================================================

def main():

    try:

        # ----------------------------------------------------
        # BUILD SUMMARY
        # ----------------------------------------------------


        software= input("Enter software type: ")
        
        summary = build_network_summary(software)
        

        print("\n================ NETWORK SUMMARY ================\n")
        print(summary)

        # ----------------------------------------------------
        # INTERACTIVE LOOP
        # ----------------------------------------------------

        while True:

            print("\n=================================================\n")

            question = input(
                "Agent commands:\n\n"
                "exit -> to quit\n" \
                "refresh -> to refresh summary\n\n" \
                "Ask your question about the network: ")

            if not question.strip():
                continue

            if question.lower() in ["refresh"]:
                print("\nRefreshing network summary...\n")
                summary = build_network_summary(software)
                print(summary)
                continue

            if question.lower() in ["exit"]:
                break

            start_time = time.perf_counter()
            answer = ask_llm(summary, question)
            elapsed_seconds = time.perf_counter() - start_time

            # Format elapsed time as minutes and seconds
            minutes = int(elapsed_seconds // 60)
            seconds = elapsed_seconds % 60
            if minutes:
                time_str = f"{minutes}m {seconds:.3f}s"
            else:
                time_str = f"{seconds:.3f}s"

            print("\nLLM Response:\n")
            print(answer)
            print(f"\nLLM response time: {time_str} ({elapsed_seconds:.3f} seconds)")


    except Exception as e:
        print(f"\nERROR: {e}")


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    import threading
    import webbrowser

    port = int(os.environ.get("AGENT_UI_PORT", 5000))
    url = f"http://localhost:{port}"

    # start Flask server in background thread
    from server import app
    server_thread = threading.Thread(
        target=lambda: app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False),
        daemon=True
    )
    server_thread.start()

    # give the server a moment then open browser
    threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    print(f"RANPilot UI → {url}")

    main()